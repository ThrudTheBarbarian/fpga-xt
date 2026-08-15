// hdmi_i2s_out.sv — POKEY's mixed stereo sample -> the SiI9022A's I2S audio input.
//
// WHY THIS EXISTS, AND WHY IT IS NOT pokey_i2s_tx
//
// `pokey_i2s_tx` does the MIXING (two POKEYs + the PCM1808 ADC pair, soft
// saturation) and hands out a 4-deep buffer shaped for an HDMI audio
// PACKETISER — the rp-XT board serialises nothing, because there we drive TMDS
// ourselves and the samples go straight into audio-sample packets.
//
// The Z-Turn does not work that way.  Its HDMI transmitter is an SiI9022A, a
// separate chip that takes audio on its OWN pins, and the V2 board wires four
// of them to PL bank 34 (schematic sheet 10, "HDMI", MYS-7Z010-20-V2):
//
//     SiI9022A pin 45  SCK   <- I2S_SCLK       R107 0R   ball T17
//     SiI9022A pin 44  WS    <- I2S_FSYNC_OUT  R109 0R   ball R18
//     SiI9022A pin 41  SD0   <- I2S_Dout       R108 0R   ball V17
//     SiI9022A pin 38  MCLK  <- 12MHZ          R116 0R   ball U15  (IO_L11P_T1_SRCC_34)
//
// THE FPGA OWNS MCLK, AND THAT IS THE WHOLE REASON THIS MODULE IS CLOCKED THE
// WAY IT IS.  The board has a 12 MHz oscillator (Y3) sitting next to that net,
// but its output goes through **R115, which is DNP** — the oscillator is
// isolated and drives nothing.  The only populated path onto the MCLK net is
// R116 (0R) from PL ball U15.  So MCLK is ours to generate, there is no
// contention, and nothing else drives it.
//
// That matters because in I2S mode the transmitter does NOT measure the audio
// rate off WS.  TPI 0x20[6:4] tells it the MCLK:fs ratio, and it divides MCLK
// by that to compute the CTS values it sends to the sink (TPI programmer's
// reference, "Configuring Audio using I2S").  If MCLK is absent, or is not an
// exact multiple of the real frame rate, the regenerated audio clock at the far
// end is wrong no matter how correct the bits on SD0 are.
//
// Hence: ONE audio clock, and everything integer-divided from it.
//
//     clk (MCLK) = 256 fs      also forwarded to the SiI9022A's MCLK pin
//     SCK        = clk / 4     = 64 fs   (32-bit slots, two slots per frame)
//     WS         = clk / 256   = fs
//
// A phase accumulator off clk_sys was the obvious first move and is the wrong
// one here: it makes the AVERAGE rate right while leaving MCLK either absent or
// unrelated to it, which is precisely the case the transmitter cannot handle.
// Integer division from the same root makes SCK and WS exactly MCLK/4 and
// MCLK/256 by construction, so whatever the MMCM actually produces, the ratio
// the chip is told is the ratio it gets.
//
// FORMAT — Philips I2S, 32-bit slots, 24-bit left-justified data
//
//   - WS low = LEFT slot, WS high = RIGHT (I2S, not left-justified).
//   - WS and SD change on the FALLING edge of SCK; the receiver samples on the
//     rising edge.
//   - WS leads the new slot's MSB by one SCK — so the bit driven AT a slot
//     boundary is the outgoing slot's last bit.  That one-bit delay is what
//     makes I2S I2S, and getting it wrong costs the slot's final bit.
//   - Bits 23..0 MSB first, then 8 trailing zeros pad the 32-bit slot.
//
// Data is two's complement.  pokey_i2s_tx emits POKEY's naturally positive
// levels as unsigned magnitudes; `signed_in` (default 0) flips the MSB so the
// wire carries the AC-coupled signal the receiver expects, rather than a
// permanent positive DC offset that eats half the headroom.

`default_nettype none

module hdmi_i2s_out #(
    // Frame = 2 slots x 32 bits = 64 SCK; SCK = clk/4; so clk = 256 fs.
    parameter int unsigned SCK_DIV  = 4,     // clk -> SCK
    parameter int unsigned SLOT_BITS = 32
) (
    input  wire        clk,           // the audio root: MCLK, 256 fs
    input  wire        rst,

    input  wire [23:0] sample_l,      // stable for a whole frame (see the CDC below)
    input  wire [23:0] sample_r,
    input  wire        signed_in,     // 1 = samples are already two's complement

    output logic       sck,           // -> SiI9022A SCK  (ball T17)
    output logic       ws,            // -> SiI9022A WS   (ball R18)
    output logic       sd,            // -> SiI9022A SD0  (ball V17)

    output logic       frame_start    // one clk pulse at each LEFT-slot boundary
);

    localparam int unsigned HALF     = SCK_DIV / 2;      // clks per SCK half-period
    localparam int unsigned FRAME_BITS = SLOT_BITS * 2;

    // ---- SCK generation: plain integer division, no accumulator ------------
    logic [$clog2(HALF+1)-1:0] hcnt;
    logic                      sck_edge;                 // 1 clk before each SCK toggle

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= '0; sck <= 1'b0; sck_edge <= 1'b0;
        end else if (hcnt == HALF - 1) begin
            hcnt     <= '0;
            sck      <= ~sck;
            sck_edge <= 1'b1;
        end else begin
            hcnt     <= hcnt + 1'b1;
            sck_edge <= 1'b0;
        end
    end

    // ---- frame state -------------------------------------------------------
    logic [$clog2(FRAME_BITS)-1:0] bitpos;
    logic [SLOT_BITS-1:0]          shreg;
    logic [23:0]                   lat_r;
    // NOT declared inside the always_ff: a variable with an initialiser in a
    // procedural block is STATIC and takes its value once, at time zero — it
    // would hold that value forever and the frame would never advance.
    logic [$clog2(FRAME_BITS)-1:0] nxt;

    // MSB-first 24 bits, then 8 zeros: a 32-bit slot carrying 24 bits of data.
    function automatic logic [SLOT_BITS-1:0] slot(input logic [23:0] s, input logic sgn);
        // Unsigned POKEY levels are centred by flipping the MSB — the cheapest
        // exact way to subtract half of full scale.
        logic [23:0] v;
        v = sgn ? s : {~s[23], s[22:0]};
        return {v, {(SLOT_BITS-24){1'b0}}};
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ws <= 1'b0; sd <= 1'b0;
            bitpos <= '0; shreg <= '0; lat_r <= 24'd0;
            frame_start <= 1'b0;
        end else begin
            frame_start <= 1'b0;
            // Act on the FALLING edge of SCK: sck has just been driven low, so
            // the receiver latches what we put out here on the next rise.
            if (sck_edge && !sck) begin
                nxt    = bitpos + 1'b1;
                bitpos <= nxt;

                sd    <= shreg[SLOT_BITS-1];       // outgoing slot's next bit
                shreg <= {shreg[SLOT_BITS-2:0], 1'b0};

                if (nxt == '0) begin               // LEFT slot starts next
                    lat_r       <= sample_r;       // hold right for its own slot
                    shreg       <= slot(sample_l, signed_in);
                    ws          <= 1'b0;
                    frame_start <= 1'b1;
                end else if (nxt == FRAME_BITS/2) begin   // RIGHT slot starts next
                    shreg <= slot(lat_r, signed_in);
                    ws    <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
