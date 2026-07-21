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
//                Bits [5:0]: CA1/CA2 control — read/write.
//                Bits [7:6]: IRQA1 / IRQA2 interrupt-status flags — READ
//                ONLY.  A write only affects [5:0]; a read returns the
//                live IRQ-flag state in [7:6].  Bit 6 (IRQA2) latches on
//                the selected edge of the CA2 line (see the CA2/CB2 block
//                below) and clears on a PORTA data read.  Bit 7 (IRQA1)
//                has no CA1 edge source wired and reads 0.  (ACID800
//                pia_irq: writing $FF to PACTL reads back $3F, not $FF;
//                the $34->$3C->$14 CA2 dance reads back $54.)
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

    // ---- 6821 CA2 / CB2 edge-detect + IRQA2 / IRQB2 flags -----------
    // (ACID800 pia_irq).  CA2/CB2 double as a programmable output OR an
    // edge-sensitive interrupt input, selected by PACTL[5] / PBCTL[5]:
    //
    //   [5]=1 OUTPUT:  [4]=1        -> CA2 follows [3] (manual level:
    //                                  $34 drives low, $3C drives high);
    //                  [4]=0,[3]=1  -> pulse mode (line idles HIGH);
    //                  [4]=0,[3]=0  -> handshake mode (line unchanged).
    //   [5]=0 INPUT:   line floats HIGH (Atari CA2 pull-up); [4] selects
    //                  the active edge (1 = low->high, 0 = high->low),
    //                  [3] enables the CPU IRQ (IRQ line to the 6502 is
    //                  not wired here — this models the flag only).
    //
    // IRQA2 (PACTL[6]) / IRQB2 (PBCTL[6]) latch on the selected edge of
    // the internal CA2/CB2 line.  An OUTPUT-mode control write clears the
    // flag, but a selected edge produced BY that same write still sets it
    // (this is how the $34->$3C low->high output transition arms IRQA2).
    // The flag clears ONLY on a read of the PORTA / PORTB DATA register
    // ($D300 / $D301) — reading PACTL/PBCTL or DDRA/DDRB leaves it set.
    // This path is self-contained: it never touches the PORTB/DDRB
    // banking state above.
    logic ca2_line_q, cb2_line_q;   // internal CA2 / CB2 line level
    logic irqa2_q,    irqb2_q;      // PACTL[6] / PBCTL[6] flags
    logic porta_rd_q, portb_rd_q;   // registered PORTA / PORTB read decode

    wire read_porta   = read_in_win && (rreg == 2'b00);
    wire read_portb   = read_in_win && (rreg == 2'b01);
    wire porta_rd_stb = read_porta && !porta_rd_q;   // fresh PORTA data read
    wire portb_rd_stb = read_portb && !portb_rd_q;   // fresh PORTB data read

    // Next CA2/CB2 line level implied by a control write of `wdata`.
    wire ca2_next = wdata[5] ? (wdata[4] ? wdata[3]              // direct output level
                                         : (wdata[3] ? 1'b1      // pulse: idles high
                                                     : ca2_line_q)) // handshake: unchanged
                             : 1'b1;                             // input: pulled high
    wire cb2_next = wdata[5] ? (wdata[4] ? wdata[3]
                                         : (wdata[3] ? 1'b1
                                                     : cb2_line_q))
                             : 1'b1;
    // Selected edge on this write (bit4 = 1 -> low->high, else high->low).
    wire ca2_edge = wdata[4] ? (~ca2_line_q &  ca2_next)
                             : ( ca2_line_q & ~ca2_next);
    wire cb2_edge = wdata[4] ? (~cb2_line_q &  cb2_next)
                             : ( cb2_line_q & ~cb2_next);

    wire pactl_wr = write_in_win && (wreg == 2'b10);
    wire pbctl_wr = write_in_win && (wreg == 2'b11);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ca2_line_q <= 1'b1;
            cb2_line_q <= 1'b1;
            irqa2_q    <= 1'b0;
            irqb2_q    <= 1'b0;
            porta_rd_q <= 1'b0;
            portb_rd_q <= 1'b0;
        end else begin
            porta_rd_q <= read_porta;
            portb_rd_q <= read_portb;

            // Port A CA2: OUTPUT write clears IRQA2 unless this write is
            // itself the selected edge; INPUT write latches a selected edge.
            if (pactl_wr) begin
                ca2_line_q <= ca2_next;
                irqa2_q    <= wdata[5] ? ca2_edge : (irqa2_q | ca2_edge);
            end
            if (porta_rd_stb) irqa2_q <= 1'b0;   // PORTA data read clears (wins)

            // Port B CB2: same shape.
            if (pbctl_wr) begin
                cb2_line_q <= cb2_next;
                irqb2_q    <= wdata[5] ? cb2_edge : (irqb2_q | cb2_edge);
            end
            if (portb_rd_stb) irqb2_q <= 1'b0;   // PORTB data read clears (wins)
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
                // PACTL / PBCTL: control bits [5:0] read back the written
                // value; the top two bits are the read-only IRQ-status flags
                // (IRQ*1 = bit 7, IRQ*2 = bit 6).  Bit 6 = the live IRQA2 /
                // IRQB2 CA2/CB2-edge flag; bit 7 (CA1/CB1) has no edge source
                // wired and reads 0.  Writing $FF reads back $3F; the CA2
                // output->input edge dance reads back $54 (bit 6 set).
                2'b10: rdata = {1'b0, irqa2_q, pactl_q[5:0]};
                2'b11: rdata = {1'b0, irqb2_q, pbctl_q[5:0]};
            endcase
        end
    end

endmodule

`default_nettype wire
