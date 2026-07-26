// antic_timing.sv — the cycle-serial ANTIC timing machine.
//
// docs/Design/antic-timing-machine.md.  This module is (becoming) the sole
// authority for everything the CPU can OBSERVE about ANTIC: VCOUNT, NMIST,
// /NMI, /RDY (WSYNC), and the bus schedule (DMA stealing).  It is a direct
// implementation of the chip's per-cycle state machine — one hcount/line
// counter chain, a live display-list fetch FSM, a live row counter — in the
// CPU's OWN clock domain on the CPU's OWN phi2 grid, so every CPU-visible
// edge is same-domain and same-grid with the core: no CDC compensation, no
// calibration constants, no phantom/carry patch mechanisms.
//
// It renders nothing.  The parse/walk/compositor pipeline keeps drawing the
// frame; in migration phase 4 it consumes this machine's per-line decode.
//
// CYCLE CONVENTION.  Altirra processes ANTIC's events for cycle N before
// the CPU acts in cycle N.  Here, state keyed `hc_next == N` updates on the
// tick ENTERING cycle N, so it is visible to a CPU whose data cycle is N —
// the same ordering.  A register write snooped during cycle K is in the
// register before the tick entering K+1 (and, because snooping is per-clk,
// before any event keyed on later cycles of the same line).
//
// Cycle anchors (Altirra source, verified this week; hcount 0-113):
//   1        DL instruction fetch (DL DMA on, new line needed)
//   6        DL address low + VSCROL sample for the DLI compare
//              ("mLatchedVScroll2", used at 7)
//   7        DL address high + NMIST change + NMI pending (DLI per rowStop
//              compare with the cycle-6 sample; VBI at line 248)
//   7-8      /NMI low pulse (2 cycles)
//   25..57/4 memory refresh (9 slots)
//   109      VSCROL row-stop latch window closes ("mLatchedVScroll":
//              writes at hcount<109 pass through, later writes miss)
//   111      the line counter advances (VCOUNT increment)
//   112      row-advance decision: rowStop = vsExit ? latch109
//              : (height-1); rowCounter++ or new DL line; latch re-samples
//              after use
//   line 248 VBI; DL control byte saved (mDLControlPrev), VS bit kept
//   line 8   first display line: DL (re)starts, control byte restored
//
// WSYNC ($D40A write in cycle K): latch falls entering K+1, /RDY (one more
// stage) falls entering K+2 — exactly one instruction cycle runs after the
// write (Avery's delay slot).  Release: latch rises entering RELEASE (102),
// /RDY rises entering 103 — the CPU's first executed cycle is 103 (Avery's
// own annotations: `mva #$40 nmien ;*, 104, 105..` — the * is 103; MiSTer's
// "105" uses a different hcount origin).  Same-domain: what you see is what
// the core samples.  Clear beats set (the late-INC straddle).

`default_nettype none

module antic_timing #(
    parameter [6:0] RELEASE_CYCLE = 7'd104,  // fid-effective resume = 104: the core's
                                             // SUB_DATA sample sits one window ahead of
                                             // its commit, so /RDY rising entering 105
                                             // puts the first data-visible cycle at 104
                                             // (measured: prog=7 d2 sample tm-110 at
                                             // release 103 -> needs +1 for data@111)
    parameter [8:0] VBI_LINE      = 9'd248,
    parameter [8:0] RESTART_LINE  = 9'd8      // first display line
) (
    input  wire        clk,          // clk_sally
    input  wire        rst,
    input  wire        phi2_tick,    // machine-cycle grid (the tick the fid core paces on)
    input  wire        cold,         // SALLYRST cold-boot: power-on-clear NMIEN/DMACTL
                                     // (xexload relies on it; counters keep running)

    // ---- Register write snoop (same-domain, pre-CDC) --------------------
    input  wire        reg_we,       // 1-clk strobe: CPU write to $D4xx
    input  wire [3:0]  reg_addr,
    input  wire [7:0]  reg_wdata,

    // ---- Stolen-slot memory read port -----------------------------------
    // Held through OUR cycle (the CPU is halted then); rdata is sampled at
    // the tick ending the cycle.
    output logic        mem_req,
    output logic [15:0] mem_addr,
    input  wire  [7:0]  mem_rdata,

    // ---- CPU-visible outputs --------------------------------------------
    output wire  [7:0]  vcount,      // $D40B read value
    output wire  [7:0]  nmist,      // $D40F read value
    output logic        nmi_n,       // /NMI to the core (2-cycle low pulse)
    output logic        rdy_n_q,     // /RDY (1 = ready), registered, same grid
    output logic [2:0]  cycle_type,  // THIS cycle's bus owner (CT_*)

    // ---- Debug / diff taps ----------------------------------------------
    output wire  [6:0]  dbg_hcount,
    output wire  [8:0]  dbg_line,
    output wire  [3:0]  dbg_rowctr,
    output wire  [7:0]  dbg_dlctl,
    output wire [15:0]  dbg_dlpc
);

    localparam [2:0] CT_CPU     = 3'd0;
    localparam [2:0] CT_DL      = 3'd1;
    localparam [2:0] CT_PF      = 3'd2;   // phase-2d: schedule only
    localparam [2:0] CT_PM      = 3'd3;
    localparam [2:0] CT_REFRESH = 3'd4;

    // =====================================================================
    // Registers (snooped — zero latency, same domain as the CPU)
    // =====================================================================
    logic [7:0] dmactl_q, nmien_q, vscrol_q, hscrol_q;
    logic [7:0] dlistl_q, dlisth_q;
    logic       wsync_armed;

    wire dl_dma_on = dmactl_q[5];

    // =====================================================================
    // Counter chain
    // =====================================================================
    logic [6:0] hcount;               // current cycle, 0..113
    logic [8:0] line;                 // current line; advances entering 111
    wire  [6:0] hc_next = (hcount == 7'd113) ? 7'd0 : hcount + 7'd1;
    wire        line_wraps = (hc_next == 7'd0);

    assign vcount     = line[8:1];
    assign dbg_hcount = hcount;
    assign dbg_line   = line;

    // =====================================================================
    // Display-list machine
    // =====================================================================
    logic [7:0]  dl_ctl, dl_ctl_prev; // live control byte + VBI-saved copy
    logic [15:0] dl_pc;               // live DL PC (1K-wrap advance)
    logic [3:0]  row_ctr;             // DCTR
    logic [3:0]  row_height_m1;
    logic        dl_active;           // 0 = parked (JVB wait) — DLI keeps firing
    logic        need_inst;
    logic        need_addr;
    logic        is_jvb;
    logic        vs_prev;             // previous DL line's VS bit
    logic [3:0]  vs_latch6;           // DLI-compare sample (cycle 6)
    logic [3:0]  vs_latch109;         // row-stop latch (write-through < 109)
    logic [7:0]  inst_q;
    logic [7:0]  addr_lo_q;

    assign dbg_rowctr = row_ctr;
    assign dbg_dlctl  = dl_ctl;
    assign dbg_dlpc   = dl_pc;

    function automatic [3:0] mode_height_m1(input [3:0] m);
        case (m)
            4'h0: mode_height_m1 = 4'd0;
            4'h1: mode_height_m1 = 4'd0;
            4'h2: mode_height_m1 = 4'd7;
            4'h3: mode_height_m1 = 4'd9;
            4'h4: mode_height_m1 = 4'd7;
            4'h5: mode_height_m1 = 4'd15;
            4'h6: mode_height_m1 = 4'd7;
            4'h7: mode_height_m1 = 4'd15;
            4'h8: mode_height_m1 = 4'd7;
            4'h9: mode_height_m1 = 4'd3;
            4'hA: mode_height_m1 = 4'd3;
            4'hB: mode_height_m1 = 4'd1;
            4'hC: mode_height_m1 = 4'd0;
            4'hD: mode_height_m1 = 4'd1;
            4'hE: mode_height_m1 = 4'd0;
            4'hF: mode_height_m1 = 4'd0;
        endcase
    endfunction

    function automatic [3:0] ctl_height_m1(input [7:0] c);
        if (c[3:0] == 4'h0) ctl_height_m1 = {1'b0, c[6:4]};   // blank: count in 6:4
        else                ctl_height_m1 = mode_height_m1(c[3:0]);
    endfunction

    wire [3:0] mode      = dl_ctl[3:0];
    wire       vs_cur    = (mode >= 4'h2) && dl_ctl[5];
    wire       vs_exit   = vs_prev && !vs_cur;
    wire [3:0] stop_dli  = vs_exit ? vs_latch6   : row_height_m1;
    wire [3:0] stop_adv  = vs_exit ? vs_latch109 : row_height_m1;

    // DLIST pair is consumed only at the frame restart (mDLIST semantics —
    // the live PC free-runs otherwise; ACID antic_dlistwrap #1).
    logic dlist_dirty;

    // =====================================================================
    // NMIST / NMI / WSYNC state
    // =====================================================================
    logic [1:0] nmist_hi;             // {DLI, VBI}
    logic       nmi_ext;              // extend the pulse one more cycle
    logic       nmi_arm_q;            // DLI/VBI condition met at 7 -> pulse at 9
    logic       nmi_arm_vbi_q;        // which NMIEN bit gates this pulse
    logic       nmi_en_early;         // NMIEN sample #1 (entering 8)
    logic       nmi_en_late;          // enable that arrived between the samples
    logic [1:0] nmist_hold_q;         // cycle-6 status set is DOMINANT: re-assert
                                      // entering 7 so a same-cycle-6 NMIRES write
                                      // cannot erase it (ACID nmist 'VBI bit was
                                      // reset too early'); a cycle-7+ NMIRES clears.
    logic       wsync_latch_n;
    assign nmist = {nmist_hi, 6'h1F};

    // =====================================================================
    // Bus schedule for the CURRENT cycle (combinational)
    // =====================================================================
    wire refresh_slot = (hcount >= 7'd25) && (hcount <= 7'd57)
                        && (((hcount - 7'd25) % 7'd4) == 7'd0);
    wire dl_inst_slot = (hcount == 7'd1) && dl_dma_on && dl_active && need_inst;
    wire dl_lo_slot   = (hcount == 7'd6) && dl_dma_on && dl_active && need_addr;
    wire dl_hi_slot   = (hcount == 7'd7) && dl_dma_on && dl_active && need_addr;
    wire pm_missile   = (hcount == 7'd0) && (dmactl_q[3:2] != 2'b00);
    wire pm_player    = (hcount >= 7'd2) && (hcount <= 7'd5) && dmactl_q[3];

    // ---- Playfield DMA windows (phase 2d; Altirra UpdateDMAPattern) ------
    // Character name clock: every 2 (modes 2-5) / 4 (6-7) from S =
    // {wide 10, normal 18, narrow 26}; char DATA = the same clock +3;
    // bitmap data (8-F) = +2 with step 8 (8-9), 4 (A-C), 2 (D-F).  HSCROL
    // (when the line enables HS) bumps the fetch width one step wider and
    // delays the whole grid by one clock per 2 of HSCROL.  Cycles 105-113
    // are VIRTUAL: the clock runs, the bus is NOT stolen.  Fetch counts by
    // width: step2 = 48/40/32, step4 = 24/20/16, step8 = 12/10/8.
    wire       pf_line     = dl_active && (mode >= 4'h2);   // a mode line
    wire       hs_en       = pf_line && dl_ctl[4];
    wire [1:0] w_raw       = dmactl_q[1:0];
    wire [1:0] pf_w        = (hs_en && (w_raw == 2'd1 || w_raw == 2'd2))
                             ? w_raw + 2'd1 : w_raw;        // HS widens 1 step
    wire       pf_on       = pf_line && (pf_w != 2'd0);
    wire [6:0] hs_delay    = {4'd0, hscrol_q[3:1]};
    wire [6:0] name_start  = ((pf_w == 2'd3) ? 7'd10 :
                              (pf_w == 2'd2) ? 7'd18 : 7'd26) + hs_delay;
    wire       is_char     = (mode >= 4'h2) && (mode <= 4'h7);
    wire       step4       = (mode == 4'h6) || (mode == 4'h7) ||
                             (mode >= 4'hA && mode <= 4'hC);
    wire       step8       = (mode == 4'h8) || (mode == 4'h9);
    // data clock start: names+3 for char modes, names+2 for bitmap
    wire [6:0] data_start  = name_start + (is_char ? 7'd3 : 7'd2);
    // fetch counts: step2 48/40/32, step4 24/20/16, step8 12/10/8
    wire [6:0] n_fetch     = step8 ? ((pf_w == 2'd3) ? 7'd12 : (pf_w == 2'd2) ? 7'd10 : 7'd8)
                           : step4 ? ((pf_w == 2'd3) ? 7'd24 : (pf_w == 2'd2) ? 7'd20 : 7'd16)
                                   : ((pf_w == 2'd3) ? 7'd48 : (pf_w == 2'd2) ? 7'd40 : 7'd32);
    wire [3:0] stepv       = step8 ? 4'd8 : step4 ? 4'd4 : 4'd2;
    wire [8:0] name_end    = {2'd0, name_start} + ({2'd0, n_fetch} * {5'd0, stepv});
    wire [8:0] data_end    = {2'd0, data_start} + ({2'd0, n_fetch} * {5'd0, stepv});
    // grid hits (virtual >= 105: no steal)
    wire [6:0] name_rel    = hcount - name_start;
    wire [6:0] data_rel    = hcount - data_start;
    wire name_hit = pf_on && is_char && (row_ctr == 4'd0)          // names: first row line
                    && (hcount >= name_start) && ({2'd0, hcount} < name_end)
                    && ((name_rel & (stepv[3:0] - 4'd1)) == 7'd0)
                    && (hcount < 7'd105);
    wire data_hit = pf_on
                    && (hcount >= data_start) && ({2'd0, hcount} < data_end)
                    && ((data_rel & (stepv[3:0] - 4'd1)) == 7'd0)
                    && (hcount < 7'd105);
    wire pf_steal = name_hit || data_hit;

    always_comb begin
        if (dl_inst_slot || dl_lo_slot || dl_hi_slot) cycle_type = CT_DL;
        else if (pm_missile || pm_player)             cycle_type = CT_PM;
        else if (pf_steal)                            cycle_type = CT_PF;
        else if (refresh_slot)                        cycle_type = CT_REFRESH;
        else                                          cycle_type = CT_CPU;
    end

    always_comb begin
        mem_req  = dl_inst_slot || dl_lo_slot || dl_hi_slot;
        mem_addr = dl_pc;
    end

    // Instruction byte as seen by the cycle-2 decode.  The decode tick IS
    // the tick that ends the fetch cycle: cap_inst (registered) is not set
    // yet, but the byte is already on mem_rdata — bypass on the slot itself.
    wire [7:0] inst_now = dl_inst_slot ? mem_rdata : inst_q;

    // =====================================================================
    // The machine
    // =====================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dmactl_q <= 8'h00; nmien_q <= 8'h00; vscrol_q <= 8'h00; hscrol_q <= 8'h00;
            dlistl_q <= 8'h00; dlisth_q <= 8'h00;
            wsync_armed <= 1'b0; dlist_dirty <= 1'b1;
            hcount <= 7'd0; line <= 9'd0;
            dl_ctl <= 8'h00; dl_ctl_prev <= 8'h00; dl_pc <= 16'h0000;
            row_ctr <= 4'd0; row_height_m1 <= 4'd0;
            dl_active <= 1'b0; need_inst <= 1'b0; need_addr <= 1'b0; is_jvb <= 1'b0;
            vs_prev <= 1'b0; vs_latch6 <= 4'd0; vs_latch109 <= 4'd0;
            inst_q <= 8'h00; addr_lo_q <= 8'h00;
            nmist_hi <= 2'b00; nmi_ext <= 1'b0; nmi_n <= 1'b1; nmi_arm_q <= 1'b0; nmi_arm_vbi_q <= 1'b0; nmi_en_early <= 1'b0; nmi_en_late <= 1'b0; nmist_hold_q <= 2'b00;
            wsync_latch_n <= 1'b1; rdy_n_q <= 1'b1;
        end else begin
            // ---------- register snoop (every clk, zero latency) ----------
            if (cold) begin
                dmactl_q <= 8'h00;
                nmien_q  <= 8'h00;
            end
            if (reg_we) begin
                case (reg_addr)
                    4'h0: dmactl_q <= reg_wdata;
                    4'h2: begin dlistl_q <= reg_wdata; dlist_dirty <= 1'b1; end
                    4'h3: begin dlisth_q <= reg_wdata; dlist_dirty <= 1'b1; end
                    4'h4: hscrol_q <= reg_wdata;
                    4'h5: begin
                        vscrol_q <= reg_wdata;
                        if (hcount < 7'd109) vs_latch109 <= reg_wdata[3:0];
                    end
                    4'hA: wsync_armed <= 1'b1;
                    4'hE: nmien_q <= reg_wdata;
                    4'hF: nmist_hi <= 2'b00;               // NMIRES
                    default: ;
                endcase
            end

            if (phi2_tick) begin
                // ---- DL fetch data: capture AT the launch tick ----------
                // mem_rdata (the shadow's port-A register) refreshes every
                // non-write clk of the slot cycle and holds mem[dl_pc] at
                // this tick; dl_pc increments on the SAME tick, so a delayed
                // capture would read the NEXT byte (measured: the JVB read
                // its own operand and never parked).
                if (dl_inst_slot) begin
                    inst_q <= mem_rdata;
                    dl_pc  <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
                end
                if (dl_lo_slot) begin
                    addr_lo_q <= mem_rdata;
                    dl_pc     <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
                end
                if (dl_hi_slot) begin
                    need_addr <= 1'b0;
                    if (is_jvb) begin
                        dl_pc <= {mem_rdata, addr_lo_q};
                        if (inst_q[6]) dl_active <= 1'b0;    // JVB parks
                        is_jvb <= 1'b0;
                    end else begin
                        dl_pc <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
                    end
                    // (LMS target: renderer's concern in phases 1-3)
                end

                // ---- entering cycle 2: decode a just-fetched instruction -
                if (hc_next == 7'd2 && need_inst && dl_active && dl_dma_on) begin
                    need_inst     <= 1'b0;
                    dl_ctl        <= inst_now;
                    row_height_m1 <= ctl_height_m1(inst_now);
                    // block entry: DCTR loads the LIVE VSCROL (Altirra
                    // mRowCounter = mVSCROL), else 0
                    row_ctr <= ((inst_now[3:0] >= 4'h2) && inst_now[5] && !vs_cur)
                               ? vscrol_q[3:0] : 4'd0;
                    if (inst_now[3:0] == 4'h1) begin
                        need_addr <= 1'b1; is_jvb <= 1'b1;
                    end else if (inst_now[6] && inst_now[3:0] != 4'h0) begin
                        need_addr <= 1'b1;                   // LMS operand
                    end
                end

                // ---- entering cycle 6: VSCROL DLI-compare sample --------
                if (hc_next == 7'd6) vs_latch6 <= vscrol_q[3:0];

                // ---- /NMI pulse shaping ---------------------------------
                // (trigger below overrides — trigger wins on the same tick)
                if (nmi_ext) begin nmi_ext <= 1'b0; nmi_n <= 1'b0; end
                else               nmi_n   <= 1'b1;

                // ---- entering cycle 7: NMIST changes --------------------
                // Visible to a CPU read whose data cycle is 6 and not one
                // earlier: on the release-104 grid the fid's data sample
                // sits one window ahead of its commit, so 'entering 7' is
                // what the CPU sees as cycle 6 (measured: entering 6 gave
                // ACID nmist 'set too early (<cycle 6)', entering 7 on the
                // OLD release-102 grid gave 'too late').  The DLI compare
                // uses the cycle-6 VSCROL sample — Altirra mLatchedVScroll2,
                // sampled at 6 and used at 7.
                if (hc_next == 7'd7) begin
                    if (line == VBI_LINE) begin
                        nmist_hi  <= 2'b01;
                        nmist_hold_q <= 2'b01;
                        nmi_arm_q <= 1'b1;          // condition only — NMIEN gates at pulse time
                        nmi_arm_vbi_q <= 1'b1;
                        dl_ctl_prev <= dl_ctl;               // save across the VBI
                        dl_ctl      <= dl_ctl & 8'h20;       // VS survives
                    end else if (dl_ctl[7] && (row_ctr == stop_dli)) begin
                        // DLI: mode lines, blank+DLI lines, and the parked
                        // JVB wait region alike (Race In Space).
                        nmist_hi  <= 2'b10;
                        nmist_hold_q <= 2'b10;
                        nmi_arm_q <= 1'b1;          // condition only — NMIEN gates at pulse time
                        nmi_arm_vbi_q <= 1'b0;
                    end else begin
                        nmi_arm_q <= 1'b0;
                    end
                end
                // entering 8: the cycle-7 set survives a same-cycle NMIRES
                // (ACID nmist 'VBI bit was reset too early')
                if (hc_next == 7'd8 && nmist_hold_q != 2'b00) begin
                    nmist_hi     <= nmist_hold_q;
                    nmist_hold_q <= 2'b00;
                end
                // ---- entering cycle 9: /NMI pulse (cycles 9-10) ---------
                // Two cycles after the status set, mirroring the real chip's
                // 7-8 pulse relative to its cycle-6 status change plus the
                // NMOS core's internal /NMI synchronizer stage (which the
                // fid's per-clk edge latch skips).  HW-verified: blockednmi
                // passes under authority on this grid.
                // ---- NMIEN: TWO samples, asymmetric combine -------------
                // Altirra takes mEarlyNMIEN at mX==7 and mEarlyNMIEN2 at
                // mX==8, then:
                //     cumulative     = pending & early          -> fire now
                //     cumulativeLate = pending & early2 & ~early -> fire +1
                // so an enable present at the FIRST sample fires promptly,
                // an enable arriving BETWEEN the samples still fires (one
                // cycle late), and a disable arriving after the first
                // sample cannot cancel an already-committed interrupt.
                // That asymmetry is precisely what ACID antic_nmist's
                // NMIEN sub-tests demand — a single sample point cannot
                // satisfy 'enable on cycle 6 activates' and 'disable on
                // cycle 6 does NOT deactivate' simultaneously (measured
                // from both directions on builds 52d/53/54b).
                // SAMPLE POINTS, pinned by four ACID asserts.  In this
                // machine's own frame a CPU write with Avery data-cycle N
                // becomes visible in nmien_q entering N+2 (consistent across
                // every probe taken on builds 52d/53/54b/55).  Therefore:
                //   disable@5 must deactivate      -> deciding sample >= 7
                //   disable@6 must NOT deactivate  -> deciding sample <= 7
                //   enable@6  must activate        -> a sample at 8
                //   enable@7  must NOT activate    -> no sample after 8
                // => early sample entering 7 (the decision tick), late
                //    sample entering 8.  Early fires at 8, late at 9.
                // (select the bit from the LIVE line compare — nmi_arm_vbi_q
                //  is written on this same tick and would read stale here)
                if (hc_next == 7'd7)
                    nmi_en_early <= (line == VBI_LINE) ? nmien_q[6] : nmien_q[7];
                if (hc_next == 7'd8) begin
                    nmi_en_late <= ((line == VBI_LINE) ? nmien_q[6] : nmien_q[7])
                                   & ~nmi_en_early;
                    if (nmi_arm_q && nmi_en_early) begin
                        nmi_n <= 1'b0; nmi_ext <= 1'b1; nmi_arm_q <= 1'b0;
                    end
                end
                // late enable (arrived between the samples): pulse slips one
                if (hc_next == 7'd9 && nmi_arm_q && nmi_en_late) begin
                    nmi_n <= 1'b0; nmi_ext <= 1'b1; nmi_arm_q <= 1'b0;
                end
                if (hc_next == 7'd10) begin
                    nmi_arm_q <= 1'b0; nmi_en_late <= 1'b0;
                end

                // ---- WSYNC latch + /RDY (clear beats set) ---------------
                if (hc_next == RELEASE_CYCLE) wsync_latch_n <= 1'b1;
                else if (wsync_armed)         wsync_latch_n <= 1'b0;
                wsync_armed <= 1'b0;
                rdy_n_q     <= wsync_latch_n;

                // ---- entering cycle 111: line advance (VCOUNT) ----------
                // The last line does NOT wrap here: ANTIC increments into
                // 262 so VCOUNT reads 131 for exactly ONE cycle before
                // resetting (ACID antic_vcount 'rollover #1 (NTSC) wrong' —
                // Avery's "nasty one: single cycle rollover", expects 131).
                if (hc_next == 7'd111) line <= line + 9'd1;
                // ---- entering cycle 112: the rollover completes ---------
                if (hc_next == 7'd112 && line == 9'd262) line <= 9'd0;

                // ---- entering cycle 112: row-advance decision -----------
                if (hc_next == 7'd112) begin
                    if (dl_active && !need_inst) begin
                        if (row_ctr == stop_adv) begin
                            row_ctr     <= 4'd0;
                            need_inst   <= 1'b1;
                            vs_prev     <= vs_cur;
                            vs_latch109 <= vscrol_q[3:0];    // re-sample after use
                        end else begin
                            row_ctr <= row_ctr + 4'd1;       // 4-bit wrap = over-scroll
                        end
                    end else if (dl_active && need_inst && !dl_dma_on) begin
                        // DL DMA off mid-frame: the fetch never happened —
                        // the STUCK control byte keeps cycling its rows and
                        // firing its DLI (live-DMACTL semantics).
                        row_ctr <= row_ctr + 4'd1;
                    end
                end

                // ---- end of line 7: (re)start the DL for line 8 ---------
                if (line_wraps && line == RESTART_LINE && dl_dma_on) begin
                    dl_active <= 1'b1;
                    need_inst <= 1'b1;
                    dl_pc     <= dlist_dirty ? {dlisth_q, dlistl_q} : dl_pc;
                    dlist_dirty <= 1'b0;
                    dl_ctl    <= dl_ctl_prev;                // Altirra restart
                    row_height_m1 <= ctl_height_m1(dl_ctl_prev);
                    row_ctr   <= 4'd0;
                    // The straddling line's VS state must survive the VBI:
                    // Altirra restores mDLControl = mDLControlPrev, so the
                    // "previous line" the next VS-exit compares against is
                    // the one that ran into the vertical blank.  Resetting
                    // this to 0 loses a VS->non-VS transition across the
                    // frame boundary (ACID antic_vscroll #5: a 29x blank-8
                    // list whose VS mode line straddles the VBI).
                    vs_prev   <= (dl_ctl_prev[3:0] >= 4'h2) && dl_ctl_prev[5];
                end

                // ---- counters -------------------------------------------
                hcount <= hc_next;
            end
        end
    end

endmodule

`default_nettype wire
