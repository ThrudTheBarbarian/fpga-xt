// tb_dr_title.sv — replay Despatch Rider's MASTERTRONIC title-screen DL (read off
// the board at $70AA during the "crash"/corruption) through dl_parser and dump the
// per-row metadata. The screen renders as garbled rainbow on HW; the CPU is fine, so
// this is an ANTIC render bug. The DL is blank-heavy:
//   $70AA: 13x $70 (blank-8)         ; 104 leading blank scanlines
//          $46 $D0 $71               ; mode 6 + LMS $71D0  ("MASTERTRONIC")
//          $70 $70                   ; 2x blank-8
//          $06                       ; mode 6
//          $41 $AA $70               ; JVB $70AA
// Hypothesis: dl_parser's leading-blank skip drops too many of the 13 blanks and
// misaligns every subsequent row vs vbeam's scanline count -> garbage.

`default_nettype none
`timescale 1ns / 1ps
module tb_dr_title;
    logic clk=1'b0; always #10 clk=~clk;
    logic rst=1'b1;
    logic bram_we=1'b0; logic [15:0] bram_waddr=16'h0; logic [7:0] bram_wdata=8'h0;
    wire [15:0] bram_raddr; wire [7:0] bram_rdata;
    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_shadow (.clk(clk),.we(bram_we),.waddr(bram_waddr),.wdata(bram_wdata),.raddr(bram_raddr),.rdata(bram_rdata));

    logic start_parse=1'b0; logic [7:0] dlistl=8'hAA, dlisth=8'h70; logic [7:0] meta_row=8'h00;
    wire [3:0] meta_mode; wire meta_dli; wire [15:0] meta_lms_addr; wire [3:0] meta_sub_row;
    wire parse_done; wire [31:0] parse_count;
    dl_parser u_dl (.clk(clk),.rst(rst),.start_parse(start_parse),.dlistl(dlistl),.dlisth(dlisth),.vscrol(4'h0),
        .mem_raddr(bram_raddr),.mem_rdata(bram_rdata),.mem_req(),.mem_ready(1'b1),
        .meta_row(meta_row),.meta_mode(meta_mode),.meta_dli(meta_dli),.meta_lms_addr(meta_lms_addr),.meta_sub_row(meta_sub_row),
        .meta_hscrol_en(),.meta_vscrol_en(),.dli_row(8'h00),.dli_at(),.parse_done(parse_done),.parse_count(parse_count));

    task automatic lb(input logic [15:0] a, input logic [7:0] d);
        @(negedge clk); bram_waddr<=a; bram_wdata<=d; bram_we<=1'b1; @(posedge clk); @(negedge clk); bram_we<=1'b0;
    endtask
    integer r; logic [15:0] a;
    initial begin
        $display("[dr_title] start"); repeat(4) @(posedge clk); rst=1'b0; repeat(2) @(posedge clk);
        a=16'h70AA;
        for (r=0;r<13;r++) lb(a++, 8'h70);
        lb(a++,8'h46); lb(a++,8'hD0); lb(a++,8'h71);
        lb(a++,8'h70); lb(a++,8'h70);
        lb(a++,8'h06);
        lb(a++,8'h41); lb(a++,8'hAA); lb(a++,8'h70);
        @(posedge clk); start_parse<=1'b1; @(posedge clk); start_parse<=1'b0;
        wait(parse_done); @(posedge clk);
        $display("parse_count=%0d (rows emitted)", parse_count);
        $display("row  mode dli lms   sub");
        for (r=0;r<160;r++) begin
            meta_row=r[7:0]; @(posedge clk); #1;
            $display("%3d   %1h    %0d  $%04h %0d", r, meta_mode, meta_dli, meta_lms_addr, meta_sub_row);
        end
        $finish;
    end
    initial begin #4_000_000; $display("watchdog"); $fatal(1); end
endmodule
`default_nettype wire
