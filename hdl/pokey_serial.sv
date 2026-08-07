`default_nettype none
//
// pokey_serial — POKEY's OWN serial shift timing.
//
// docs/a800/HANDOFF.md 1p/1q. The register surface for the serial port already
// exists in pokey_regs (SEROUT/SERIN at $D20D, the IRQ latch bits, the SKSTAT
// inputs), but everything driving it came from the STM32 companion SPI bridge —
// i.e. from real data transport. POKEY's own timing was never modelled: no
// shift clock derived from the timers, no framing, no timing-derived status.
//
// That is exactly what ACID800 pokey_sertiming / pokey_serclock measure, and
// neither needs a peripheral at the far end. This module supplies the timing;
// the SPI bridge stays the transport for real SIO, and antic_top MUXES the two
// rather than merging them.
//
// Shift-clock source, from SKCTL[6:5] (bit 4 is not part of the selection):
//     00  external clock   — also resets the internal clock phase
//     01  timer 4
//     10  timer 4, asynchronous receive
//     11  timer 2
// pokey_sertiming uses SKCTL=$63 -> 11 -> TIMER 2, which under its AUDCTL=$78
// is the 16-bit ch1+2 pair. So this sits directly downstream of the N+7/N+4
// first-period fix in pokey_audio: if that is wrong, everything here is too.
//
// Frame: start bit (0), 8 data bits LSB first, stop bit (1) = 10 shift ticks.
//
// SEROUT handling is double-buffered, which is the point of the test:
//   * a write to $D20D lands in a HOLDING register,
//   * when the shifter goes idle the holding byte TRANSFERS into it, and that
//     transfer raises ser_out_ready_pulse (IRQ bit 4, "output data required"),
//   * ser_out_complete is a LEVEL that is high while the shifter is idle
//     (IRQ bit 3).
// pokey_sertiming asserts on exactly WHEN that transfer happens — "Serial
// output register was loaded too early / too late" — not on the bit rate.
//
`timescale 1ns/1ps

module pokey_serial (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  skctl,
    input  wire        timer2_pulse,
    input  wire        timer4_pulse,
    input  wire        ext_clk_tick,        // external shift clock (mode 00)

    // ---- transmit --------------------------------------------------------
    input  wire [7:0]  serout_byte,         // $D20D shadow
    input  wire        serout_strobe,       // 1-clk: CPU wrote $D20D

    output logic       ser_out_ready_pulse, // 1-clk: SEROUT -> shifter (bit 4)
    output logic       ser_out_complete,    // LEVEL: shifter idle    (bit 3)
    output wire        ser_out_bit,         // serial data out

    // ---- debug taps ------------------------------------------------------
    output logic [3:0] dbg_bitcnt,
    output logic       dbg_holding_valid
);

    // SKCTL[1:0] == 00 is init mode: the dividers are held, so no shift clock.
    wire init_mode = (skctl[1:0] == 2'b00);
    wire [1:0] smode = skctl[6:5];

    wire shift_tick = init_mode ? 1'b0
                    : (smode == 2'b11) ? timer2_pulse
                    : (smode == 2'b01 || smode == 2'b10) ? timer4_pulse
                    :                    ext_clk_tick;

    logic [7:0] holding_q;
    logic       holding_valid_q;
    // FORCE BREAK (SKCTL bit 7) DRIVES THE OUTPUT TO SPACE.  emu's ser_out_bit()
    // tests it before anything else, and two-tone keys timer 2 off this level,
    // so it has to be visible outside.  An idle line sits at MARK.
    logic       ser_out_bit_q;
    assign ser_out_bit = skctl[7] ? 1'b0 : ser_out_bit_q;

    logic [9:0] shifter_q;        // {stop, data[7:0], start} shifted right
    // TWENTY TICKS CARRY TEN BIT TIMES.  Each bit occupies TWO shift clocks --
    // emu indexes the frame as `i = (20 - ser_bits) / 2` -- so a ten-tick frame
    // runs the line at twice the right rate.  pokey_serclock measures it
    // directly: with ten ticks it read 20 where the timer-4 case wants 40.
    logic [4:0] bitcnt_q;         // 0 = idle, else TICKS remaining
    logic       shifting_q;

    assign dbg_bitcnt        = bitcnt_q[3:0];
    assign dbg_holding_valid = holding_valid_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            holding_q           <= 8'h00;
            holding_valid_q     <= 1'b0;
            shifter_q           <= 10'h3FF;
            bitcnt_q            <= 5'd0;
            shifting_q          <= 1'b0;
            ser_out_ready_pulse <= 1'b0;
            ser_out_complete    <= 1'b1;   // idle at reset
            ser_out_bit_q       <= 1'b1;   // mark
        end else begin
            ser_out_ready_pulse <= 1'b0;   // pulse default

            // A CPU write to SEROUT always lands in the holding register; it
            // does NOT disturb a transmission already in progress.
            if (serout_strobe) begin
                holding_q       <= serout_byte;
                holding_valid_q <= 1'b1;
            end

            // INIT MODE RESETS THE SERIAL PORT, it does not merely stop the
            // clock.  emu (pokey_timer.c:779) clears ser_bits and serout_full
            // when SKCTL[1:0] goes to 00: "The tests write skctl = 0 for
            // exactly this and say so -- 'reset serial port to force output
            // complete' -- and without it a transmission still in flight from
            // an earlier sub-test leaves SEROC deasserted for good."  That is
            // pokey_serclock's last assertion, which wants IRQST $f7 and got
            // $ff because a byte from the 15KHz section was still shifting.
            if (init_mode) begin
                shifting_q       <= 1'b0;
                bitcnt_q         <= 5'd0;
                holding_valid_q  <= 1'b0;
                ser_out_complete <= 1'b1;
            end

            if (shift_tick) begin
                if (shifting_q) begin
                    // A new bit every OTHER tick: advance when the count about
                    // to be loaded is even, which is emu's `i` stepping.
                    if (bitcnt_q == 5'd1) begin
                        shifting_q       <= 1'b0;
                        bitcnt_q         <= 5'd0;
                        ser_out_complete <= 1'b1;
                    end else begin
                        bitcnt_q <= bitcnt_q - 5'd1;
                        if (bitcnt_q[0]) begin
                            // EMIT shifter_q[1], NOT [0].  Both assignments are
                            // non-blocking, so [0] still holds the bit already on
                            // the line -- taking it re-emits that bit and puts the
                            // whole frame one position behind for ever.  The
                            // transfer tick emits the start bit from [0]; every
                            // advance after it emits the NEXT bit and then shifts,
                            // so [0] and the line agree again.  pokey_twotone
                            // catches it: its $fc frame should go three spaces
                            // then marks, and the line sat at SPACE for the whole
                            // measured window.
                            ser_out_bit_q <= shifter_q[1];
                            shifter_q     <= {1'b1, shifter_q[9:1]};
                        end
                    end
                end else if (holding_valid_q) begin
                    // shifter idle and a byte is waiting: TRANSFER.  This is
                    // the instant pokey_sertiming measures.
                    shifter_q           <= {1'b1, holding_q, 1'b0};  // stop,data,start
                    // The transfer tick ITSELF emits the start bit, so 19 of
                    // the frame's 20 ticks remain.
                    bitcnt_q            <= 5'd19;
                    shifting_q          <= 1'b1;
                    holding_valid_q     <= 1'b0;
                    ser_out_complete    <= 1'b0;
                    ser_out_ready_pulse <= 1'b1;
                    ser_out_bit_q       <= 1'b0;                     // start bit
                end
            end
        end
    end

endmodule

`default_nettype wire
