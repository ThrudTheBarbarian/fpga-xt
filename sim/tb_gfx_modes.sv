// tb_gfx_modes.sv — M8 graphics modes 8 / 9 / A / B / D.
//
// One DL line per mode. Source bytes at $3000+: byte b = b & $FF.
// Verify the resulting FB matches per-mode unpack semantics:
//
//   Mode 8 (40 px, 2bpp, 4 cell_idxs/byte, 8 atari px/cell_idx)  — 10 bytes/row
//   Mode 9 (80 px, 1bpp, 8 bits/byte,  4 atari px/bit)   — 10 bytes/row
//   Mode A (80 px, 2bpp, 4 cell_idxs/byte, 4 atari px/cell_idx)  — 20 bytes/row
//   Mode B (160 px, 1bpp, 8 bits/byte, 2 atari px/bit)   — 20 bytes/row
//   Mode D (160 px, 2bpp, 4 cell_idxs/byte, 2 atari px/cell_idx) — 40 bytes/row
//
// Modes C and E are scan-count variants of B and D (same unpack)
// and are not separately tested at M8.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_gfx_modes;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    // ---- cpu_shadow + dl_parser + compositor + bus stack ---------------
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

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_sub_row(dl_meta_sub),
        .chbase(8'h00), .chactl(8'h00),
        .pmbase(8'h00), .dmactl(8'h00), .gractl(8'h00),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0),
        .vdelay(8'h0),
        .hscrol(4'h0), .vscrol(4'h0),
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

    localparam int FB_BYTES = 8 * 1024;
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

    // ---- Per-mode pixel oracles ----------------------------------------
    function automatic logic [7:0] mode_cell_idx_value(logic [7:0] byte_val, logic [1:0] cell_idx);
        logic [3:0] shift;
        shift = 4'd6 - {cell_idx, 1'b0};
        case ((byte_val >> shift) & 8'h03)
            8'h00: return 8'h00;
            8'h01: return 8'h01;
            8'h02: return 8'h02;
            8'h03: return 8'h04;       // graphics modes always emit PF2 for v=3
            default: return 8'h00;
        endcase
    endfunction

    function automatic logic [7:0] mode_bit_value(logic [7:0] byte_val, integer bit_idx);
        return byte_val[7 - bit_idx] ? 8'h04 : 8'h00;
    endfunction

    // ---- Test runner ---------------------------------------------------
    int fail_count = 0;
    int test_count = 0;

    task automatic run_compose;
        @(posedge clk);
        cmp_start <= 1'b1;
        @(posedge clk);
        cmp_start <= 1'b0;
        wait (cmp_done);
        @(posedge clk);
        repeat (32) @(posedge clk);
    endtask

    task automatic do_parse_and_compose;
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
    endtask

    // ---- Main ----------------------------------------------------------
    initial begin
        $display("[gfx_modes] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Pattern: bytes at $3000..$3027 (40 bytes) = byte_idx & $FF.
        // Covers bytes for modes 8/9 (10), A/B (20), D (40).
        for (int b = 0; b < 40; b++) load_byte(16'h3000 + 16'(b), b[7:0]);

        // ==== Mode 8 ===================================================
        load_byte(16'hD000, 8'h48);  // mode 8 + LMS
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);  // JVB
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);
        do_parse_and_compose();
        $display("[gfx_modes] mode 8 done; sets=%0d", mock_set_count);
        begin : v8
            integer      fb_off;
            integer      b;
            integer      cell_idx;
            integer      sub;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  byte_val;
            for (b = 0; b < 10; b = b + 1) begin
                byte_val = b[7:0];
                for (cell_idx = 0; cell_idx < 4; cell_idx = cell_idx + 1) begin
                    exp_v = mode_cell_idx_value(byte_val, cell_idx[1:0]);
                    for (sub = 0; sub < 8; sub = sub + 1) begin
                        fb_off = b * 32 + cell_idx * 8 + sub;
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 8)
                                $display("FAIL mode8 b=%0d cell_idx=%0d sub=%0d got $%02h exp $%02h",
                                         b, cell_idx, sub, got, exp_v);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[gfx_modes] mode 8 verified");
        dump_ppm("visual/gfx_mode8.ppm", 320, 8, 3);

        // ==== Mode 9 ===================================================
        load_byte(16'hD000, 8'h49);
        do_parse_and_compose();
        $display("[gfx_modes] mode 9 done; sets=%0d", mock_set_count);
        begin : v9
            integer      fb_off;
            integer      b;
            integer      bit_idx;
            integer      sub;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  byte_val;
            for (b = 0; b < 10; b = b + 1) begin
                byte_val = b[7:0];
                for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                    exp_v = mode_bit_value(byte_val, bit_idx);
                    for (sub = 0; sub < 4; sub = sub + 1) begin
                        fb_off = b * 32 + bit_idx * 4 + sub;
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 8)
                                $display("FAIL mode9 b=%0d bit=%0d sub=%0d got $%02h exp $%02h",
                                         b, bit_idx, sub, got, exp_v);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[gfx_modes] mode 9 verified");
        dump_ppm("visual/gfx_mode9.ppm", 320, 8, 3);

        // ==== Mode A ===================================================
        load_byte(16'hD000, 8'h4A);
        do_parse_and_compose();
        $display("[gfx_modes] mode A done; sets=%0d", mock_set_count);
        begin : vA
            integer      fb_off;
            integer      b;
            integer      cell_idx;
            integer      sub;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  byte_val;
            for (b = 0; b < 20; b = b + 1) begin
                byte_val = b[7:0];
                for (cell_idx = 0; cell_idx < 4; cell_idx = cell_idx + 1) begin
                    exp_v = mode_cell_idx_value(byte_val, cell_idx[1:0]);
                    for (sub = 0; sub < 4; sub = sub + 1) begin
                        fb_off = b * 16 + cell_idx * 4 + sub;
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 8)
                                $display("FAIL modeA b=%0d cell_idx=%0d sub=%0d got $%02h exp $%02h",
                                         b, cell_idx, sub, got, exp_v);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[gfx_modes] mode A verified");
        dump_ppm("visual/gfx_modeA.ppm", 320, 8, 3);

        // ==== Mode B ===================================================
        load_byte(16'hD000, 8'h4B);
        do_parse_and_compose();
        $display("[gfx_modes] mode B done; sets=%0d", mock_set_count);
        begin : vB
            integer      fb_off;
            integer      b;
            integer      bit_idx;
            integer      sub;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  byte_val;
            for (b = 0; b < 20; b = b + 1) begin
                byte_val = b[7:0];
                for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                    exp_v = mode_bit_value(byte_val, bit_idx);
                    for (sub = 0; sub < 2; sub = sub + 1) begin
                        fb_off = b * 16 + bit_idx * 2 + sub;
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 8)
                                $display("FAIL modeB b=%0d bit=%0d sub=%0d got $%02h exp $%02h",
                                         b, bit_idx, sub, got, exp_v);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[gfx_modes] mode B verified");
        dump_ppm("visual/gfx_modeB.ppm", 320, 8, 3);

        // ==== Mode D ===================================================
        load_byte(16'hD000, 8'h4D);
        do_parse_and_compose();
        $display("[gfx_modes] mode D done; sets=%0d", mock_set_count);
        begin : vD
            integer      fb_off;
            integer      b;
            integer      cell_idx;
            integer      sub;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  byte_val;
            for (b = 0; b < 40; b = b + 1) begin
                byte_val = b[7:0];
                for (cell_idx = 0; cell_idx < 4; cell_idx = cell_idx + 1) begin
                    exp_v = mode_cell_idx_value(byte_val, cell_idx[1:0]);
                    for (sub = 0; sub < 2; sub = sub + 1) begin
                        fb_off = b * 8 + cell_idx * 2 + sub;
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 8)
                                $display("FAIL modeD b=%0d cell_idx=%0d sub=%0d got $%02h exp $%02h",
                                         b, cell_idx, sub, got, exp_v);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[gfx_modes] mode D verified");
        dump_ppm("visual/gfx_modeD.ppm", 320, 8, 3);

        if (mock_bad_tag_count != 32'h0) begin
            $display("FAIL: mock_bad_tag_count=%0d", mock_bad_tag_count);
            fail_count++;
        end
        if (mock_set_misalign_count != 32'h0) begin
            $display("FAIL: mock_set_misalign_count=%0d", mock_set_misalign_count);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** GFX_MODES OK *** %0d modes verified; mock_sets=%0d",
                     test_count, mock_set_count);
            $finish;
        end else begin
            $display("*** GFX_MODES FAIL *** %0d failures across %0d modes",
                     fail_count, test_count);
            $fatal(1);
        end
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_gfx_modes watchdog (sets=%0d)", mock_set_count);
        $fatal(1);
    end

endmodule

`default_nettype wire
