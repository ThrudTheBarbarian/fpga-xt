`timescale 1ns/1ps
`default_nettype none
//
// tb_hdmi_i2s — does hdmi_i2s_out actually speak I2S, at the right rate?
//
// The SiI9022A is a real receiver on the other end of three PL pins, and there
// is no way to see what it thinks of our waveform except by looking at a screen
// with a speaker attached — a slow, ambiguous instrument.  So decode the wire
// here instead, with a receiver written to the SPEC rather than to the
// transmitter: sample SD on the RISING edge of SCK, take the slot from WS, and
// expect the MSB one SCK AFTER the WS transition.  If the transmitter and this
// bench agree, the bit-level contract is met; if they disagree, one of them is
// wrong about I2S and that is exactly what needs finding before a bitstream.
//
// Three things are checked, and each of them is a way the audio could be wrong
// while looking plausible on a scope:
//
//   1. FRAME RATE — the average must be the declared 48 kHz.  The clock does
//      not divide evenly (150 MHz / 3.072 MHz = 48.828125), so the accumulator
//      is the only thing keeping the rate honest; a plain divider would be
//      0.35 % flat and drift against the CTS the receiver derives.
//   2. SLOT ORDER AND POLARITY — WS low = LEFT.  Getting this backwards swaps
//      the channels, which is inaudible on mono material and therefore exactly
//      the sort of bug that ships.
//   3. ROUND TRIP — the decoded 24-bit value must equal what was presented,
//      including the unsigned->two's-complement centring.  A wrong centring
//      costs 6 dB of headroom and adds a DC step at every sample.
//
module tb_hdmi_i2s;

    localparam int unsigned CLK_HZ    = 150_000_000;
    localparam int unsigned SAMPLE_HZ = 48_000;
    localparam real         HALF_NS   = 500.0e6 / real'(CLK_HZ);  // half period, ns

    logic clk = 0, rst = 1;
    always #(HALF_NS) clk = ~clk;

    logic [23:0] sample_l = 24'h000000, sample_r = 24'h000000;
    wire         sck, ws, sd, frame_start;

    hdmi_i2s_out #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) dut (
        .clk(clk), .rst(rst),
        .sample_l(sample_l), .sample_r(sample_r), .signed_in(1'b0),
        .sck(sck), .ws(ws), .sd(sd), .frame_start(frame_start)
    );

    // ---- receiver: written to the I2S spec, not to the transmitter ---------
    // WS leads the new slot's MSB by one SCK, so the bit sampled AT a WS change
    // is the last bit of the slot that is ending.  A receiver that instead
    // treats it as the first bit of the new slot loses a bit and rotates every
    // sample — which is why this is decoded from the spec, not from the DUT.
    logic        sck_q = 0, ws_q = 0;
    int          bitcnt = 0;
    logic [31:0] rx = 0;
    logic [23:0] got_l, got_r;
    int          n_left = 0, n_right = 0;
    logic        started = 0;
    // Declared OUT here on purpose: a variable with an initialiser inside a
    // procedural block is static and gets its value once, at time zero.
    logic [31:0] full;

    always @(posedge clk) begin
        sck_q <= sck;
        if (sck && !sck_q) begin                       // rising edge of SCK
            full = {rx[30:0], sd};
            if (ws != ws_q) begin                      // this bit ENDS the old slot
                if (started && bitcnt == 31) begin
                    if (ws_q == 1'b0) begin got_l = full[31:8]; n_left++;  end
                    else              begin got_r = full[31:8]; n_right++; end
                end
                ws_q    <= ws;
                started <= 1'b1;
                bitcnt  <= 0;
                rx      <= 32'd0;
            end else begin
                rx     <= full;
                bitcnt <= bitcnt + 1;
            end
        end
    end

    // ---- frame-rate measurement -------------------------------------------
    realtime t_first = 0, t_last = 0;
    int      frames  = 0;
    always @(posedge clk) if (frame_start) begin
        if (frames == 0) t_first = $realtime;
        t_last = $realtime;
        frames++;
    end

    // centring: unsigned in, MSB flipped on the wire
    function automatic logic [23:0] centred(input logic [23:0] v);
        return {~v[23], v[22:0]};
    endfunction

    int errors = 0;
    task automatic expect_eq(input string what, input logic [23:0] a, input logic [23:0] b);
        if (a !== b) begin
            $display("  FAIL %-22s got $%06h want $%06h", what, a, b);
            errors++;
        end else
            $display("  ok   %-22s $%06h", what, a);
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;

        // A value with bits in every byte, so a rotate or a byte swap shows up.
        sample_l = 24'hA5_3C_7E;
        sample_r = 24'h12_34_56;

        // let a good number of frames go by
        wait (frames == 1);
        wait (n_left >= 4 && n_right >= 4);

        $display("");
        $display("=== tb_hdmi_i2s ===");
        expect_eq("left slot round trip",  got_l, centred(24'hA5_3C_7E));
        expect_eq("right slot round trip", got_r, centred(24'h12_34_56));

        // change the input and confirm the NEXT frame carries it
        sample_l = 24'h00_00_01;
        sample_r = 24'hFF_FF_FF;
        n_left = 0; n_right = 0;
        wait (n_left >= 2 && n_right >= 2);
        expect_eq("left follows input",  got_l, centred(24'h00_00_01));
        expect_eq("right follows input", got_r, centred(24'hFF_FF_FF));

        // ---- rate ----------------------------------------------------------
        begin
            realtime span_ns;
            real     hz;
            wait (frames >= 200);
            span_ns = t_last - t_first;
            hz      = (real'(frames - 1) * 1.0e9) / span_ns;
            $display("  frames=%0d span=%.1f us  ->  %.2f Hz (want %0d)",
                     frames, span_ns/1000.0, hz, SAMPLE_HZ);
            if (hz < SAMPLE_HZ * 0.999 || hz > SAMPLE_HZ * 1.001) begin
                $display("  FAIL frame rate off by more than 0.1%%");
                errors++;
            end else
                $display("  ok   frame rate within 0.1%%");
        end

        $display("");
        if (errors == 0) $display("tb_hdmi_i2s: PASS");
        else             $display("tb_hdmi_i2s: FAIL (%0d)", errors);
        $finish;
    end

    initial begin
        #20_000_000;                                   // 20 ms guard
        $display("tb_hdmi_i2s: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
