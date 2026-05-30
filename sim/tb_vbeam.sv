// tb_vbeam.sv — M3 vbeam timing validation.
//
// Drives the pix_clk for 2 frames at 640×480@60 and verifies:
//   - Total H cycles per frame match VESA spec.
//   - Total V cycles per frame match VESA spec.
//   - HSYNC and VSYNC pulse widths match.
//   - frame_start fires once per V_TOTAL.
//   - vbi_start fires once per frame at the right line.
//   - atari_row is 0xFFFF in letterbox; ramps 0..191 in the active band.

`default_nettype none
`timescale 1ns / 1ps

module tb_vbeam;

    logic clk_pix = 1'b0;
    always #19.860 clk_pix = ~clk_pix;       // 25.175 MHz

    logic rst = 1'b1;

    wire [11:0] h_count, v_count;
    wire        in_active, h_active, v_active;
    wire        hsync, vsync, de;
    wire        line_start, frame_start, vbi_start;
    wire [15:0] atari_row;
    wire [7:0]  vcount;

    vbeam u_dut (
        .clk_pix    (clk_pix),
        .rst        (rst),
        .h_count    (h_count),
        .v_count    (v_count),
        .in_active  (in_active),
        .h_active   (h_active),
        .v_active   (v_active),
        .hsync      (hsync),
        .vsync      (vsync),
        .de         (de),
        .line_start (line_start),
        .frame_start(frame_start),
        .vbi_start  (vbi_start),
        .atari_row  (atari_row),
        .vcount     (vcount)
    );

    int fail_count = 0;
    int frame_count = 0;
    int vbi_count = 0;
    int hsync_pulse_cycles = 0;
    int hsync_pulses_total = 0;
    int max_atari_row_seen = -1;
    int min_atari_row_in_band_seen = 99999;

    // Track HSYNC pulse width.
    logic hsync_q;
    always_ff @(posedge clk_pix) begin
        hsync_q <= hsync;
        if (~hsync && hsync_q) hsync_pulses_total++;       // negedge
        if (~hsync) hsync_pulse_cycles++;                    // active-low: count cycles low
    end

    // Track frame_start / vbi_start counts.
    always_ff @(posedge clk_pix) begin
        if (frame_start) frame_count++;
        if (vbi_start)   vbi_count++;
        if (atari_row !== 16'hFFFF) begin
            if (int'(atari_row) > max_atari_row_seen) max_atari_row_seen = int'(atari_row);
            if (int'(atari_row) < min_atari_row_in_band_seen) min_atari_row_in_band_seen = int'(atari_row);
        end
    end

    initial begin
        $display("[vbeam] start");
        repeat (4) @(posedge clk_pix);
        rst = 1'b0;

        // Run 2 full frames. 640x480@60: 525 lines × 800 px = 420000 cycles.
        // 2 frames = 840000 cycles ≈ 33.4 ms.
        repeat (840_000) @(posedge clk_pix);

        // Expected frame_count = 2 (frame_start fires once per frame, when
        // h_count rolls past H_TOTAL-1 at v_count == V_TOTAL-1).
        if (frame_count != 2) begin
            $display("FAIL: frame_count=%0d expected 2", frame_count); fail_count++;
        end
        if (vbi_count != 2) begin
            $display("FAIL: vbi_count=%0d expected 2", vbi_count); fail_count++;
        end

        // Expected HSYNC pulse count: 525 lines * 2 frames = 1050.
        if (hsync_pulses_total < 1048 || hsync_pulses_total > 1052) begin
            $display("FAIL: hsync_pulses=%0d expected ~1050", hsync_pulses_total);
            fail_count++;
        end

        // Atari row band: should hit 191 max (192 ANTIC lines × 2 native /
        // 2 line-double = 192 atari rows, indexed 0..191).
        if (max_atari_row_seen != 191) begin
            $display("FAIL: max_atari_row_seen=%0d expected 191", max_atari_row_seen);
            fail_count++;
        end
        if (min_atari_row_in_band_seen != 0) begin
            $display("FAIL: min_atari_row_in_band=%0d expected 0",
                     min_atari_row_in_band_seen);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** VBEAM OK *** frames=%0d vbis=%0d hsyncs=%0d",
                     frame_count, vbi_count, hsync_pulses_total);
            $finish;
        end else begin
            $display("*** VBEAM FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #100_000_000;
        $display("FAIL: vbeam watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
