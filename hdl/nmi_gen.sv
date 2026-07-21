// nmi_gen.sv — NMI generator. Pulses /NMI at start-of-VBI (NMIEN[6])
// and at the start of any DL line whose dl_parser metadata has the
// DLI bit set (NMIEN[7]). Holds /NMI low until the CPU acks via a
// $D40F write (nmires_strobe).
//
// Inputs are expected to be in the bus_clk domain; vbi_start /
// line_start come from vbeam (clk_pix). For first cut they're sampled
// directly — proper CDC with 2-FF synchronisers + edge detection is
// M19 polish. Acceptable for sim because vbeam pulses are 1 clk_pix
// wide and our bus_clk happens to be the same domain in the testbench.

`default_nettype none

module nmi_gen (
    input  wire        clk,
    input  wire        rst,

    // From antic_regs.
    input  wire  [7:0] nmien,            // $D40E
    input  wire        nmires_strobe,    // pulses on $D40F write

    // From vbeam (1-cycle pulses).
    input  wire        vbi_start,        // start of vertical blank
    input  wire        line_start,       // start of a new atari row

    // From dl_parser (combinational read of line_dli at current row).
    output logic [7:0] cur_row,
    input  wire        cur_row_dli,

    // From vbeam.
    input  wire  [7:0] atari_row_in,

    // From antic_raster (display scanline, for DLI correlation diag).
    input  wire  [8:0] scanline_in,

    // To antic_regs read mux.
    output logic [7:0] nmist_q,

    // TEMP DLI-debug instrumentation (clk_bus). See DIAG12/DIAG13 @ GP0.
    //   dbg_nmi0 = {dli_nmi_count[7:0], vbi_nmi_count[7:0],
    //              dli_event_count[7:0], last_nmist[7:0]}
    //   dbg_nmi1 = {nmien[7:0], last_dli_scanline[7:0], nmi_assert_count[15:0]}
    output logic [31:0] dbg_nmi0,
    output logic [31:0] dbg_nmi1,

    // To CPU bus (active-low).
    output wire        nmi_n
);

    // Drive dl_parser's dli_row read port with the row vbeam is about
    // to enter. line_start fires one cycle into that row, so we want
    // dli_at to reflect line_dli[atari_row_in] on the line_start
    // cycle — atari_row_in is itself registered by vbeam, no offset
    // needed.
    assign cur_row = atari_row_in;

    // NMI status latches.
    //   bit 7 = DLI fired
    //   bit 6 = VBI fired
    //   bit 5 = ResetKey fired (unused — tied 0)
    //   bits 4..0 = always 1 (Altirra §14.6 NMIST layout)
    //
    // NMIST presents the cause of the MOST RECENT NMI ("last NMI"
    // semantics), NOT an accumulation. This is REQUIRED by the real XL
    // OS NMI handler ($C018), which dispatches with:
    //     BIT NMIST ; BPL vbi ; JMP (VDSLST)   ; DLI
    // and the user DLI path (JMP (VDSLST)) RTIs WITHOUT touching NMIRES —
    // only the VBI path writes NMIRES ($D40F). So when a VBI NMI is taken
    // the DLI bit MUST already read 0, otherwise the OS mis-dispatches
    // every VBI as a DLI, the VBI body (and its NMIRES) never runs, and
    // the whole NMI system wedges (observed: NMIST stuck $DF, DLI handler
    // never executes, per-scanline colour/font switches frozen). Hence a
    // VBI event clears the DLI bit and vice-versa; NMIRES clears both.
    // DLI/VBI never coincide on real ANTIC — give VBI priority on a tie so
    // its NMIRES path always runs.
    //
    // The DLI/VBI trigger (line_start / vbi_start) is driven by antic_top's
    // cycle-8 strobe — real ANTIC raises the NMI at machine cycle 8 of the
    // scan line, not cycle 0.  See antic_top's cycle_8_pulse wiring.
    //
    // NMIST status vs /NMI assertion are DECOUPLED: real ANTIC latches the
    // NMIST status bit on the DLI/VBI EVENT *regardless* of NMIEN — NMIEN
    // gates only the /NMI line to the CPU, not the status flag (ACID800
    // antic_nmist: "DLI bit set in NMIST with DLIs disabled", "VBI bit set
    // in NMIST with VBIs disabled").  So flags_q sets on the event; the
    // /NMI pulse (nmi_lo_ctr below) is what stays gated by nmien[7]/nmien[6].
    wire dli_event = line_start && cur_row_dli;   // NMIST status event
    wire vbi_event = vbi_start;                    // NMIST status event
    wire dli_nmi   = dli_event && nmien[7];         // /NMI assertion (gated)
    wire vbi_nmi   = vbi_event && nmien[6];         // /NMI assertion (gated)

    logic [7:0] flags_q;        // bits 6..7 carry the last cause, others 0

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            flags_q <= 8'h00;
        end else begin
`ifdef NMI_GEN_TRACE
            if (nmires_strobe || dli_event || vbi_event)
                $display("[nmi_gen] t=%0t flags=$%02h ack=%b dli=%b vbi=%b",
                         $time, flags_q, nmires_strobe, dli_event, vbi_event);
`endif
            if      (vbi_event)     flags_q <= 8'h40;  // VBI: present bit6, clear DLI
            else if (dli_event)     flags_q <= 8'h80;  // DLI: present bit7, clear VBI
            else if (nmires_strobe) flags_q <= 8'h00;  // CPU ack (VBI path)
        end
    end

    // External NMIST view: last-cause bits in 6..7, constant 1s in 0..4.
    assign nmist_q = flags_q | 8'h1F;

    // /NMI is a PULSE, not a held level. The 6502 latches NMI on the
    // high→low edge, so every DLI/VBI event must produce a fresh falling
    // edge. The old design held /NMI = ~|flags_q, but the DLI dispatch
    // path never writes NMIRES, so the first un-acked DLI flag pinned /NMI
    // low forever and no further NMI was ever taken (root cause of the
    // frozen interrupts above). We therefore assert /NMI low for a fixed
    // window per event, decoupled from flags_q.
    //
    // The window must span at least one machine cycle of the SLOWEST core:
    // the fidelity core samples /NMI once per ~1.79 MHz machine cycle
    // (~560 ns), so a sub-560 ns pulse could fall entirely between two of
    // its samples and be missed. 256 clk_bus cycles (~1.9 µs @133 MHz)
    // covers ~3 such machine cycles yet is far below the ≥63 µs between
    // real DLI/VBI events, so successive pulses never merge into one edge.
    localparam int unsigned NMI_LOW_CYCLES = 256;
    logic [7:0] nmi_lo_ctr;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                     nmi_lo_ctr <= 8'd0;
        else if (dli_nmi || vbi_nmi) nmi_lo_ctr <= 8'd255;   // (re)assert low
        else if (nmi_lo_ctr != 8'd0) nmi_lo_ctr <= nmi_lo_ctr - 8'd1;
    end
    assign nmi_n = (nmi_lo_ctr == 8'd0);

    // ---- TEMP DLI-debug instrumentation (pure observation) --------------
    // Debugging: on HW, VBI NMIs work (RTCLOK advances) but DLI NMIs never
    // reach their handler. These counters/latches make the DLI path visible
    // over GP0 (DIAG12/DIAG13). They only READ the existing event/flag/NMI
    // signals — no signal that drives ANTIC/CPU behaviour depends on them.
    //
    //   dli_nmi_count   : # of gated DLI /NMI assertions (dli_event & NMIEN[7])
    //   vbi_nmi_count   : # of gated VBI /NMI assertions (vbi_event & NMIEN[6])
    //   dli_event_count : # of DLI events DETECTED, regardless of NMIEN[7]
    //   last_nmist      : NMIST (external view) sampled the cycle after the
    //                     last /NMI assertion, i.e. flags_q settled to the cause
    //   last_dli_scan   : antic_raster scanline latched when a DLI event fires
    //   nmi_assert_cnt  : total DLI+VBI /NMI assertions
    logic [7:0]  dli_nmi_count;
    logic [7:0]  vbi_nmi_count;
    logic [7:0]  dli_event_count;
    logic [7:0]  last_nmist;
    logic [7:0]  last_dli_scan;
    logic [15:0] nmi_assert_cnt;
    logic        nmi_assert_d;   // 1-cycle delayed assertion, to sample settled flags_q

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dli_nmi_count   <= 8'd0;
            vbi_nmi_count   <= 8'd0;
            dli_event_count <= 8'd0;
            last_nmist      <= 8'd0;
            last_dli_scan   <= 8'd0;
            nmi_assert_cnt  <= 16'd0;
            nmi_assert_d    <= 1'b0;
        end else begin
            if (dli_nmi)   dli_nmi_count   <= dli_nmi_count   + 8'd1;
            if (vbi_nmi)   vbi_nmi_count   <= vbi_nmi_count   + 8'd1;
            if (dli_event) begin
                dli_event_count <= dli_event_count + 8'd1;
                last_dli_scan   <= scanline_in[7:0];
            end
            if (dli_nmi || vbi_nmi) nmi_assert_cnt <= nmi_assert_cnt + 16'd1;
            // Sample NMIST one cycle after assertion so flags_q reflects THIS
            // event's cause (flags_q is written on the same edge as the event).
            nmi_assert_d <= (dli_nmi || vbi_nmi);
            if (nmi_assert_d) last_nmist <= nmist_q;
        end
    end

    assign dbg_nmi0 = {dli_nmi_count, vbi_nmi_count, dli_event_count, last_nmist};
    assign dbg_nmi1 = {nmien, last_dli_scan, nmi_assert_cnt};

endmodule

`default_nettype wire
