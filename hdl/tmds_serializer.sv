// tmds_serializer.sv — 10:1 LSB-first serializer for TMDS output.
//
// Sim-portable shift-register implementation. Drives one TMDS lane
// (one of R/G/B/clock). Runs on the bit clock (10× pixel rate); the
// upstream encoder produces a fresh `symbol` once per pixel cycle
// (= 10 bit clocks). The serializer captures `symbol` at bit_phase=9
// and shifts it out LSB-first over the next 10 cycles.
//
// On Topaz the production build replaces this with the HSIO LVDS
// SERDES primitive — it accepts the parallel 10-bit word at pixel
// rate and clocks out the serial stream from the SERDES hard logic,
// dropping the burden of running fabric at 250-400 MHz. Placeholder:
// `ifdef EFINITY around the body so the structural sim version stays
// in iverilog/Verilator and the vendor primitive maps in synth.
//
// Bit ordering: DVI 1.0 §4 specifies LSB-first transmission, so
// symbol[0] is sent first.

`default_nettype none

module tmds_serializer (
    input  wire        bit_clk,        // 10× pixel clock
    input  wire        rst,
    input  wire  [9:0] symbol,          // captured at bit_phase=9
    output wire        serial_out,
    output logic [3:0] bit_phase        // 0..9 modulo
);

`ifdef EFINITY
    // Placeholder — instantiate the Topaz LVDS SERDES primitive here
    // (e.g. EFX_LVDS_OBUF_SERDES or HSIO IP) once the synth flow is
    // wired up. Until then this branch is empty so any accidental
    // EFINITY define triggers an unbound-output error rather than
    // silently emitting junk.
`else
    logic [9:0] shift;

    always_ff @(posedge bit_clk or posedge rst) begin
        if (rst) begin
            bit_phase <= 4'd0;
            shift     <= 10'h0;
        end else if (bit_phase == 4'd9) begin
            // Last bit of current symbol just emitted; load next.
            shift     <= symbol;
            bit_phase <= 4'd0;
        end else begin
            shift     <= {1'b0, shift[9:1]};
            bit_phase <= bit_phase + 4'd1;
        end
    end

    assign serial_out = shift[0];
`endif

endmodule

`default_nettype wire
