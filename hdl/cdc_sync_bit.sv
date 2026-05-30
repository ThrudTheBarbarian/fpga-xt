// cdc_sync_bit.sv — 2-FF synchroniser for single-bit CDC crossings.
//
// Standard 2-flop synchroniser for level signals crossing from src_clk
// to dst_clk.  MTBF at Zynq-7020 -2 speeds (121 → 162 MHz) is well into
// the billions of years for a 2-FF chain on a single-bit toggle.
//
// Usage:
//   cdc_sync_bit #(.WIDTH(4)) u_sync_irq (
//       .dst_clk  (clk_sally),
//       .src_sig  ({nmi_n, irq_n, halt_n, rdy_n}),
//       .dst_sig  ({nmi_n_sync, irq_n_sync, halt_n_sync, rdy_n_sync})
//   );

`default_nettype none

module cdc_sync_bit #(
    parameter int WIDTH = 1
) (
    input  wire              dst_clk,
    input  wire [WIDTH-1:0]  src_sig,
    output wire [WIDTH-1:0]  dst_sig
);

    logic [WIDTH-1:0] sync_ff0, sync_ff1;

    always_ff @(posedge dst_clk) begin
        sync_ff0 <= src_sig;
        sync_ff1 <= sync_ff0;
    end

    assign dst_sig = sync_ff1;

endmodule

`default_nettype wire
