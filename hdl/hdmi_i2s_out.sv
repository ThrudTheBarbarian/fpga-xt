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
// separate chip that takes audio on its OWN pins, and the Z-Turn V2 wires three
// of them to PL bank 34 (schematic sheet 3 -> sheet 10, all through 0R links):
//
//     SiI9022A pin 45  SCK  <- I2S_SCLK       (R107)  ball T17  IO_L20P_T3_34
//     SiI9022A pin 44  WS   <- I2S_FSYNC_OUT  (R109)  ball R18  IO_L20N_T3_34
//     SiI9022A pin 41  SD0  <- I2S_Dout       (R108)  ball V17  IO_L21P_T3_DQS_34
//
// (SD1..SD3 are unconnected, SPDIF goes to ground through R110, and MCLK is not
// driven — the part runs MCLK-less, deriving its audio timing from SCK and the
// CTS it measures against TMDS.  The net names are the PS's naming convention,
// not a claim about who drives them: on this board they land on PL pins, so the
// fabric owns them.)
//
// So this module is the piece the Z-Turn needs and the rp-XT does not: a plain
// I2S transmitter.
//
// CLOCKING — WHY A FRACTIONAL ACCUMULATOR AND NOT A DIVIDER
//
// 48 kHz needs SCK = 48000 x 64 = 3.072 MHz, and clk_bus / 3.072 MHz =
// 48.828125 — not an integer.  Rounding to /49 gives 47.83 kHz, 0.35 % flat
// (~6 cents): audible on sustained tones and, worse, WRONG in a way that grows
// with playing time against a receiver told the stream is 48 kHz.  A phase
// accumulator instead makes the AVERAGE rate exactly right and pushes the error
// into +/-1 clk of edge jitter (6.7 ns on a 325 ns bit period).  That is the
// correct trade here: the SiI9022A buffers the incoming audio and generates CTS
// by measuring it against the TMDS clock, so it tolerates edge jitter but not a
// mis-stated rate.
//
// The sample itself is taken at the START of each frame from `sample_l/r` —
// whatever the mixer's latest output is.  No FIFO and no handshake, because
// there is nothing to synchronise: the mixer runs in this same clock domain, and
// WS defines the sample cadence, so the emitted rate is exactly SCK/64 by
// construction and cannot drift against the mixer.
//
// FORMAT — Philips I2S, 32-bit slots, 24-bit left-justified data
//
//   - WS low = LEFT slot, WS high = RIGHT (I2S, not left-justified).
//   - WS and SD change on the FALLING edge of SCK; the receiver samples on the
//     rising edge.
//   - One SCK of delay: the MSB appears on the second SCK of the slot, which is
//     what makes I2S I2S.  Bits 23..0 MSB first, then 8 trailing zeros pad the
//     32-bit slot.
//
// Data is two's complement.  pokey_i2s_tx emits POKEY's naturally positive
// levels as unsigned magnitudes; `signed_in` (default 0) subtracts the midpoint
// so the wire carries the AC-coupled signal the receiver expects, rather than a
// permanent positive DC offset that eats half the headroom.

`default_nettype none

module hdmi_i2s_out #(
    parameter int unsigned CLK_HZ     = 150_000_000,  // this module's clock
    parameter int unsigned SAMPLE_HZ  = 48_000,       // frames per second
    parameter int unsigned PHASE_BITS = 28            // accumulator width
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [23:0] sample_l,      // latest mixed sample, this clock domain
    input  wire [23:0] sample_r,
    input  wire        signed_in,     // 1 = samples are already two's complement

    output logic       sck,           // -> SiI9022A SCK  (ball T17)
    output logic       ws,            // -> SiI9022A WS   (ball R18)
    output logic       sd,            // -> SiI9022A SD0  (ball V17)

    output logic       frame_start    // one clk pulse at each LEFT-slot boundary
);

    // SCK toggles twice per bit, so the accumulator runs at 128 x SAMPLE_HZ.
    localparam longint unsigned TOGGLE_HZ = longint'(SAMPLE_HZ) * 128;
    localparam longint unsigned INC_L     =
        (TOGGLE_HZ * (longint'(1) << PHASE_BITS)) / longint'(CLK_HZ);
    localparam logic [PHASE_BITS-1:0] INC = PHASE_BITS'(INC_L);

    logic [PHASE_BITS:0] phase;                    // one guard bit = the wrap flag
    wire                 tick = phase[PHASE_BITS]; // high for exactly one clk per toggle

    always_ff @(posedge clk or posedge rst) begin
        if (rst) phase <= '0;
        else     phase <= {1'b0, phase[PHASE_BITS-1:0]} + {{(1){1'b0}}, INC};
    end

    // Bit position within the frame: 0..63, two SCK phases each.
    logic [5:0]  bitpos;
    logic [31:0] shreg;
    logic [23:0] lat_l, lat_r;
    // NOT declared inside the always_ff: a variable with an initialiser in a
    // procedural block is STATIC and initialised once at time zero, so it would
    // hold its start value forever and the frame would never advance.
    logic [5:0]  nxt;

    // MSB-first 24 bits, then 8 zeros: a 32-bit slot with 24 bits of data.
    function automatic logic [31:0] slot(input logic [23:0] s, input logic sgn);
        // Unsigned POKEY levels are centred by flipping the MSB — the cheapest
        // exact way to subtract half of full scale.
        logic [23:0] v = sgn ? s : {~s[23], s[22:0]};
        return {v, 8'h00};
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sck <= 1'b0; ws <= 1'b0; sd <= 1'b0;
            bitpos <= 6'd0; shreg <= 32'd0;
            lat_l <= 24'd0; lat_r <= 24'd0;
            frame_start <= 1'b0;
        end else begin
            frame_start <= 1'b0;
            if (tick) begin
                sck <= ~sck;
                if (sck) begin
                    // FALLING edge of SCK: advance the frame and drive the wire.
                    // The receiver latches on the rising edge that follows.
                    nxt    = bitpos + 6'd1;
                    bitpos <= nxt;

                    // Always shift: the bit driven at a slot boundary is the
                    // OUTGOING slot's last bit, which is precisely what makes
                    // WS lead the new slot's MSB by one SCK.  Getting this wrong
                    // costs the slot's final bit and puts WS a bit late.
                    sd    <= shreg[31];
                    shreg <= {shreg[30:0], 1'b0};

                    if (nxt == 6'd0) begin              // LEFT slot starts next
                        lat_l       <= sample_l;        // one sample pair per frame
                        lat_r       <= sample_r;        // right is held for its slot
                        shreg       <= slot(sample_l, signed_in);
                        ws          <= 1'b0;
                        frame_start <= 1'b1;
                    end else if (nxt == 6'd32) begin    // RIGHT slot starts next
                        shreg <= slot(lat_r, signed_in);
                        ws    <= 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
