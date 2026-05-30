// pia_regs.sv — Atari PIA shadow at $D300-$D37F (M25-1).
//
// Implements the four PIA registers (PORTA / PORTB / PACTL / PBCTL)
// at the Atari hardware page $D300-$D303, mirrored every 4 bytes
// through $D37F. Cache-control registers at $D380-$D3FF (cache_regs)
// share the same $D3 page but are split out by address bit 7.
//
//   $D300 PORTA  read:  pin level (port mode)     / porta_ddr_q (DDR mode)
//                write: porta_out_latch (port)    / porta_ddr_q (DDR mode)
//   $D301 PORTB  read:  pin level (port mode)     / portb_ddr_q (DDR mode)
//                write: portb_out_latch (port)    / portb_ddr_q (DDR mode)
//   $D302 PACTL  bit 2 = 1 → port-A in port mode (read returns pins);
//                       0 → port-A in DDR mode (read returns DDRA).
//                Other bits: CA1/CA2 control + IRQA flags. Writeable;
//                read-only mirroring of IRQ flags is not modelled.
//   $D303 PBCTL  same shape as PACTL but for port B.
//
// Mode select (PACTL[2] / PBCTL[2]):
//   1 = port mode (the common Atari OS configuration). Reads return
//       the live pin level; writes go to the output latch.
//   0 = DDR mode. Reads return the DDR latch; writes update DDRA/B.
//
// Bidirectional joystick pins (PIA proper):
//   PORTA / PORTB are genuinely bidirectional per-bit — each DDR bit
//   controls one pin's direction. Period accessories like the XEP80
//   80-column adapter, mouse adapters, and bit-banged serial gadgets
//   used the joystick ports for output as well as input. We expose
//   `joy_porta_out[7:0]` (= porta_out_latch_q) + `joy_porta_oe[7:0]`
//   (= porta_ddr_q) and the matching pair for PORTB so the synth-time
//   pad wrapper can build a per-bit tristate (drive when oe[i]=1,
//   release when oe[i]=0). The PORTA/PORTB read path returns the
//   live `joy_porta_in[i]` pin level — for an output bit that's the
//   FPGA's own driven value looped back through the level shifter,
//   for an input bit that's the external pin state.
//
// PORTB special case:
//   On 130XE-class machines the upper bits of PORTB (4-7) double as
//   memory-bank-select control regardless of PBCTL[2] — software writes
//   $D301 to flip banks. We expose `portb_out_q` (the registered byte
//   most recently written to $D301) so bank_translator sees the live
//   banking state. This subsumes the standalone portb_q latch that
//   previously lived in antic_top.
//
// Mirror window:
//   $D300-$D37F is decoded by addr[15:8]==$D3 && addr[7]==0; within
//   that, the low 2 bits of the address pick the register (mirrors of
//   $D300-$D303 every 4 bytes — matches the real 6520/6821 PIA).

`default_nettype none

module pia_regs (
    input  wire        clk,
    input  wire        rst,

    // Snoop write port — registered from bus_snoop.
    input  wire        we,         // snoop_we_pia
    input  wire [15:0] waddr,      // snoop_addr (only [1:0] matters within $D300-$D37F)
    input  wire [7:0]  wdata,

    // Read port — combinational off the live SALLY hwreg address.
    input  wire [15:0] raddr,
    output logic [7:0] rdata,

    // Joystick pin shadow — packed live pin states, one byte per port.
    // PORTA carries sticks 0 + 1 (bits 0-3 / 4-7); PORTB carries
    // sticks 2 + 3 in 800-class hardware (XL/XE drop sticks 2+3 in
    // favour of banking control on the same physical pins). Default
    // for sim / unwired = 8'hFF (all directions released).
    input  wire [7:0]  joy_porta_in,
    input  wire [7:0]  joy_portb_in,

    // PORTA / PORTB driven outputs — the synth-time pad wrapper
    // tristates the bidirectional pin per bit using `joy_porta_oe[i]`
    // / `joy_portb_oe[i]` (= DDRA[i] / DDRB[i] when the matching
    // control register is in port mode; 0 in DDR mode so the pin
    // floats). XEP80 / mouse / serial-bit-bang accessories rely on
    // this — they write DDRA[i]=1 + the bit value into PORTA[i] and
    // toggle the line.
    output wire [7:0]  joy_porta_out,
    output wire [7:0]  joy_porta_oe,
    output wire [7:0]  joy_portb_out,
    output wire [7:0]  joy_portb_oe,

    // PORTB output latch — drives bank_translator's PORTB[3:2] /
    // PORTB[4] regardless of PBCTL[2] (130XE banking semantics).
    output wire [7:0]  portb_out_q
);

    // ---- Address decode ---------------------------------------------
    // $D300-$D37F (PIA window). Within: low 2 bits of address pick
    // PORTA / PORTB / PACTL / PBCTL.
    localparam logic [8:0] WIN_PREFIX = 9'b1101_0011_0;  // $D300-$D37F
    wire write_in_win = we && (waddr[15:7] == WIN_PREFIX);
    wire read_in_win  = (raddr[15:7] == WIN_PREFIX);
    wire [1:0] wreg = waddr[1:0];
    wire [1:0] rreg = raddr[1:0];

    // ---- Register storage -------------------------------------------
    logic [7:0] porta_ddr_q, portb_ddr_q;
    logic [7:0] porta_out_latch_q, portb_out_latch_q;
    logic [7:0] pactl_q,     pbctl_q;

    assign portb_out_q = portb_out_latch_q;

    // Bidirectional joystick-pin driving signals. The OE follows the
    // DDR latch only when the matching control register is in port
    // mode (PACTL[2] / PBCTL[2] = 1) — in DDR mode the pin is always
    // floating from the FPGA's perspective (the chip is busy reading
    // the DDR latch back to the bus instead of acting as a port).
    assign joy_porta_out = porta_out_latch_q;
    assign joy_porta_oe  = pactl_q[2] ? porta_ddr_q : 8'h00;
    assign joy_portb_out = portb_out_latch_q;
    assign joy_portb_oe  = pbctl_q[2] ? portb_ddr_q : 8'h00;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            porta_ddr_q       <= 8'h00;
            portb_ddr_q       <= 8'h00;
            porta_out_latch_q <= 8'hFF;
            portb_out_latch_q <= 8'hFF;     // matches the antic_top default for banking
            pactl_q           <= 8'h00;
            pbctl_q           <= 8'h00;
        end else if (write_in_win) begin
            unique case (wreg)
                2'b00: begin
                    if (pactl_q[2]) porta_out_latch_q <= wdata;   // port mode
                    else            porta_ddr_q       <= wdata;   // DDR mode
                end
                2'b01: begin
                    // Match the PORTA case + real PIA: a $D301 write updates the
                    // OUTPUT LATCH only in PORT mode (PBCTL[2]=1); in DDR mode it
                    // writes DDRB.  The XL OS IHW1 init ($C4E0) clears the whole
                    // $D3xx page in DDR mode — it skips the literal $D301 but NOT
                    // its mirrors ($D305/$D309/...), which decode to PORTB.  Those
                    // must go to DDRB, not clobber the PORTB output latch, else
                    // bit0 (OS-ROM-enable) switches off mid-boot and the OS, now
                    // fetching RAM, crashes into a BRK/IRQ loop.  130XE banking
                    // writes $D301 in port mode (PBCTL[2]=1 after OS init), so it
                    // still latches the bank-select bits as before.
                    if (pbctl_q[2]) portb_out_latch_q <= wdata;   // port mode
                    else            portb_ddr_q       <= wdata;   // DDR mode
                end
                2'b10: pactl_q <= wdata;
                2'b11: pbctl_q <= wdata;
            endcase
        end
    end

    // ---- Read mux ---------------------------------------------------
    always_comb begin
        rdata = 8'h00;
        if (read_in_win) begin
            unique case (rreg)
                // Port mode (CTL[2]=1): real PIA returns the PIN level — for an
                // OUTPUT bit (DDR=1) that's the driven output latch, for an INPUT
                // bit (DDR=0) the external pin.  DDR mode returns the DDR latch.
                // (Without the output-latch term, reading back a port the OS just
                // drove high returns open-bus, and the XL OS RMW of PORTB lands on
                // a self-test value — see tb_boot.)
                2'b00: rdata = pactl_q[2] ? ((porta_out_latch_q & porta_ddr_q) | (joy_porta_in & ~porta_ddr_q)) : porta_ddr_q;
                2'b01: rdata = pbctl_q[2] ? ((portb_out_latch_q & portb_ddr_q) | (joy_portb_in & ~portb_ddr_q)) : portb_ddr_q;
                2'b10: rdata = pactl_q;
                2'b11: rdata = pbctl_q;
            endcase
        end
    end

endmodule

`default_nettype wire
