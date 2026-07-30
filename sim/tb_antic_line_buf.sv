`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_line_buf — the ping-pong scanline buffer.
//
// The behaviour that matters is that the expander reads the line BEHIND the one
// the beam is drawing. If the banks were shared, the expander would see a line
// being overwritten under it and the display would tear — T3/T4 pin that.
//
module tb_antic_line_buf;

    localparam int PIXELS = 456;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       line_start, wr_stb, swap;
    logic [7:0] wr_color;
    logic [9:0] rd_addr;
    wire  [7:0] rd_color;
    wire  [9:0] wr_index;

    antic_line_buf #(.PIXELS(PIXELS)) dut (
        .clk(clk), .rst(rst),
        .line_start(line_start), .wr_stb(wr_stb), .wr_color(wr_color),
        .wr_index(wr_index),
        .rd_addr(rd_addr), .rd_color(rd_color),
        .swap(swap)
    );

    int fail = 0;

    // Stimulus on the negedge — driving at the posedge races the always_ff.
    task automatic emit(input [7:0] c);
        begin
            @(negedge clk); wr_color = c; wr_stb = 1'b1;
            @(negedge clk); wr_stb = 1'b0;
        end
    endtask

    task automatic pulse_line_start;
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
        end
    endtask

    task automatic pulse_swap;
        begin
            @(negedge clk); swap = 1'b1;
            @(negedge clk); swap = 1'b0;
        end
    endtask

    // Read has one clock of latency, so present the address and wait an edge.
    task automatic read_at(input int a, output logic [7:0] v);
        begin
            @(negedge clk); rd_addr = 10'(a);
            @(negedge clk);
            v = rd_color;
        end
    endtask

    logic [7:0] got;

    initial begin
        line_start = 0; wr_stb = 0; swap = 0; wr_color = 0; rd_addr = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: the write pointer advances one pixel per strobe ---------
        pulse_line_start();
        if (wr_index !== 10'd0) begin
            $display("FAIL T1: line_start did not rewind (idx=%0d)", wr_index); fail++;
        end
        emit(8'h11); emit(8'h22); emit(8'h33);
        if (wr_index !== 10'd3) begin
            $display("FAIL T1b: after 3 pixels idx=%0d expected 3", wr_index); fail++;
        end

        // ---- T2: nothing is visible on the read side yet -----------------
        // The beam is writing bank 0; the reader is on bank 1, which is empty.
        read_at(0, got);
        if (got === 8'h11) begin
            $display("FAIL T2: reader sees the bank being WRITTEN — banks are shared");
            fail++;
        end

        // ---- T3: after a swap the reader sees the completed line ---------
        pulse_swap();
        read_at(0, got);
        if (got !== 8'h11) begin $display("FAIL T3: px0=$%02h expected $11", got); fail++; end
        read_at(1, got);
        if (got !== 8'h22) begin $display("FAIL T3: px1=$%02h expected $22", got); fail++; end
        read_at(2, got);
        if (got !== 8'h33) begin $display("FAIL T3: px2=$%02h expected $33", got); fail++; end

        // ---- T4: the new line does not disturb the one being read --------
        // This is the tearing case: write a full line into the other bank and
        // confirm the reader still sees the old contents throughout.
        pulse_line_start();
        emit(8'hAA); emit(8'hBB); emit(8'hCC);
        read_at(0, got);
        if (got !== 8'h11) begin
            $display("FAIL T4: reader saw $%02h — the new line is overwriting it", got);
            fail++;
        end

        // ---- T5: swap again and the roles reverse ------------------------
        pulse_swap();
        read_at(0, got);
        if (got !== 8'hAA) begin $display("FAIL T5: px0=$%02h expected $AA", got); fail++; end
        read_at(2, got);
        if (got !== 8'hCC) begin $display("FAIL T5: px2=$%02h expected $CC", got); fail++; end

        // ---- T6: a full line, end to end ---------------------------------
        pulse_line_start();
        for (int i = 0; i < PIXELS; i++) emit(8'(i & 8'hFF));
        if (wr_index !== 10'(PIXELS-1)) begin
            $display("FAIL T6: idx=%0d expected saturation at %0d", wr_index, PIXELS-1);
            fail++;
        end

        // ---- T7: the pointer saturates rather than wrapping ---------------
        // Checked HERE, before the swap — a swap legitimately rewinds for the
        // next line, so testing after it proves nothing.  Wrapping instead of
        // saturating would silently corrupt pixel 0 of the line in progress.
        emit(8'hFF);
        if (wr_index !== 10'(PIXELS-1)) begin
            $display("FAIL T7: pointer moved past the end (idx=%0d)", wr_index); fail++;
        end

        pulse_swap();
        for (int i = 0; i < PIXELS; i += 37) begin
            read_at(i, got);
            if (got !== 8'(i & 8'hFF)) begin
                $display("FAIL T6b: px%0d=$%02h expected $%02h", i, got, i & 8'hFF);
                fail++;
            end
        end

        if (fail == 0) $display("tb_antic_line_buf: all checks PASS");
        else           $display("tb_antic_line_buf: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
