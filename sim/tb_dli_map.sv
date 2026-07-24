// tb_dli_map.sv — where does dl_parser record a blank-line DLI?
//
// Loads ACID800 antic_pfstarttiming's display list ($70,$70,$F0,$00,$66...) and,
// after a parse, sweeps dli_row 0..47 reading dli_at to print exactly which
// physical rows have line_dli_p set.  The $F0 (blank-8 + DLI) is the 3rd DL
// entry, after 2x$70 = 16 leading scanlines, so its last scan line is row 23.
// If dli_at is NOT set at 23 (or is set somewhere else), that's the bug that
// stops nmi_gen firing the test's DLI.

`default_nettype none
`timescale 1ns / 1ps

module tb_dli_map;
    logic clk = 0; always #5 clk = ~clk;
    logic rst = 1;

    logic [15:0] bram_waddr; logic [7:0] bram_wdata; logic bram_we = 0;
    wire  [15:0] bram_raddr; wire  [7:0] bram_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_ram (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(bram_raddr), .rdata(bram_rdata));

    logic        start_parse = 0;
    logic [7:0]  dlistl = 8'h00, dlisth = 8'h2C;   // DL at $2C00
    logic [7:0]  dli_row = 0;
    wire         dli_at;
    wire         parse_done;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(start_parse),
        .cold_abort(1'b0), .frame_start(1'b0), .line_start(1'b0), .prep_tick(1'b0),
        .dlistl(dlistl), .dlisth(dlisth), .dlistl_we(1'b0), .dlisth_we(1'b0), .vscrol(4'h0),
        .mem_raddr(bram_raddr), .mem_rdata(bram_rdata),
        .mem_req(), .mem_ready(1'b1),
        .meta_row(8'h00), .meta_mode(), .meta_dli(), .meta_lms_addr(),
        .meta_sub_row(), .meta_hscrol_en(), .meta_vscrol_en(),
        .dli_row(dli_row), .dli_at(dli_at),
        .parse_done(parse_done), .parse_count());

    task automatic wr(input [15:0] a, input [7:0] d);
        @(negedge clk); bram_waddr <= a; bram_wdata <= d; bram_we <= 1;
        @(posedge clk); @(negedge clk); bram_we <= 0;
    endtask

    integer r;
    initial begin
        repeat (4) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);

        // pfstarttiming display list at $2C00 (from the .lst):
        wr(16'h2C00, 8'h70);   // blank-8            rows 0-7   (skipped overscan)
        wr(16'h2C01, 8'h70);   // blank-8            rows 8-15  (skipped overscan)
        wr(16'h2C02, 8'hF0);   // blank-8 + DLI      rows 16-23 -> DLI at row 23
        wr(16'h2C03, 8'h00);   // blank-1            row 24
        wr(16'h2C04, 8'h66);   // LMS mode 6 (+DLI? no, $66 bit7=0)
        wr(16'h2C05, 8'h00);   // LMS lo
        wr(16'h2C06, 8'h2D);   // LMS hi
        wr(16'h2C07, 8'h0A);   // blank-1 + DLI? $0A bit7=0 -> mode A (no)
        wr(16'h2C08, 8'hF0);   // blank-8 + DLI
        wr(16'h2C09, 8'h00);
        wr(16'h2C0A, 8'h66);
        wr(16'h2C0B, 8'h00);
        wr(16'h2C0C, 8'h2D);
        wr(16'h2C0D, 8'h0A);
        wr(16'h2C0E, 8'h41);   // JVB
        wr(16'h2C0F, 8'h00);
        wr(16'h2C10, 8'h2C);

        @(negedge clk); start_parse <= 1; @(posedge clk);
        @(negedge clk); start_parse <= 0;

        wait (parse_done); repeat (4) @(posedge clk);

        $display("== line_dli_p bits set after parsing pfstart DL ==");
        for (r = 0; r < 48; r = r + 1) begin
            @(negedge clk); dli_row <= r[7:0];
            @(posedge clk); #1;
            if (dli_at) $display("  DLI recorded at physical row %0d", r);
        end
        $display("== (expected: row 23 for first $F0, and the 2nd $F0's row) ==");
        $finish;
    end
endmodule

`default_nettype wire
