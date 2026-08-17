// tb_xl_publish.sv — the XL frame publish must be anchored to the WRITEBACK'S
// ROW WRAP, never to ANTIC's vbi.
//
// The bug this pins (fixed 89d143ad): frame_done fed to xl_buffer_ctrl was the
// ANTIC VBI, which fires when the DISPLAY LIST ENDS.  The writeback's row index
// comes from the raster timer and wraps independently, so any display list
// shorter than the nominal 192-line window makes the two diverge and the 192
// rows written between two publishes SPAN TWO FRAMES: rows first..191 from one
// and rows 0..first-1 from the next.  The published slot is then torn at
// `first`, by exactly one frame of motion.  On hardware that showed as every
// moving object splitting at one screen row, at a row that was constant within a
// run and different on every Atari cold start (BallBlazer's list is ~144 lines,
// a test probe's 120, BASIC's happens to align -- which is why the machine
// looked clean at idle).
//
// The check is the same one that named the bug on hardware: record the FIRST and
// LAST row written into a slot between consecutive publishes.  A coherent frame
// is a contiguous top-to-bottom pass, so first must be 0 and last must be 191.
//
// TWO ANCHORS ARE RUN SIDE BY SIDE from one row counter:
//   GOOD — frame_done = the row counter's own wrap        (the fix)
//   BAD  — frame_done = a vbi that fires at VBI_ROW       (the old wiring)
// so the test also proves it DISCRIMINATES: if the BAD anchor ever reported a
// clean 0..191 the check would be worthless, and a future edit that reverts the
// fix cannot pass by accident.

`timescale 1ns/1ps
`default_nettype none

module tb_xl_publish;

    localparam int ROWS      = 192;   // XL_SRC_H
    localparam int VBI_ROW   = 143;   // a ~144-line display list: ends early
    localparam int ROW_TICKS = 6;     // clk_sys cycles per Atari row (scaled down)

    // Two clocks at different rates, as on the board.
    reg clk_sys = 1'b0;  always #5 clk_sys = ~clk_sys;
    reg clk_pix = 1'b0;  always #7 clk_pix = ~clk_pix;
    reg rst_sys = 1'b1, rst_pix = 1'b1;

    // ---- the writeback's row counter -------------------------------------
    integer tick = 0;
    reg [7:0] row = 8'd0;
    reg       row_tick = 1'b0;        // 1-clk: this row is being written
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            tick <= 0; row <= 8'd0; row_tick <= 1'b0;
        end else begin
            row_tick <= 1'b0;
            if (tick == ROW_TICKS - 1) begin
                tick     <= 0;
                row_tick <= 1'b1;
                row      <= (row == ROWS - 1) ? 8'd0 : row + 8'd1;
            end else begin
                tick <= tick + 1;
            end
        end
    end

    // GOOD anchor: the counter's own wrap, exactly as fpga_xt_top does it.
    reg [7:0] row_q = 8'd0;
    always_ff @(posedge clk_sys) row_q <= row;
    wire wrap_pulse = (row < row_q);

    // BAD anchor: a vbi that fires when a SHORT display list ends.
    wire vbi_pulse = row_tick && (row == VBI_ROW[7:0]);

    // ---- scan-out vblank, free-running against the producer ---------------
    integer pixcnt = 0;
    reg disp_vbi = 1'b0;
    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin pixcnt <= 0; disp_vbi <= 1'b0; end
        else begin
            disp_vbi <= 1'b0;
            if (pixcnt == 199) begin pixcnt <= 0; disp_vbi <= 1'b1; end
            else                     pixcnt <= pixcnt + 1;
        end
    end

    wire [1:0] wr_good, di_good, wr_bad, di_bad;

    xl_buffer_ctrl u_good (
        .clk_sys(clk_sys), .rst_sys(rst_sys), .frame_done(wrap_pulse),
        .write_idx(wr_good), .display_idx(di_good),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .disp_vbi(disp_vbi)
    );
    xl_buffer_ctrl u_bad (
        .clk_sys(clk_sys), .rst_sys(rst_sys), .frame_done(vbi_pulse),
        .write_idx(wr_bad), .display_idx(di_bad),
        .clk_pix(clk_pix), .rst_pix(rst_pix), .disp_vbi(disp_vbi)
    );

    // ---- observe what lands in a slot between publishes -------------------
    // iverilog will not take `automatic` locals in a procedural block, so the
    // per-anchor state is declared once.
    reg       g_seen = 1'b0, b_seen = 1'b0;
    reg [7:0] g_first = 8'd0, g_last = 8'd0, b_first = 8'd0, b_last = 8'd0;
    reg       g_valid = 1'b0, b_valid = 1'b0;
    integer   g_frames = 0, b_frames = 0;
    integer   g_bad = 0, b_bad = 0;
    // The FIRST publish after reset is a partial pass by construction (the model
    // starts mid-frame), so it is not evidence either way -- skip it.
    reg       g_started = 1'b0, b_started = 1'b0;
    // Reported at the end: the last COMPLETE frame, not a mid-frame snapshot of
    // g_first/g_last, which would read 0/0 and look like a failure.
    reg [7:0] g_rep_f = 8'd0, g_rep_l = 8'd0, b_rep_f = 8'd0, b_rep_l = 8'd0;

    always_ff @(posedge clk_sys) begin
        if (!rst_sys) begin
            // GOOD
            // The wrap pulse and the row_tick that writes row 0 land on the SAME
            // cycle, so that tick belongs to the NEW frame -- fold it in here or
            // the first row of every frame reads 1 and the check misfires.
            if (wrap_pulse) begin
                if (g_seen && g_started) begin
                    g_valid  <= 1'b1;
                    g_frames <= g_frames + 1;
                    if (g_first != 8'd0 || g_last != ROWS - 1) g_bad <= g_bad + 1;
                    g_rep_f <= g_first; g_rep_l <= g_last;
                end
                g_started <= 1'b1;
                g_seen  <= row_tick;
                g_first <= row;
                g_last  <= row;
            end else if (row_tick) begin
                if (!g_seen) begin g_seen <= 1'b1; g_first <= row; end
                g_last <= row;
            end
            // BAD
            if (vbi_pulse) begin
                if (b_seen && b_started) begin
                    b_valid  <= 1'b1;
                    b_frames <= b_frames + 1;
                    if (b_first != 8'd0 || b_last != ROWS - 1) b_bad <= b_bad + 1;
                    b_rep_f <= b_first; b_rep_l <= b_last;
                end
                b_started <= 1'b1;
                b_seen  <= 1'b0;
                b_first <= 8'd0;
                b_last  <= 8'd0;
            end else if (row_tick) begin
                if (!b_seen) begin b_seen <= 1'b1; b_first <= row; end
                b_last <= row;
            end
        end
    end

    // ---- the buffer invariant, checked continuously ----------------------
    integer g_collide = 0;
    always_ff @(posedge clk_sys)
        if (!rst_sys && wr_good == di_good) g_collide <= g_collide + 1;

    integer fail = 0;

    initial begin
        repeat (4) @(posedge clk_sys);
        rst_sys = 1'b0;
        repeat (4) @(posedge clk_pix);
        rst_pix = 1'b0;

        // enough for many frames at both anchors
        repeat (ROWS * ROW_TICKS * 12) @(posedge clk_sys);

        $display("tb_xl_publish: %0d frames via the row-wrap anchor, %0d via the vbi anchor",
                 g_frames, b_frames);
        $display("   row-wrap anchor: last complete frame first=%0d last=%0d  (want 0 and %0d)",
                 g_rep_f, g_rep_l, ROWS - 1);
        $display("   vbi anchor     : last complete frame first=%0d last=%0d  (spans two frames)",
                 b_rep_f, b_rep_l);

        if (g_frames < 4) begin
            $display("FAIL xl_publish: only %0d frames published via the wrap -- the stimulus never ran", g_frames);
            fail = fail + 1;
        end
        if (g_bad != 0) begin
            $display("FAIL xl_publish: %0d of %0d frames published on the ROW WRAP were not a contiguous 0..%0d pass -- a published slot spans two frames and will TEAR", g_bad, g_frames, ROWS - 1);
            fail = fail + 1;
        end
        if (g_collide != 0) begin
            $display("FAIL xl_publish: writeback slot == displayed slot on %0d cycles",
                     g_collide);
            fail = fail + 1;
        end

        // The discriminator: the old anchor MUST fail this check, otherwise the
        // check proves nothing and could not catch a revert.
        if (b_bad == 0) begin
            $display("FAIL xl_publish: the VBI anchor also produced clean frames, so this test cannot tell the anchors apart and would not catch a revert");
            fail = fail + 1;
        end else begin
            $display("   (vbi anchor tore %0d of %0d frames, as it must -- the check discriminates)", b_bad, b_frames);
        end

        if (fail == 0) $display("tb_xl_publish: all checks PASS");
        else           $display("tb_xl_publish: %0d FAILURES", fail);
        $finish;
    end

endmodule

`default_nettype wire
