// tb_visual.sv — visual smoke tests with recognizable output.
//
// Unlike the verification testbenches (which use synthetic XOR
// charsets / source patterns that match a numeric oracle), this one
// loads hand-packed letter glyphs and renders human-readable text.
// No PASS/FAIL — the only output is sim/visual/text_*.ppm and a
// corresponding [visual] log line. Eyeball the PPM in any image
// viewer.
//
// Scenes:
//   1. visual/text_hello.ppm     "Hello world" in mode 2
//   2. visual/text_with_pm.ppm   same text + a P0 sprite slid across

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_visual;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;

    wire  [15:0] dl_raddr;
    wire  [7:0]  dl_rdata;
    wire  [15:0] cmp_raddr;
    wire  [7:0]  cmp_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_dl_mem (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(dl_raddr), .rdata(dl_rdata));
    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_cmp_mem (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(cmp_raddr), .rdata(cmp_rdata));

    logic        dl_start = 1'b0;
    logic [7:0]  dlistl   = 8'h00;
    logic [7:0]  dlisth   = 8'hD0;
    wire  [7:0]  meta_row_w;
    wire  [3:0]  dl_meta_mode;
    wire         dl_meta_hscrol_en;
    wire         dl_meta_vscrol_en;
    wire         dl_meta_dli;
    wire  [15:0] dl_meta_lms;
    wire  [3:0]  dl_meta_sub;
    wire         dl_done;
    wire  [31:0] dl_count;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(dl_start),
        .dlistl(dlistl), .dlisth(dlisth),
        .vscrol(4'h0),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata), .mem_req(), .mem_ready(1'b1),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_dli(dl_meta_dli),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_lms_addr(dl_meta_lms), .meta_sub_row(dl_meta_sub),
        .dli_row(8'h00), .dli_at(),
        .parse_done(dl_done), .parse_count(dl_count));

    logic        cmp_start = 1'b0;
    wire  [1:0]  cmp_cmd_tag;
    wire  [23:0] cmp_cmd_addr;
    wire  [23:0] cmp_cmd_data;
    wire         cmp_cmd_valid;
    wire         cmp_cmd_ready;
    wire         cmp_done;
    wire  [31:0] cmp_count;

    logic [7:0]  pmbase_reg = 8'h80;
    logic [7:0]  dmactl_reg = 8'h00;
    logic [7:0]  gractl_reg = 8'h00;
    logic [7:0]  hposp0_reg = 8'h00;

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_sub_row(dl_meta_sub),
        .chbase(8'hE0), .chactl(8'h00),
        .pmbase(pmbase_reg), .dmactl(dmactl_reg), .gractl(gractl_reg),
        .hposp0(hposp0_reg), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0), .hscrol(4'h0), .vscrol(4'h0),
        .prior(8'h00),
        .mpf_q(), .ppf_q(), .mpl_q(), .ppl_q(), .hitclr(1'b0),
        .mem_raddr(cmp_raddr), .mem_rdata(cmp_rdata), .mem_req(), .mem_ready(1'b1),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .compose_done(cmp_done), .compose_count(cmp_count));

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [31:0] tx_set_misalign_count;

    rp_tx u_tx (
        .clk(clk), .rst(rst),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .tx_set_misalign_count(tx_set_misalign_count));

    localparam int FB_BYTES = 32 * 1024;
    wire  [15:0] mock_rsp;
    wire         mock_rsp_valid;
    wire  [31:0] mock_fetch_count, mock_set_count, mock_draw_count;
    wire  [31:0] mock_bad_tag_count, mock_set_misalign_count;

    rp_bus_mock #(.FB_BYTES(FB_BYTES), .FETCH_LATENCY(4)) u_mock (
        .clk(clk), .rst(rst),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .rsp_payload(mock_rsp), .rsp_valid(mock_rsp_valid),
        .mock_fetch_count(mock_fetch_count), .mock_set_count(mock_set_count),
        .mock_draw_count(mock_draw_count),
        .mock_bad_tag_count(mock_bad_tag_count),
        .mock_set_misalign_count(mock_set_misalign_count));

    `include "dump_ppm.svh"

    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr; bram_wdata <= data; bram_we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    task automatic clear_fb();
        integer i;
        for (i = 0; i < FB_BYTES; i = i + 1) u_mock.fb[i] = 8'h00;
    endtask

    task automatic run_compose();
        @(posedge clk);
        cmp_start <= 1'b1;
        @(posedge clk);
        cmp_start <= 1'b0;
        wait (cmp_done);
        @(posedge clk);
        repeat (32) @(posedge clk);
    endtask

    task automatic do_parse_and_compose();
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
    endtask

    // Hand-packed 8x8 letter glyphs. Bit 7 = leftmost atari px in mode 2.
    // Stored at chbase=$E0 << 8 = $E000, code C → $E000 + C*8 + row.
    // We pick our own code numbers (no ATASCII / internal mapping).
    //
    //   Code 0  space        Code 1  H            Code 2  e
    //   Code 3  l            Code 4  o            Code 5  w
    //   Code 6  r            Code 7  d            Code 8  M9 ('!')
    task automatic load_charset();
        integer i;
        // Code 0: space — all blank
        for (i = 0; i < 8; i = i + 1) load_byte(16'hE000 + 16'(i), 8'h00);

        // Code 1: H
        load_byte(16'hE008, 8'h44);
        load_byte(16'hE009, 8'h44);
        load_byte(16'hE00A, 8'h44);
        load_byte(16'hE00B, 8'h7C);
        load_byte(16'hE00C, 8'h44);
        load_byte(16'hE00D, 8'h44);
        load_byte(16'hE00E, 8'h44);
        load_byte(16'hE00F, 8'h00);

        // Code 2: e
        load_byte(16'hE010, 8'h00);
        load_byte(16'hE011, 8'h00);
        load_byte(16'hE012, 8'h38);
        load_byte(16'hE013, 8'h44);
        load_byte(16'hE014, 8'h7C);
        load_byte(16'hE015, 8'h40);
        load_byte(16'hE016, 8'h3C);
        load_byte(16'hE017, 8'h00);

        // Code 3: l
        load_byte(16'hE018, 8'h30);
        load_byte(16'hE019, 8'h10);
        load_byte(16'hE01A, 8'h10);
        load_byte(16'hE01B, 8'h10);
        load_byte(16'hE01C, 8'h10);
        load_byte(16'hE01D, 8'h10);
        load_byte(16'hE01E, 8'h38);
        load_byte(16'hE01F, 8'h00);

        // Code 4: o
        load_byte(16'hE020, 8'h00);
        load_byte(16'hE021, 8'h00);
        load_byte(16'hE022, 8'h38);
        load_byte(16'hE023, 8'h44);
        load_byte(16'hE024, 8'h44);
        load_byte(16'hE025, 8'h44);
        load_byte(16'hE026, 8'h38);
        load_byte(16'hE027, 8'h00);

        // Code 5: w
        load_byte(16'hE028, 8'h00);
        load_byte(16'hE029, 8'h00);
        load_byte(16'hE02A, 8'h44);
        load_byte(16'hE02B, 8'h44);
        load_byte(16'hE02C, 8'h54);
        load_byte(16'hE02D, 8'h6C);
        load_byte(16'hE02E, 8'h44);
        load_byte(16'hE02F, 8'h00);

        // Code 6: r
        load_byte(16'hE030, 8'h00);
        load_byte(16'hE031, 8'h00);
        load_byte(16'hE032, 8'h78);
        load_byte(16'hE033, 8'h44);
        load_byte(16'hE034, 8'h40);
        load_byte(16'hE035, 8'h40);
        load_byte(16'hE036, 8'h40);
        load_byte(16'hE037, 8'h00);

        // Code 7: d
        load_byte(16'hE038, 8'h04);
        load_byte(16'hE039, 8'h04);
        load_byte(16'hE03A, 8'h3C);
        load_byte(16'hE03B, 8'h44);
        load_byte(16'hE03C, 8'h44);
        load_byte(16'hE03D, 8'h44);
        load_byte(16'hE03E, 8'h3C);
        load_byte(16'hE03F, 8'h00);
    endtask

    // Code mapping (pick our own — no ATASCII / internal):
    //   0 = space    1 = H    2 = e    3 = l    4 = o
    //   5 = w        6 = r    7 = d
    // "Hello world" → 1, 2, 3, 3, 4, 0, 5, 4, 6, 3, 7
    task automatic write_hello_world(input logic [15:0] base);
        integer i;
        logic [7:0] codes [0:10];
        codes[0]  = 8'd1;   // H
        codes[1]  = 8'd2;   // e
        codes[2]  = 8'd3;   // l
        codes[3]  = 8'd3;   // l
        codes[4]  = 8'd4;   // o
        codes[5]  = 8'd0;   // <space>
        codes[6]  = 8'd5;   // w
        codes[7]  = 8'd4;   // o
        codes[8]  = 8'd6;   // r
        codes[9]  = 8'd3;   // l
        codes[10] = 8'd7;   // d
        for (i = 0; i < 11; i = i + 1) load_byte(base + 16'(i), codes[i]);
        for (i = 11; i < 40; i = i + 1) load_byte(base + 16'(i), 8'h00);
    endtask

    initial begin
        $display("[visual] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        load_charset();

        // ===== Scene 1: plain "Hello world" in mode 2 ====================
        // DL: mode 2 + LMS=$3000, then JVB.
        load_byte(16'hD000, 8'h42);
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);

        write_hello_world(16'h3000);

        clear_fb();
        do_parse_and_compose();
        $display("[visual] hello composed; sets=%0d", mock_set_count);
        dump_ppm("visual/text_hello.ppm", 320, 8, 3);

        // ===== Scene 2: same text + P0 sprite over the second 'l' ========
        // P0 shape = filled 8-bit pattern, parked at HPOSP=88 → atari_x_left
        // = (88-48)*2 = 80, covering atari_x [80,95]. The text starts at
        // atari_x 0; 'H'=cols 0-7, 'e'=8-15, 'l'=16-23, 'l'=24-31, 'o'=32-
        // 39, ' '=40-47, 'w'=48-55, 'o'=56-63, 'r'=64-71, 'l'=72-79,
        // 'd'=80-87 — so the player lands over 'd' / start of trailing
        // space. (Repositioning the sprite is just a one-line change for
        // future testing.)
        dmactl_reg <= 8'h08;        // bit 3 = player DMA (1-line resolution off)
        gractl_reg <= 8'h02;        // bit 1 = player presence enable
        hposp0_reg <= 8'd88;
        // P0 shape table at PMBASE=$80, 1-line offset $400 → $8400 +
        // atari_row. Fill all 8 atari rows (one mode-2 line = 8 atari
        // rows) with $7E ("solid bar with rounded ends").
        for (int r = 0; r < 8; r = r + 1)
            load_byte(16'h8400 + 16'(r), 8'h7E);
        // Set 1-line resolution so $8400+row is the right address.
        dmactl_reg <= 8'h18;        // bit 3 (player DMA) + bit 4 (1-line)

        clear_fb();
        do_parse_and_compose();
        $display("[visual] hello+P0 composed; sets=%0d", mock_set_count);
        dump_ppm("visual/text_with_pm.ppm", 320, 8, 3);

        $display("*** VISUAL OK *** sets=%0d", mock_set_count);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL: tb_visual watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
