// tb_hscrol_e2e.sv — end-to-end HSCROL fine-scroll: dl_parser -> compositor.
//
// Wires dl_parser's per-row meta (incl. meta_hscrol_en, latched from the DL
// instruction's bit-4) into the compositor exactly as antic_top does, sharing
// one RAM.  A real DL with a mode-4 + HSCROL line is parsed; then the compositor
// composes that row for several live HSCROL values and the marker pixel's
// screen position is checked to move by exactly 2*hscrol atari px.
//
// This closes the gap the isolated tb_hscrol left: it proves the ENABLE path
// (DL bit-4 -> line_hscrol_en[] -> meta_hscrol_en) actually turns on the
// compositor's fine-scroll window, and that a live hscrol value shifts smoothly.

`default_nettype none
`timescale 1ns / 1ps

module tb_hscrol_e2e;

    localparam logic [15:0] SCR = 16'h5000;   // mode-4 screen data
    localparam logic [7:0]  CHB = 8'h20;      // char ROM at $2000

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- shared RAM (two combinational read ports) ----------------------
    logic [7:0] mem [0:65535];

    // dl_parser
    logic        start_parse;
    wire [15:0]  dl_raddr;
    wire [7:0]   dl_rdata = mem[dl_raddr];
    wire [7:0]   meta_row_w;
    wire [3:0]   dl_mode;
    wire         dl_dli;
    wire [15:0]  dl_lms;
    wire [3:0]   dl_sub;
    wire         dl_hscrol_en;
    wire         dl_vscrol_en;
    wire         parse_done;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(start_parse),
        .cold_abort(1'b0), .frame_start(1'b0), .line_start(1'b0), .prep_tick(1'b0), .vs_dli_tick(1'b1), .vs_stop_tick(1'b1),
        .dlistl(8'h00), .dlisth(8'h30), .vscrol(4'h0),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata),
        .mem_req(), .mem_ready(1'b1),
        .meta_row(meta_row_w),
        .meta_mode(dl_mode), .meta_dli(dl_dli),
        .meta_lms_addr(dl_lms), .meta_sub_row(dl_sub),
        .meta_hscrol_en(dl_hscrol_en), .meta_vscrol_en(dl_vscrol_en),
        .dli_row(8'h00), .dli_at(),
        .parse_done(parse_done), .parse_count());

    // compositor
    logic        start_compose;
    logic [7:0]  row_in;
    logic [3:0]  hscrol_v;
    wire [15:0]  cmp_raddr;
    wire [7:0]   cmp_rdata = mem[cmp_raddr];
    wire [1:0]   cmd_tag;
    wire [23:0]  cmd_addr, cmd_data;
    wire         cmd_valid;
    wire         compose_done;

    compositor u_cmp (
        .clk(clk), .rst(rst),
        .start_compose(start_compose), .row_in(row_in),
        .meta_row(meta_row_w),
        .meta_mode(dl_mode), .meta_lms_addr(dl_lms), .meta_sub_row(dl_sub),
        .meta_hscrol_en(dl_hscrol_en), .meta_vscrol_en(dl_vscrol_en),
        .chbase(CHB), .chactl(8'h0), .pmbase(8'h0), .dmactl(8'h0), .gractl(8'h0),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep_early_flat(8'h00), .sizep_chg_x_flat({4{12'h7FF}}),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0), .hscrol(hscrol_v), .vscrol(4'h0), .prior(8'h0),
        .mem_raddr(cmp_raddr), .mem_rdata(cmp_rdata), .mem_req(), .mem_ready(1'b1),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1),
        .mpf_q(), .ppf_q(), .mpl_q(), .ppl_q(), .hitclr(1'b0),
        .compose_done(compose_done), .compose_count());

    // per-atari-x capture
    logic [7:0] px [0:511];
    int         pxn;
    logic       cap_rst;
    int         fail = 0;

    always_ff @(posedge clk) begin
        if (cap_rst) pxn <= 0;
        else if (cmd_valid) begin
            px[2*pxn]   <= cmd_data[7:0];
            px[2*pxn+1] <= cmd_data[15:8];
            pxn         <= pxn + 1;
        end
    end

    integer i;
    function automatic int first_px(input logic [7:0] want, input int n);
        int k; first_px = -1;
        for (k = 0; k < n; k++) if (first_px < 0 && px[k] === want) first_px = k;
    endfunction

    int pos, expct, en_probe;
    task automatic compose_and_check(input logic [3:0] hv);
        int g;
        @(negedge clk);
        row_in = 8'd0; hscrol_v = hv;
        cap_rst = 1'b1; @(negedge clk); cap_rst = 1'b0;
        start_compose = 1'b1; @(negedge clk); start_compose = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 100000);
        repeat (4) @(posedge clk);
        pos   = first_px(8'h04, 2*pxn);
        expct = 80 - 2*hv;
        $display("  e2e mode4 hscrol=%0d : meta_hscrol_en(row0)=%0d marker screen-x=%0d (expect %0d) %s",
                 hv, en_probe, pos, expct, (pos==expct) ? "" : "  <-- MISMATCH");
        if (pos != expct) fail++;
    endtask

    initial begin
        $display("=== HSCROL END-TO-END (dl_parser -> compositor) ===");
        start_parse = 0; start_compose = 0; cap_rst = 0; row_in = 0; hscrol_v = 0;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;

        // DL @ $3000: mode-4 + LMS + HSCROL line, then JVB.
        //   $54 = mode4(0x4) | LMS(0x40) | HSCROL(0x10)
        mem[16'h3000] = 8'h54; mem[16'h3001] = SCR[7:0]; mem[16'h3002] = SCR[15:8];
        mem[16'h3003] = 8'h41; mem[16'h3004] = 8'h00;    mem[16'h3005] = 8'h30;   // JVB $3000

        // mode-4 screen: char codes. Wider fetch = 48 bytes; fill 48 + margin.
        for (i = 0; i < 60; i = i + 1) mem[SCR+i] = 8'h01;     // code 1 background
        mem[SCR+10] = 8'h02;                                   // char 10 -> code 2 (marker)
        // char ROM: code 1 glyph row0 = 0x00 (cells 0 -> $00); code 2 = 0xC0
        // (cell0 = 11, code bit7=0 -> $04 marker at char-relative atari 0,1).
        mem[(CHB<<8) + (8'h01<<3) + 0] = 8'h00;
        mem[(CHB<<8) + (8'h02<<3) + 0] = 8'hC0;

        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Parse the DL so line_hscrol_en[] / line_mode[] / line_lms_addr[] fill.
        @(posedge clk); start_parse <= 1'b1; @(posedge clk); start_parse <= 1'b0;
        wait (parse_done); repeat (2) @(posedge clk);

        // Probe row-0 metadata. The compositor's meta_row output is 0 while
        // idle (post-reset), so dl_parser's combinational meta_* reflect row 0.
        @(negedge clk); #1; en_probe = dl_hscrol_en;
        $display("  parsed: row0 mode=%0h lms=$%04h hscrol_en=%0d", dl_mode, dl_lms, en_probe);
        if (dl_mode !== 4'h4) begin $display("FAIL: row0 not mode 4"); fail++; end
        if (en_probe !== 1'b1) begin $display("FAIL: row0 meta_hscrol_en not set by DL bit-4"); fail++; end

        compose_and_check(4'd0);
        compose_and_check(4'd1);
        compose_and_check(4'd2);
        compose_and_check(4'd3);
        compose_and_check(4'd4);

        if (fail == 0) $display("*** HSCROL_E2E OK *** enable path + fine shift smooth end-to-end");
        else           $display("*** HSCROL_E2E FAIL *** %0d mismatches", fail);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL: tb_hscrol_e2e watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
