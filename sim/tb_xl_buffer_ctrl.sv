// tb_xl_buffer_ctrl.sv — dual-clock test for the XL triple-buffer controller.
//
// Proves the property the whole anti-tear fix rests on:
//   write_idx != display_idx  AT ALL TIMES
// i.e. the writeback never fills the buffer the compositor is displaying — so the
// compositor always reads a complete, stable frame (no tear, no mid-write ghost).
//
// It drives frame_done (producer, clk_sys) and disp_vbi (consumer, clk_pix) from
// independent period counters, exercising both the real rate ordering (ANTIC
// ~59.92 Hz < display 60 Hz) and the reverse (producer faster) to show the
// invariant holds regardless.  It also checks that adoption and rotation actually
// happen (display_idx and write_idx each take all three slot values).

`default_nettype none
`timescale 1ns / 1ps

module tb_xl_buffer_ctrl;

    logic clk_sys = 1'b0; always #3    clk_sys = ~clk_sys;   // ~167 MHz
    logic clk_pix = 1'b0; always #3.38 clk_pix = ~clk_pix;   // ~148 MHz
    logic rst_sys = 1'b1, rst_pix = 1'b1;

    logic        frame_done = 1'b0;
    logic        disp_vbi   = 1'b0;
    wire  [1:0]  write_idx, display_idx;

    xl_buffer_ctrl u_dut (
        .clk_sys (clk_sys), .rst_sys (rst_sys),
        .frame_done (frame_done), .write_idx (write_idx), .display_idx (display_idx),
        .clk_pix (clk_pix), .rst_pix (rst_pix), .disp_vbi (disp_vbi)
    );

    int  fail_count = 0;
    int  checks     = 0;
    // Coverage: which slot values each output has taken.
    logic [2:0] wr_seen = 3'b000;
    logic [2:0] dp_seen = 3'b000;

    // ---- The invariant: write_idx must never equal display_idx ----------
    // Sampled in clk_sys (both are clk_sys registers).  Skip while in reset.
    always_ff @(posedge clk_sys) begin
        if (!rst_sys) begin
            checks++;
            if (write_idx === display_idx) begin
                $display("FAIL @%0t: write_idx == display_idx == %0d (writeback would scribble the displayed buffer!)",
                         $time, write_idx);
                fail_count++;
            end
            wr_seen[write_idx]   <= 1'b1;
            dp_seen[display_idx] <= 1'b1;
        end
    end

    // ---- Producer frame_done generator (clk_sys) ------------------------
    // period = PROD_CYC clk_sys cycles -> one ANTIC frame.
    int prod_cyc = 130;   // changed mid-run to flip the rate ordering
    int prod_cnt = 0;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin prod_cnt <= 0; frame_done <= 1'b0; end
        else begin
            if (prod_cnt >= prod_cyc - 1) begin prod_cnt <= 0; frame_done <= 1'b1; end
            else                          begin prod_cnt <= prod_cnt + 1; frame_done <= 1'b0; end
        end
    end

    // ---- Consumer disp_vbi generator (clk_pix) --------------------------
    int cons_cyc = 120;
    int cons_cnt = 0;
    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin cons_cnt <= 0; disp_vbi <= 1'b0; end
        else begin
            if (cons_cnt >= cons_cyc - 1) begin cons_cnt <= 0; disp_vbi <= 1'b1; end
            else                          begin cons_cnt <= cons_cnt + 1; disp_vbi <= 1'b0; end
        end
    end

    initial begin
        $display("=== XL_BUFFER_CTRL TEST ===");
        repeat (4) @(posedge clk_sys); rst_sys = 1'b0;
        repeat (4) @(posedge clk_pix); rst_pix = 1'b0;

        // Phase 1: producer SLOWER than consumer (the real ANTIC/HDMI ordering).
        prod_cyc = 130; cons_cyc = 120;
        #400_000;

        // Phase 2: producer FASTER than consumer — invariant must still hold
        // (free_slot always excludes the displayed buffer).
        prod_cyc = 95; cons_cyc = 120;
        #400_000;

        // Phase 3: near-equal rates (beat) — the worst case for naive schemes.
        prod_cyc = 121; cons_cyc = 120;
        #400_000;

        if (wr_seen !== 3'b111) begin
            $display("FAIL: write_idx did not rotate through all 3 slots (seen=%b)", wr_seen);
            fail_count++;
        end
        if (dp_seen !== 3'b111) begin
            $display("FAIL: display_idx did not adopt all 3 slots (seen=%b)", dp_seen);
            fail_count++;
        end

        if (fail_count == 0)
            $display("*** XL_BUFFER_CTRL OK *** %0d invariant checks, write/display always disjoint, rotation+adopt exercised", checks);
        else
            $display("*** XL_BUFFER_CTRL FAIL *** %0d failures", fail_count);
        if (fail_count) $fatal(1); else $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_xl_buffer_ctrl watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
