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

    // Event ticks (1-cycle pulses).  STATUS ticks lead the NMI ticks by two
    // machine cycles: real ANTIC latches the NMIST cause bit at ~cycle 6 of
    // the scan line and pulls /NMI at cycle 8 (ACID800 antic_nmist's
    // cycle-exact checks: bit not set at a read ending cycle 5, set by a
    // read ending cycle 6; Altirra updates NMIST at its cycle-7 slot).
    input  wire        status_tick,      // every-machine-cycle tick: NMIRES apply boundary
    input  wire        vbi_status,       // VBI cause -> NMIST bit, cycle-6 tick
    input  wire        vbi_start,        // VBI /NMI pulse, cycle-8 tick
    input  wire        line_status,      // DLI cause -> NMIST bit, cycle-6 tick
    input  wire        line_start,       // DLI /NMI pulse, cycle-8 tick

    // From dl_parser (combinational read of line_dli at current row).
    output logic [7:0] cur_row,
    input  wire        cur_row_dli,

    // From vbeam.
    input  wire  [7:0] atari_row_in,

    // To antic_regs read mux.
    output logic [7:0] nmist_q,

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
    wire dli_event = line_status && cur_row_dli;         // NMIST status (cycle 7)
    wire vbi_event = vbi_status;                          // NMIST status (cycle 7)
    // The NMIEN gate is SAMPLED AT THE STATUS TICK and used at the /NMI tick:
    // real ANTIC commits the NMI decision with the status latch, so an NMIEN
    // disable landing after that boundary cannot suppress the pulse (ACID800:
    // write at cycle 5 blocks the VBI, write at cycle 6 does not — 'VBI was
    // deactivated by write to NMIEN on cycle 6' when gating live at cycle 8).
    logic dli_arm_q, vbi_arm_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dli_arm_q <= 1'b0;
            vbi_arm_q <= 1'b0;
        end else begin
            if (dli_event) dli_arm_q <= nmien[7];
            if (vbi_event) vbi_arm_q <= nmien[6];
        end
    end
    wire dli_nmi   = line_start && cur_row_dli && dli_arm_q; // /NMI (cycle 8, armed @7)
    wire vbi_nmi   = vbi_start && vbi_arm_q;                 // /NMI (cycle 8, armed @7)

    logic [7:0] flags_q;        // bits 6..7 carry the last cause, others 0

    // NMIRES is applied with MACHINE-CYCLE arbitration: the strobe (an
    // asynchronous-within-the-cycle CDC pulse) pends until the status tick
    // boundary, where a same-cycle DLI/VBI status event WINS — real ANTIC's
    // new cause survives an NMIRES landing on the same machine cycle
    // (ACID800 antic_nmist NMIRES-timing: 'VBI bit was reset too early'
    // when the raw strobe order let the clear beat the cycle-7 set).
    logic nmires_pend;
    logic set_cycle_q;   // a cause bit set at the last status tick; high for
                         // that whole machine cycle — an NMIRES strobed within
                         // it LOSES outright (real ANTIC: the write cycle that
                         // coincides with the set cannot clear the fresh bit;
                         // ACID800 'VBI bit was reset too early' with the
                         // strobe landing after the tick inside the set cycle)
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                          set_cycle_q <= 1'b0;
        else if (dli_event || vbi_event)  set_cycle_q <= 1'b1;
        else if (status_tick)             set_cycle_q <= 1'b0;
    end
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                 nmires_pend <= 1'b0;
        else if (dli_event || vbi_event) nmires_pend <= 1'b0;  // set wins; consume
        else if (status_tick && nmires_pend) nmires_pend <= 1'b0;  // applied below
        else if (nmires_strobe && !set_cycle_q) nmires_pend <= 1'b1;
    end

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
            else if (status_tick && nmires_pend) flags_q <= 8'h00;  // CPU ack, tick-aligned
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

endmodule

`default_nettype wire
