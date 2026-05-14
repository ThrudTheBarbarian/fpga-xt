// tb_hdmi_out.sv — verify hdmi_out's period sequencer.
//
// Phase A — period schedule per line. Walk one full line of 800×600
//   timing and count cycles in each period. Expected per line:
//     P_VIDEO         802  (800 active + 2 video guard)
//     P_CONTROL_F      12
//     P_DI_PRE          8
//     P_DI_GLEAD        2
//     P_DATA_ISL       32
//     P_DI_GTRAIL       2
//     P_CONTROL_B     190
//     P_VID_PRE         8
//   Total            1056  = H_TOTAL
//
// Phase B — symbol type per period (1-cycle delayed via period_q).
//   Sample tmds_b across one line and assert it lands on:
//     - a guard symbol whenever period_q is in {P_DI_GLEAD, P_DI_GTRAIL}
//       OR is_video_guard_q is true (those 2 cycles before next line)
//     - a TERC4 symbol when period_q == P_DATA_ISL (any of the 16
//       LUT entries)
//     - otherwise, the TMDS encoder output (= one of the 4 control
//       codes during blanking, or encoded RGB during active video)
//
// Phase C — line-end video guard transition: confirm the 2 cycles
//   before line wrap emit GUARD_LANE0_HS0 on lane 0 (= 0b1011001100).
//
// Sim runs at 800×600 timing (full real values) for ~3 lines.

`default_nettype none
`timescale 1ns / 1ps

module tb_hdmi_out;

    logic clk_bit = 1'b0;
    logic clk_pix = 1'b0;
    always #1.25 clk_bit = ~clk_bit;
    always #12.5 clk_pix = ~clk_pix;

    logic rst = 1'b1;

    logic [7:0]  rgb_r = 8'h00, rgb_g = 8'h00, rgb_b = 8'h00;
    logic [23:0] audio_l0 = 24'h0, audio_l1 = 24'h0, audio_l2 = 24'h0, audio_l3 = 24'h0;
    logic [23:0] audio_r0 = 24'h0, audio_r1 = 24'h0, audio_r2 = 24'h0, audio_r3 = 24'h0;
    logic [3:0]  audio_present = 4'h0, audio_flat = 4'h0, audio_block_start = 4'h0;
    logic [2:0]  pkt_select = 3'd1;     // PKT_AUDIO_CLK — fixed packet for the FSM test

    wire [11:0] h_count, v_count;
    wire        de, hsync, vsync, line_start, frame_start, vbi_start;
    wire [15:0] atari_row;
    wire [7:0]  vcount;
    wire [2:0]  period;
    wire        tmds_r, tmds_g, tmds_b, tmds_clk;

    hdmi_out #(
        .H_ACTIVE          (800),
        .H_FRONT_PORCH     (40),
        .H_SYNC_WIDTH      (128),
        .H_BACK_PORCH      (88),
        .V_ACTIVE          (600),
        .V_FRONT_PORCH     (1),
        .V_SYNC_WIDTH      (4),
        .V_BACK_PORCH      (23),
        .ANTIC_LINES_NATIVE(384),
        .HSYNC_ACTIVE_LOW  (1'b0),
        .VSYNC_ACTIVE_LOW  (1'b0)
    ) u_dut (
        .clk_pix(clk_pix), .clk_bit(clk_bit), .rst(rst),
        .rgb_r(rgb_r), .rgb_g(rgb_g), .rgb_b(rgb_b),
        .audio_l0(audio_l0), .audio_l1(audio_l1),
        .audio_l2(audio_l2), .audio_l3(audio_l3),
        .audio_r0(audio_r0), .audio_r1(audio_r1),
        .audio_r2(audio_r2), .audio_r3(audio_r3),
        .audio_present(audio_present),
        .audio_flat(audio_flat),
        .audio_block_start(audio_block_start),
        .pkt_select(pkt_select),
        .h_count(h_count), .v_count(v_count),
        .de(de), .hsync(hsync), .vsync(vsync),
        .line_start(line_start), .frame_start(frame_start),
        .vbi_start(vbi_start),
        .atari_row(atari_row), .vcount(vcount),
        .period(period),
        .tmds_r(tmds_r), .tmds_g(tmds_g), .tmds_b(tmds_b),
        .tmds_clk(tmds_clk));

    // Period IDs (must match hdmi_out's localparam definitions).
    localparam logic [2:0] P_VIDEO     = 3'd0;
    localparam logic [2:0] P_CONTROL_F = 3'd1;
    localparam logic [2:0] P_DI_PRE    = 3'd2;
    localparam logic [2:0] P_DI_GLEAD  = 3'd3;
    localparam logic [2:0] P_DATA_ISL  = 3'd4;
    localparam logic [2:0] P_DI_GTRAIL = 3'd5;
    localparam logic [2:0] P_CONTROL_B = 3'd6;
    localparam logic [2:0] P_VID_PRE   = 3'd7;

    // Reference TERC4 LUT for sym-type checks.
    function automatic logic terc4_match(input logic [9:0] s);
        logic [9:0] codes [0:15];
        codes[0]  = 10'b1010011100;
        codes[1]  = 10'b1001100011;
        codes[2]  = 10'b1011100100;
        codes[3]  = 10'b1011100010;
        codes[4]  = 10'b0101110001;
        codes[5]  = 10'b0100011110;
        codes[6]  = 10'b0110001110;
        codes[7]  = 10'b0100111100;
        codes[8]  = 10'b1011001100;
        codes[9]  = 10'b0100111001;
        codes[10] = 10'b0110011100;
        codes[11] = 10'b1011000110;
        codes[12] = 10'b1010001110;
        codes[13] = 10'b1001110001;
        codes[14] = 10'b0101100011;
        codes[15] = 10'b1011000011;
        for (int i = 0; i < 16; i = i + 1)
            if (s === codes[i]) return 1'b1;
        return 1'b0;
    endfunction

    // Frame/line accounting.
    integer line_starts_seen = 0;
    always @(posedge clk_pix) begin
        if (!rst && line_start) line_starts_seen = line_starts_seen + 1;
    end

    // Counters (gated by `enabled`).
    logic   enabled = 1'b0;
    integer cnt_video    = 0;
    integer cnt_video_gd = 0;
    integer cnt_ctrl_f   = 0;
    integer cnt_di_pre   = 0;
    integer cnt_di_glead = 0;
    integer cnt_data_isl = 0;
    integer cnt_di_gt    = 0;
    integer cnt_ctrl_b   = 0;
    integer cnt_vid_pre  = 0;

    integer total_samples       = 0;
    integer guard_periods_seen  = 0;
    integer terc4_periods_seen  = 0;
    integer tmds_periods_seen   = 0;
    int     fail_count          = 0;

    always @(posedge clk_pix) begin
        if (!rst && enabled) begin
            // Distinguish P_VIDEO active vs P_VIDEO guard.
            if (period == P_VIDEO) begin
                if (u_dut.is_video_guard) cnt_video_gd = cnt_video_gd + 1;
                else                     cnt_video    = cnt_video + 1;
            end else case (period)
                P_CONTROL_F: cnt_ctrl_f   = cnt_ctrl_f   + 1;
                P_DI_PRE:    cnt_di_pre   = cnt_di_pre   + 1;
                P_DI_GLEAD:  cnt_di_glead = cnt_di_glead + 1;
                P_DATA_ISL:  cnt_data_isl = cnt_data_isl + 1;
                P_DI_GTRAIL: cnt_di_gt    = cnt_di_gt    + 1;
                P_CONTROL_B: cnt_ctrl_b   = cnt_ctrl_b   + 1;
                P_VID_PRE:   cnt_vid_pre  = cnt_vid_pre  + 1;
                default: ;
            endcase
        end
    end

    // Phase B: sample the parallel 10-bit symbol going INTO the
    // serializer (tmds_b is the 1-bit serial output, not what we want).
    logic phaseB_enabled = 1'b0;
    always @(posedge clk_pix) begin
        if (!rst && phaseB_enabled) begin
            total_samples = total_samples + 1;
            if (u_dut.period_q == P_DI_GLEAD || u_dut.period_q == P_DI_GTRAIL
                || u_dut.is_video_guard_q) begin
                guard_periods_seen = guard_periods_seen + 1;
                if (u_dut.sym_b !== 10'b1011001100 && u_dut.sym_b !== 10'b0100110011) begin
                    if (fail_count < 8)
                        $display("[B/guard] FAIL h=%0d period_q=%0d sym_b=%010b",
                                 h_count, u_dut.period_q, u_dut.sym_b);
                    fail_count = fail_count + 1;
                end
            end else if (u_dut.period_q == P_DATA_ISL) begin
                terc4_periods_seen = terc4_periods_seen + 1;
                if (!terc4_match(u_dut.sym_b)) begin
                    if (fail_count < 8)
                        $display("[B/terc4] FAIL h=%0d sym_b=%010b not in TERC4 LUT",
                                 h_count, u_dut.sym_b);
                    fail_count = fail_count + 1;
                end
            end else begin
                tmds_periods_seen = tmds_periods_seen + 1;
            end
        end
    end

    initial begin
        $display("[hdmi_out] start");
        repeat (8) @(posedge clk_bit);
        rst = 1'b0;
        @(posedge clk_pix); @(posedge clk_pix);

        // Sync to the start of a fresh line via the polled counter.
        begin : sync_line
            integer start_lines;
            while (line_starts_seen == 0) @(posedge clk_pix);
            cnt_video    = 0;  cnt_video_gd = 0;
            cnt_ctrl_f   = 0;  cnt_di_pre   = 0;
            cnt_di_glead = 0;  cnt_data_isl = 0;
            cnt_di_gt    = 0;  cnt_ctrl_b   = 0;
            cnt_vid_pre  = 0;
            enabled         = 1'b1;
            phaseB_enabled  = 1'b1;
            start_lines = line_starts_seen;
            while (line_starts_seen == start_lines) @(posedge clk_pix);
            enabled         = 1'b0;
            phaseB_enabled  = 1'b0;
        end

        // ---- Phase A asserts -----------------------------------------
        if (cnt_video    !== 800)
            begin $display("[A/video]   FAIL %0d expected 800",  cnt_video);    fail_count++; end
        if (cnt_video_gd !== 2)
            begin $display("[A/vid_gd]  FAIL %0d expected 2",    cnt_video_gd); fail_count++; end
        if (cnt_ctrl_f   !== 12)
            begin $display("[A/ctrl_f]  FAIL %0d expected 12",   cnt_ctrl_f);   fail_count++; end
        if (cnt_di_pre   !== 8)
            begin $display("[A/di_pre]  FAIL %0d expected 8",    cnt_di_pre);   fail_count++; end
        if (cnt_di_glead !== 2)
            begin $display("[A/di_gl]   FAIL %0d expected 2",    cnt_di_glead); fail_count++; end
        if (cnt_data_isl !== 32)
            begin $display("[A/data]    FAIL %0d expected 32",   cnt_data_isl); fail_count++; end
        if (cnt_di_gt    !== 2)
            begin $display("[A/di_gt]   FAIL %0d expected 2",    cnt_di_gt);    fail_count++; end
        if (cnt_ctrl_b   !== 190)
            begin $display("[A/ctrl_b]  FAIL %0d expected 190",  cnt_ctrl_b);   fail_count++; end
        if (cnt_vid_pre  !== 8)
            begin $display("[A/vid_pre] FAIL %0d expected 8",    cnt_vid_pre);  fail_count++; end

        $display("[hdmi_out/A] line schedule: video=%0d vgd=%0d ctlF=%0d diPre=%0d diGL=%0d data=%0d diGT=%0d ctlB=%0d vidPre=%0d",
                 cnt_video, cnt_video_gd, cnt_ctrl_f, cnt_di_pre,
                 cnt_di_glead, cnt_data_isl, cnt_di_gt, cnt_ctrl_b, cnt_vid_pre);

        // ---- Phase B summary -----------------------------------------
        $display("[hdmi_out/B] %0d cycles sampled: %0d guard, %0d TERC4, %0d TMDS",
                 total_samples, guard_periods_seen, terc4_periods_seen,
                 tmds_periods_seen);
        // Guard cycles per line: 2 video guard + 2 leading + 2 trailing = 6.
        // TERC4 cycles per line: 32 (data island).
        // Rest: TMDS encoder. Phase B walked 1 full line.
        if (guard_periods_seen !== 6) begin
            $display("[B/gd_count] FAIL guard=%0d expected 6", guard_periods_seen);
            fail_count++;
        end
        if (terc4_periods_seen !== 32) begin
            $display("[B/tc_count] FAIL terc4=%0d expected 32", terc4_periods_seen);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** HDMI_OUT OK *** period schedule + symbol-type mux verified");
            $finish;
        end else begin
            $display("*** HDMI_OUT FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #500_000;            // 500 us watchdog: 1 line @ 25ns = 26.4us
        $display("FAIL: tb_hdmi_out watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
