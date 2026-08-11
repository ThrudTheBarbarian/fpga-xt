`timescale 1ns/1ps
module tb_lb_cdc;
    reg wclk=0, rclk=0, rst=1;
    always #5    wclk = ~wclk;      // 100 MHz
    always #3.75 rclk = ~rclk;      // 133 MHz
    reg lb_wr=0, lb_ls=0; reg [7:0] lb_color=0; reg [8:0] lb_line=0;
    wire ovf, o_wr, o_ls; wire [7:0] o_color; wire [8:0] o_line;
    lb_stream_cdc dut (.wclk(wclk), .wrst(rst), .lb_wr(lb_wr), .lb_color(lb_color),
                       .lb_line_start(lb_ls), .lb_line(lb_line), .overflow(ovf),
                       .rclk(rclk), .rrst(rst), .out_wr(o_wr), .out_color(o_color),
                       .out_line_start(o_ls), .out_line(o_line));
    integer sent=0, got=0, marks_sent=0, marks_got=0, errors=0;
    reg [7:0] expect_q [0:4095];
    reg [8:0] expect_ln [0:63];
    always @(posedge rclk) begin
        if (o_wr) begin
            if (o_color !== expect_q[got]) begin
                errors = errors + 1;
                $display("ORDER ERROR at %0d: got %02x want %02x", got, o_color, expect_q[got]);
            end
            got = got + 1;
        end
        if (o_ls) begin
            if (o_line !== expect_ln[marks_got]) begin
                errors = errors + 1;
                $display("LINE ERROR at mark %0d: got %0d want %0d", marks_got, o_line, expect_ln[marks_got]);
            end
            marks_got = marks_got + 1;
        end
    end
    integer i, j;
    initial begin
        repeat (10) @(posedge wclk); rst = 0;
        repeat (5) @(posedge wclk);
        // 8 "lines" of 16 bytes each, bursty like px_tick pacing; line numbers
        // ride the markers (31, 33, 35 ... exercising bit patterns incl. bit 8)
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge wclk); lb_ls <= 1; lb_line <= 9'd300 + i*2;
            expect_ln[marks_sent] = 9'd300 + i*2; marks_sent = marks_sent + 1;
            @(posedge wclk); lb_ls <= 0;
            for (j = 0; j < 16; j = j + 1) begin
                @(posedge wclk);
                lb_wr <= 1; lb_color <= (i*16+j) & 8'hFF;
                expect_q[sent] = (i*16+j) & 8'hFF; sent = sent + 1;
                @(posedge wclk); lb_wr <= 0;
                // occasional back-to-back burst
                if (j % 4 == 3) begin
                    lb_wr <= 1; lb_color <= 8'hA0 + j;
                    expect_q[sent] = 8'hA0 + j; sent = sent + 1;
                    @(posedge wclk); lb_wr <= 0;
                end
            end
        end
        repeat (100) @(posedge rclk);
        if (errors == 0 && got == sent && marks_got == marks_sent && !ovf)
            $display("*** LB_CDC OK *** %0d bytes, %0d marks, in order, no overflow", got, marks_got);
        else
            $display("*** LB_CDC FAIL *** errors=%0d got=%0d/%0d marks=%0d/%0d ovf=%b",
                     errors, got, sent, marks_got, marks_sent, ovf);
        $finish;
    end
endmodule
