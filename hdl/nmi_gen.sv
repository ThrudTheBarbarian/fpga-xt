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
    // CPU ack via $D40F write clears the three flag bits; set/clear in
    // the same cycle → set wins (so a new interrupt is never lost when
    // the CPU acks late). Internally we store only the three flag bits
    // and OR in the constant $1F at the read port; this keeps the
    // comparison in nmi_n simple (`~|flags_q`) without false-positive
    // assertions from the hard-coded low bits.
    wire dli_set = line_start && cur_row_dli && nmien[7];
    wire vbi_set = vbi_start                 && nmien[6];

    logic [7:0] flags_q;        // bits 5..7 carry state, others 0

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            flags_q <= 8'h00;
        end else begin
`ifdef NMI_GEN_TRACE
            if (nmires_strobe || dli_set || vbi_set)
                $display("[nmi_gen] t=%0t flags=$%02h ack=%b dli=%b vbi=%b → next=$%02h",
                         $time, flags_q, nmires_strobe, dli_set, vbi_set,
                         (nmires_strobe ? 8'h00 : flags_q)
                         | (dli_set ? 8'h80 : 8'h00)
                         | (vbi_set ? 8'h40 : 8'h00));
`endif
            flags_q <= (nmires_strobe ? 8'h00 : flags_q)
                     | (dli_set ? 8'h80 : 8'h00)
                     | (vbi_set ? 8'h40 : 8'h00);
        end
    end

    // External NMIST view: flag bits in 5..7, constant 1s in 0..4.
    assign nmist_q = flags_q | 8'h1F;

    // /NMI is active-low; held low while any unacked flag bit is set
    // (the constant low bits don't participate in the IRQ test). CPU
    // ack clears flags_q → /NMI deasserts on the next cycle.
    assign nmi_n = ~|flags_q;

endmodule

`default_nettype wire
