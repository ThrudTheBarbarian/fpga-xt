`timescale 1ns/1ps
`default_nettype none
//
// tb_antic2_pxpos — does antic2's hi-res pixel counter line up with its beam?
//
// a2_video hands gtia_stage a colour-clock position derived from antic2's
// px_pos: cc_pos = px_pos[8:1] - 1, and the pair capture keys off px_pos[0] to
// decide which half of the colour clock a pixel is.  BOTH assume px_pos counts
// 0,1,2,3 across machine cycle 0, 4,5,6,7 across cycle 1, and so on -- that is,
// px_pos == hcount*4 + k with k running 0..3 within the cycle.
//
// Nothing asserted that.  px_pos is reset by the beam's line_start and advanced
// by px_tick; hcount is advanced by tick.  They are two counters driven from two
// different strobes and the relationship between them is a property of the
// PHASE of those strobes, not of either module.  One pixel of skew moves every
// object comparison a colour clock and silently mis-colours the whole line, so
// it is worth an assertion rather than an argument.
//
// The generator here is tb_acid's, deliberately: 56 phases, px_tick at
// 13/27/41/55 and tick at 55, so the fourth px_tick of a cycle lands on the
// same fabric clock as the tick that advances hcount.  That coincidence is
// exactly what could go wrong.
//
module tb_antic2_pxpos;

    localparam int PHASES = 56;
    localparam int PXSTEP = PHASES / 4;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'(PHASES-1)) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'(PHASES-1));
        px_tick <= (phase == 6'(PXSTEP-1))   || (phase == 6'(2*PXSTEP-1)) ||
                   (phase == 6'(3*PXSTEP-1)) || (phase == 6'(4*PXSTEP-1));
    end

    wire [15:0] mem_addr;
    wire        mem_req;
    logic [7:0] mem_data = 8'h00;
    logic       mem_valid;
    always_ff @(posedge clk) mem_valid <= mem_req;

    wire [6:0] hcount;
    wire [8:0] line;
    wire [8:0] px_pos;
    wire       px_line_start;

    antic2 dut (
        .clk(clk), .rst(rst), .tick(tick), .px_tick(px_tick),
        .cs(1'b0), .we(1'b0), .addr(4'd0), .wdata(8'h00), .rdata(),
        .cpu_writing(1'b0),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .mem_valid(mem_valid), .mem_req(mem_req),
        .nmi(), .wsync_take(), .dma_steal(),
        .hcount(hcount), .line(line),
        .px_wr(), .px_pf_src(), .px_val(), .px_hires(),
        .px_in_window(), .px_pos(px_pos),
        .px_line_start(px_line_start), .px_active()
    );

    int fail = 0;
    int checked = 0;
    int k;                       // which pixel of the machine cycle this is

    // Count px_ticks within the machine cycle independently of the design, so a
    // disagreement is between the testbench's idea of the beam and antic2's,
    // not between two of antic2's own signals.
    always_ff @(posedge clk) begin
        if (rst) begin
            k <= 0;
        end else if (px_line_start) begin
            k <= 0;
        end else if (px_tick) begin
            if (!rst && line >= 9'd10 && line < 9'd14) begin
                checked++;
                if (px_pos !== 9'(hcount * 4 + k)) begin
                    if (fail < 12)
                        $display("FAIL line %0d hcount %0d k %0d: px_pos %0d, expected %0d",
                                 line, hcount, k, px_pos, hcount * 4 + k);
                    fail++;
                end
            end
            k <= (k == 3) ? 0 : k + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        // Fourteen scanlines is enough to cross a line boundary several times
        // with the beam inside the display.
        repeat (14 * 114 * PHASES + 200) @(posedge clk);

        if (checked == 0) begin
            $display("tb_antic2_pxpos: FAIL -- nothing was checked");
            fail++;
        end

        if (fail == 0)
            $display("tb_antic2_pxpos: all checks PASS (%0d pixels, px_pos == hcount*4 + k)",
                     checked);
        else
            $display("tb_antic2_pxpos: %0d FAIL of %0d checked", fail, checked);
        $finish;
    end

endmodule

`default_nettype wire
