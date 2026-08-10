// lb_stream_cdc.sv — the render line-buffer stream across a clock boundary.
//
// Unification phase 6 (docs/antic-unification-plan.md): when the Atari realm
// moves to clk_sally, the ONE crossing that remains on the video path is this
// stream — lb_wr/lb_color/lb_line_start out of the renderer into
// antic_wb_adapt (clk_sys).  It is a DATA stream: the consumer rebuilds rows
// from line_start markers and in-order colour bytes, so no cycle semantics
// cross here — only ordering, which a FIFO preserves by construction.
//
// Shape: a shallow dual-clock FIFO of 9-bit entries {line_start, color}.
// lb_wr pushes a colour byte; lb_line_start pushes a marker (the two never
// assert together — the renderer separates them by pipeline design, and an
// assertion in sim guards it).  Depth 32 absorbs the write-side burstiness
// (four hi-res pixels per machine cycle) against the read side's free-running
// drain; the drain is one entry per clk_sys, faster than the push rate by
// construction (clk_sys >= clk_sally and pushes are px_tick-paced), so the
// FIFO can never sustain growth — overflow is a design error, counted and
// exposed rather than silently dropped.
//
// Gray-coded pointers, 2-FF synced each way — the textbook async FIFO,
// deliberately boring.

`default_nettype none
`timescale 1ns/1ps

module lb_stream_cdc #(
    parameter int DEPTH_LOG2 = 5      // 32 entries
) (
    // ---- write side (the renderer's domain) ------------------------------
    input  wire        wclk,
    input  wire        wrst,
    input  wire        lb_wr,
    input  wire [7:0]  lb_color,
    input  wire        lb_line_start,
    output wire        overflow,      // sticky; a design error, not a runtime path

    // ---- read side (the writeback's domain) ------------------------------
    input  wire        rclk,
    input  wire        rrst,
    output logic       out_wr,
    output logic [7:0] out_color,
    output logic       out_line_start
);

    localparam int DEPTH = 1 << DEPTH_LOG2;

    logic [8:0] mem [0:DEPTH-1];

    // ---- write pointer (binary + gray) -----------------------------------
    logic [DEPTH_LOG2:0] wptr_bin, wptr_gray;
    (* ASYNC_REG = "TRUE" *) logic [DEPTH_LOG2:0] rptr_gray_w1, rptr_gray_w2;   // read ptr synced into wclk
    wire  [DEPTH_LOG2:0] wptr_bin_nx  = wptr_bin + 1'b1;
    wire  [DEPTH_LOG2:0] wptr_gray_nx = (wptr_bin_nx >> 1) ^ wptr_bin_nx;
    wire push = lb_wr | lb_line_start;
    wire full = (wptr_gray == {~rptr_gray_w2[DEPTH_LOG2:DEPTH_LOG2-1],
                                rptr_gray_w2[DEPTH_LOG2-2:0]});

    logic ovf_q;
    always_ff @(posedge wclk or posedge wrst) begin
        if (wrst) begin
            wptr_bin  <= '0;
            wptr_gray <= '0;
            ovf_q     <= 1'b0;
        end else if (push) begin
            if (full) begin
                ovf_q <= 1'b1;                      // never expected; see header
            end else begin
                mem[wptr_bin[DEPTH_LOG2-1:0]] <= {lb_line_start, lb_color};
                wptr_bin  <= wptr_bin_nx;
                wptr_gray <= wptr_gray_nx;
            end
        end
    end
    assign overflow = ovf_q;

    (* ASYNC_REG = "TRUE" *) logic [DEPTH_LOG2:0] wptr_gray_r1, wptr_gray_r2;

    // ---- read side --------------------------------------------------------
    logic [DEPTH_LOG2:0] rptr_bin, rptr_gray;
    wire  [DEPTH_LOG2:0] rptr_bin_nx  = rptr_bin + 1'b1;
    wire  [DEPTH_LOG2:0] rptr_gray_nx = (rptr_bin_nx >> 1) ^ rptr_bin_nx;
    wire empty = (rptr_gray == wptr_gray_r2);

    always_ff @(posedge rclk or posedge rrst) begin
        if (rrst) begin
            {wptr_gray_r2, wptr_gray_r1} <= '0;
            rptr_bin  <= '0;
            rptr_gray <= '0;
            out_wr         <= 1'b0;
            out_color      <= 8'h00;
            out_line_start <= 1'b0;
        end else begin
            {wptr_gray_r2, wptr_gray_r1} <= {wptr_gray_r1, wptr_gray};
            out_wr         <= 1'b0;
            out_line_start <= 1'b0;
            if (!empty) begin
                {out_line_start, out_color} <= mem[rptr_bin[DEPTH_LOG2-1:0]];
                out_wr    <= ~mem[rptr_bin[DEPTH_LOG2-1:0]][8];
                rptr_bin  <= rptr_bin_nx;
                rptr_gray <= rptr_gray_nx;
            end
        end
    end

    // write-pointer sync into rclk lives above with the read regs; the
    // read-pointer sync into wclk:
    always_ff @(posedge wclk or posedge wrst) begin
        if (wrst) {rptr_gray_w2, rptr_gray_w1} <= '0;
        else      {rptr_gray_w2, rptr_gray_w1} <= {rptr_gray_w1, rptr_gray};
    end

`ifndef SYNTHESIS
    always @(posedge wclk)
        if (lb_wr && lb_line_start)
            $display("lb_stream_cdc: lb_wr and lb_line_start together — contract violation");
`endif

endmodule

`default_nettype wire
