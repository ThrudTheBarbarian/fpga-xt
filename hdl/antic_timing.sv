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
    parameter [6:0] RELEASE_CYCLE = 7'd102,  // first executed CPU cycle = 103 (Avery: mva ;*=103,104..)
    parameter [8:0] VBI_LINE      = 9'd248,
    parameter [8:0] RESTART_LINE  = 9'd8      // first display line
) (
    input  wire        clk,          // clk_sally
    input  wire        rst,
    input  wire        phi2_tick,    // machine-cycle grid (the tick the fid core paces on)

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
    logic [7:0] dmactl_q, nmien_q, vscrol_q;
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
    logic        cap_inst, cap_lo, cap_hi;   // sample mem_rdata at end of cycle

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

    always_comb begin
        if (dl_inst_slot || dl_lo_slot || dl_hi_slot) cycle_type = CT_DL;
        else if (pm_missile || pm_player)             cycle_type = CT_PM;
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
            dmactl_q <= 8'h00; nmien_q <= 8'h00; vscrol_q <= 8'h00;
            dlistl_q <= 8'h00; dlisth_q <= 8'h00;
            wsync_armed <= 1'b0; dlist_dirty <= 1'b1;
            hcount <= 7'd0; line <= 9'd0;
            dl_ctl <= 8'h00; dl_ctl_prev <= 8'h00; dl_pc <= 16'h0000;
            row_ctr <= 4'd0; row_height_m1 <= 4'd0;
            dl_active <= 1'b0; need_inst <= 1'b0; need_addr <= 1'b0; is_jvb <= 1'b0;
            vs_prev <= 1'b0; vs_latch6 <= 4'd0; vs_latch109 <= 4'd0;
            inst_q <= 8'h00; addr_lo_q <= 8'h00;
            cap_inst <= 1'b0; cap_lo <= 1'b0; cap_hi <= 1'b0;
            nmist_hi <= 2'b00; nmi_ext <= 1'b0; nmi_n <= 1'b1;
            wsync_latch_n <= 1'b1; rdy_n_q <= 1'b1;
        end else begin
            // ---------- register snoop (every clk, zero latency) ----------
            if (reg_we) begin
                case (reg_addr)
                    4'h0: dmactl_q <= reg_wdata;
                    4'h2: begin dlistl_q <= reg_wdata; dlist_dirty <= 1'b1; end
                    4'h3: begin dlisth_q <= reg_wdata; dlist_dirty <= 1'b1; end
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
                // ---- capture the cycle's DL fetch data (end of cycle) ---
                if (cap_inst) begin inst_q    <= mem_rdata; cap_inst <= 1'b0; end
                if (cap_lo)   begin addr_lo_q <= mem_rdata; cap_lo   <= 1'b0; end
                if (cap_hi) begin
                    cap_hi <= 1'b0;
                    need_addr <= 1'b0;
                    if (is_jvb) begin
                        dl_pc <= {mem_rdata, addr_lo_q};
                        if (inst_q[6]) dl_active <= 1'b0;    // JVB parks
                        is_jvb <= 1'b0;
                    end
                    // (LMS target: renderer's concern in phases 1-3)
                end
                if (dl_inst_slot) begin
                    cap_inst <= 1'b1;
                    dl_pc <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
                end
                if (dl_lo_slot) begin
                    cap_lo <= 1'b1;
                    dl_pc <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
                end
                if (dl_hi_slot) begin
                    cap_hi <= 1'b1;
                    dl_pc <= {dl_pc[15:10], dl_pc[9:0] + 10'd1};
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

                // ---- /NMI pulse shaping + entering cycle 7: NMIST -------
                // (trigger below overrides — trigger wins on the same tick)
                if (nmi_ext) begin nmi_ext <= 1'b0; nmi_n <= 1'b0; end
                else               nmi_n   <= 1'b1;

                if (hc_next == 7'd7) begin
                    if (line == VBI_LINE) begin
                        nmist_hi <= 2'b01;
                        if (nmien_q[6]) begin nmi_n <= 1'b0; nmi_ext <= 1'b1; end
                        dl_ctl_prev <= dl_ctl;               // save across the VBI
                        dl_ctl      <= dl_ctl & 8'h20;       // VS survives
                    end else if (dl_ctl[7] && (row_ctr == stop_dli)) begin
                        // DLI: fires for mode lines, blank+DLI lines, and the
                        // parked JVB wait region alike (Race In Space).
                        nmist_hi <= 2'b10;
                        if (nmien_q[7]) begin nmi_n <= 1'b0; nmi_ext <= 1'b1; end
                    end
                end

                // ---- WSYNC latch + /RDY (clear beats set) ---------------
                if (hc_next == RELEASE_CYCLE) wsync_latch_n <= 1'b1;
                else if (wsync_armed)         wsync_latch_n <= 1'b0;
                wsync_armed <= 1'b0;
                rdy_n_q     <= wsync_latch_n;

                // ---- entering cycle 111: line advance (VCOUNT) ----------
                if (hc_next == 7'd111)
                    line <= (line == 9'd261) ? 9'd0 : line + 9'd1;

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
                    vs_prev   <= 1'b0;
                end

                // ---- counters -------------------------------------------
                hcount <= hc_next;
            end
        end
    end

endmodule

`default_nettype wire
