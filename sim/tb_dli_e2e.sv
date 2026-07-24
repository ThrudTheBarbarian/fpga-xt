// tb_dli_e2e.sv — end-to-end DLI path for ACID800 pfstarttiming.
//
// Wires antic_raster + dl_parser + nmi_gen exactly as antic_top does, loads
// pfstart's display list ($70,$70,$F0,...), sets nmien=$80, runs a few frames,
// and reports every scanline on which /NMI asserts.  The test's dli1 handler
// expects the first DLI "-> end line 31", so a correct machine asserts /NMI at
// scanline 31.  Pure sim — no build, no hardware probe.

`default_nettype none
`timescale 1ns / 1ps

module tb_dli_e2e;
    logic clk = 0; always #5 clk = ~clk;
    logic rst = 1;
    logic phi2_tick = 1'b1;              // every clk = one machine cycle

    // ---- antic_raster ----
    wire [8:0] scanline;
    wire [7:0] phi2_in_line;
    wire       line_start, vbi_start;
    wire [7:0] atari_row, vcount;

    antic_raster u_raster (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .scanline(scanline), .phi2_in_line(phi2_in_line),
        .line_start(line_start), .vbi_start(vbi_start),
        .atari_row(atari_row), .vcount(vcount));

    // cycle-8 strobes (antic_top derives DLI/VBI at machine cycle 8)
    wire cycle_7   = phi2_tick && (phi2_in_line == 8'd7);   // status tick
    wire cycle_8   = phi2_tick && (phi2_in_line == 8'd8);
    wire vbi_c7    = cycle_7 && (scanline == 9'd248);
    wire vbi_c8    = cycle_8 && (scanline == 9'd248);

    // ---- DL RAM ----
    logic [15:0] waddr; logic [7:0] wdata; logic we = 0;
    wire  [15:0] raddr; wire  [7:0] rdata;
    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_ram (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata));

    // ---- dl_parser ----
    wire [7:0] nmi_cur_row;
    wire       nmi_cur_row_dli;
    wire       parse_done;
    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(vbi_start),
        .dlistl(8'h00), .dlisth(8'h2C), .dlistl_we(1'b0), .dlisth_we(1'b0), .vscrol(4'h0),
        .mem_raddr(raddr), .mem_rdata(rdata), .mem_req(), .mem_ready(1'b1),
        .meta_row(8'h00), .meta_mode(), .meta_dli(), .meta_lms_addr(),
        .meta_sub_row(), .meta_hscrol_en(), .meta_vscrol_en(),
        .dli_row(nmi_cur_row), .dli_at(nmi_cur_row_dli),
        .parse_done(parse_done), .parse_count());

    // ---- nmi_gen ----
    logic [7:0] nmien = 8'h00;
    wire  [7:0] nmist_q;
    wire        nmi_n;
    nmi_gen u_nmi (
        .clk(clk), .rst(rst), .nmien(nmien), .nmires_strobe(1'b0),
        .status_tick(1'b1),
        .vbi_status(vbi_c7), .vbi_start(vbi_c8),
        .line_status(cycle_7), .line_start(cycle_8),
        .cur_row(nmi_cur_row), .cur_row_dli(nmi_cur_row_dli),
        .atari_row_in(atari_row), .nmist_q(nmist_q), .nmi_n(nmi_n));

    task automatic wr(input [15:0] a, input [7:0] d);
        @(negedge clk); waddr <= a; wdata <= d; we <= 1;
        @(posedge clk); @(negedge clk); we <= 0;
    endtask

    // watch /NMI falling edges and report the scanline
    logic nmi_q = 1'b1;
    always @(posedge clk) begin
        nmi_q <= nmi_n;
        if (nmi_q && !nmi_n)
            $display("  /NMI asserted at scanline %0d (atari_row %0d, nmist=$%02h)",
                     scanline, atari_row, nmist_q);
    end

    initial begin
        repeat (4) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);
        // pfstarttiming DL at $2C00
        wr(16'h2C00, 8'h70); wr(16'h2C01, 8'h70); wr(16'h2C02, 8'hF0);
        wr(16'h2C03, 8'h00); wr(16'h2C04, 8'h66); wr(16'h2C05, 8'h00);
        wr(16'h2C06, 8'h2D); wr(16'h2C07, 8'h0A); wr(16'h2C08, 8'hF0);
        wr(16'h2C09, 8'h00); wr(16'h2C0A, 8'h66); wr(16'h2C0B, 8'h00);
        wr(16'h2C0C, 8'h2D); wr(16'h2C0D, 8'h0A); wr(16'h2C0E, 8'h41);
        wr(16'h2C0F, 8'h00); wr(16'h2C10, 8'h2C);

        nmien <= 8'h80;                  // DLI enable, like the test
        $display("== running 3 frames, nmien=$80, watching /NMI ==");
        $display("== the pfstart dli1 handler expects the first DLI at scanline 31 ==");
        repeat (3 * 262 * 114) @(posedge clk);
        $display("== done ==");
        $finish;
    end
endmodule

`default_nettype wire
