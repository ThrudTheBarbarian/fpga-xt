// tb_dr_maze.sv — replicate Despatch Rider's top-down maze DL and DUMP the
// per-row metadata the parser emits, to check the per-char-line LMS advance.
//
// Real DR maze DL @ $3000 (read off the board via RAM-peek):
//   $70 $70              ; 2x blank-8  (16 leading blank scanlines)
//   $44 $90 $51          ; LMS + mode 4, screen = $5190
//   $04 x10              ; 10 more mode-4 char lines (auto-advance LMS)
//   $F0                  ; blank-8 + DLI
//   $41 $00 $30          ; JVB (end frame)
//
// Expected coherent maze: char line N uses LMS = $5190 + 40*N, for N=0..10:
//   $5190 $51B8 $51E0 $5208 $5230 $5258 $5280 $52A8 $52D0 $52F8 $5320
// A drift (advance != 40, or a page-cross wrap at $5208) would show here.

`default_nettype none
`timescale 1ns / 1ps

module tb_dr_maze;

    logic clk = 1'b0;
    always #10 clk = ~clk;
    logic rst = 1'b1;

    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;
    wire  [15:0] bram_raddr;
    wire  [7:0]  bram_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_cpu_shadow (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(bram_raddr), .rdata(bram_rdata));

    logic        start_parse = 1'b0;
    logic [7:0]  dlistl      = 8'h00;
    logic [7:0]  dlisth      = 8'h30;
    logic [7:0]  meta_row    = 8'h00;
    wire  [3:0]  meta_mode;
    wire         meta_dli;
    wire  [15:0] meta_lms_addr;
    wire  [3:0]  meta_sub_row;
    wire         parse_done;
    wire  [31:0] parse_count;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(start_parse),
        .cold_abort(1'b0), .frame_start(1'b0), .line_start(1'b0), .prep_tick(1'b0),
        .dlistl(dlistl), .dlisth(dlisth), .dlistl_we(1'b0), .dlisth_we(1'b0), .vscrol(4'h0),
        .mem_raddr(bram_raddr), .mem_rdata(bram_rdata),
        .mem_req(), .mem_ready(1'b1),
        .meta_row(meta_row), .meta_mode(meta_mode), .meta_dli(meta_dli),
        .meta_lms_addr(meta_lms_addr), .meta_sub_row(meta_sub_row),
        .meta_hscrol_en(), .meta_vscrol_en(),
        .dli_row(8'h00), .dli_at(),
        .parse_done(parse_done), .parse_count(parse_count));

    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr; bram_wdata <= data; bram_we <= 1'b1;
        @(posedge clk); @(negedge clk); bram_we <= 1'b0;
    endtask

    integer r;
    logic [15:0] prev_lms;
    logic [15:0] a;
    initial begin
        $display("[dr_maze] start");
        repeat (4) @(posedge clk); rst = 1'b0; repeat (2) @(posedge clk);

        // Load the REAL full DR DL at $3000 (read off the board).
        // Top maze (no scroll) then text then the HSCROL/VSCROL bottom view @ $5C00.
        a = 16'h3000;
        load_byte(a++, 8'h70); load_byte(a++, 8'h70);
        load_byte(a++, 8'h44); load_byte(a++, 8'h90); load_byte(a++, 8'h51);
        for (r = 0; r < 10; r++) load_byte(a++, 8'h04);
        load_byte(a++, 8'hF0);
        load_byte(a++, 8'h00);
        load_byte(a++, 8'h42); load_byte(a++, 8'h0E); load_byte(a++, 8'h36); // text mode2 $360E
        load_byte(a++, 8'h00);
        load_byte(a++, 8'h02);                                              // text mode2
        load_byte(a++, 8'h00);
        load_byte(a++, 8'h42); load_byte(a++, 8'h18); load_byte(a++, 8'h3C); // text mode2 $3C18
        load_byte(a++, 8'h80); load_byte(a++, 8'h70);
        load_byte(a++, 8'h74); load_byte(a++, 8'h00); load_byte(a++, 8'h5C); // bottom mode4+LMS+VS+HS $5C00
        for (r = 0; r < 7; r++) load_byte(a++, 8'h34);                       // mode4+VS+HS
        load_byte(a++, 8'h14);                                              // mode4+HS
        load_byte(a++, 8'h41); load_byte(a++, 8'h00); load_byte(a++, 8'h30); // JVB $3000

        @(posedge clk); start_parse <= 1'b1; @(posedge clk); start_parse <= 1'b0;
        wait (parse_done); @(posedge clk);

        // Dump rows 0..119
        $display("row  mode dli lms    sub   (lms delta vs prev row's lms)");
        prev_lms = 16'hffff;
        for (r = 0; r < 200; r++) begin
            meta_row = r[7:0];
            @(posedge clk); #1;
            $display("%3d   %1h   %0d  $%04h  %0d    %s%0d",
                     r, meta_mode, meta_dli, meta_lms_addr, meta_sub_row,
                     (prev_lms==16'hffff)?"  ":"d=",
                     (prev_lms==16'hffff)?0:(meta_lms_addr - prev_lms));
            prev_lms = meta_lms_addr;
        end
        $display("[dr_maze] done parse_count=%0d", parse_count);
        $finish;
    end

    initial begin
        #4_000_000;
        $display("FAIL: tb_dr_maze watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
