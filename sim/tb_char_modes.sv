// tb_char_modes.sv — M7 char-mode compositor.
//
// Verifies the compositor's mode 2 / 4 / 5 / 6 / 7 char-mode unpack
// by setting up a charset at $E000 (chbase = $E0), char codes at LMS,
// running compose, and checking the resulting FB.
//
// Test pattern (designed to be predictable):
//   - charset: glyph[code][row] = code XOR row, low 8 bits.
//   - char codes at LMS: code C at offset C (so code 0 lives at $3000+0,
//     code 1 at $3000+1, etc.).
//
// One DL line per mode under test, each spanning 1 atari row (we
// trigger one parse + compose per mode by reloading the DL).
//
// At M7 we cover mode 2 + 4 + 5 + 6 + 7. Mode 3 (descender) is deferred.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_char_modes;

    logic clk = 1'b0;
    always #5 clk = ~clk;     // 100 MHz

    logic rst = 1'b1;

    // ---- cpu_shadow (dual byte_ram with shared writes) ------------------
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;

    wire  [15:0] dl_raddr;
    wire  [7:0]  dl_rdata;
    wire  [15:0] cmp_raddr;
    wire  [7:0]  cmp_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_cpu_shadow_dl (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(dl_raddr), .rdata(dl_rdata)
    );

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_cpu_shadow_compose (
        .clk(clk), .we(bram_we), .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(cmp_raddr), .rdata(cmp_rdata)
    );

    // ---- dl_parser ------------------------------------------------------
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
        .parse_done(dl_done), .parse_count(dl_count)
    );

    // ---- compositor → rp_tx → mock --------------------------------------
    logic        cmp_start = 1'b0;
    wire  [1:0]  cmp_cmd_tag;
    wire  [23:0] cmp_cmd_addr;
    wire  [23:0] cmp_cmd_data;
    wire         cmp_cmd_valid;
    wire         cmp_cmd_ready;
    wire         cmp_done;
    wire  [31:0] cmp_count;

    logic [7:0]  chbase_reg = 8'hE0;
    logic [7:0]  chactl_reg = 8'h00;

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_sub_row(dl_meta_sub),
        .chbase(chbase_reg), .chactl(chactl_reg),
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
        .compose_done(cmp_done), .compose_count(cmp_count)
    );

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [31:0] tx_set_misalign_count;

    rp_tx u_tx (
        .clk(clk), .rst(rst),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .tx_set_misalign_count(tx_set_misalign_count)
    );

    localparam int FB_BYTES = 16 * 1024;    // 16 atari rows worth (mode 3 needs 10, modes 2/4/6 need 8)
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
        .mock_set_misalign_count(mock_set_misalign_count)
    );

    // ---- Backdoor write -------------------------------------------------
    `include "dump_ppm.svh"

    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr; bram_wdata <= data; bram_we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    // ---- Per-mode pixel oracles -----------------------------------------
    // Mode 2: bit set → $02.
    function automatic logic [7:0] m2_px(logic [7:0] glyph, int bit_idx);
        return glyph[7 - bit_idx] ? 8'h02 : 8'h00;
    endfunction

    // Mode 4: 2-bit cell_idx value v → 0/1/2/(code[7]?$08:$04). atari px in
    // pair (cell_idx_idx 0..3) come from glyph bits (7-2c, 6-2c).
    function automatic logic [7:0] m4_px(logic [7:0] glyph, int cell_idx_idx, logic code_b7);
        logic [1:0] v;
        v = {glyph[7 - 2*cell_idx_idx], glyph[6 - 2*cell_idx_idx]};
        case (v)
            2'd0: return 8'h00;
            2'd1: return 8'h01;
            2'd2: return 8'h02;
            2'd3: return code_b7 ? 8'h08 : 8'h04;
            default: return 8'h00;
        endcase
    endfunction

    // Mode 6: bit set → ci_to_pf[code[7:6]]; bit clear → 0. atari px doubled.
    function automatic logic [7:0] m6_px(logic [7:0] glyph, int bit_idx, logic [1:0] code_b67);
        logic [7:0] pf;
        case (code_b67)
            2'd0: pf = 8'h01;
            2'd1: pf = 8'h02;
            2'd2: pf = 8'h04;
            2'd3: pf = 8'h08;
            default: pf = 8'h00;
        endcase
        return glyph[7 - bit_idx] ? pf : 8'h00;
    endfunction

    // ---- Run-and-verify helpers ----------------------------------------
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

    // ---- Main -----------------------------------------------------------
    initial begin
        $display("[char_modes] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ==== Charset (shared across all char-mode tests) ===============
        // glyph[code][row] = (code ^ row) & $FF, stored at chbase<<8 +
        // code*8 + row. With chbase = $E0 → $E000+.
        for (int c = 0; c < 256; c++) begin
            for (int r = 0; r < 8; r++) begin
                load_byte(16'hE000 + 16'(c * 8 + r), c[7:0] ^ r[7:0]);
            end
        end

        // ==== Mode 2: 40-col 1bpp text =================================
        // DL: $42 $00 $30 (mode 2 + LMS=$3000), then JVB.
        load_byte(16'hD000, 8'h42);
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);
        // Char codes 0..39 at $3000..$3027.
        for (int c = 0; c < 40; c++) load_byte(16'h3000 + 16'(c), c[7:0]);

        do_parse_and_compose();
        $display("[char_modes] mode 2 compose done; sets=%0d", mock_set_count);

        // Verify atari row 0 (sub_row 0). Each char col c emits 8 atari px.
        // glyph for code c at sub_row 0 = (c ^ 0) = c. m2_px(c, bit) =
        // c[7-bit] ? $02 : $00.
        begin : v2
            int          fb_off;
            logic [7:0]  exp_v, got;
            for (int c = 0; c < 40; c++) begin
                for (int b = 0; b < 8; b++) begin
                    fb_off = 0 * 1024 + c * 8 + b;
                    got    = u_mock.fb[fb_off];
                    exp_v  = m2_px(c[7:0], b);
                    if (got !== exp_v) begin
                        if (fail_count < 8) begin
                            $display("FAIL mode2 r0 c=%0d b=%0d got $%02h exp $%02h",
                                     c, b, got, exp_v);
                        end
                        fail_count++;
                    end
                end
            end
            // Verify atari row 1 (sub_row 1). glyph[c][1] = c ^ 1.
            for (int c = 0; c < 40; c++) begin
                for (int b = 0; b < 8; b++) begin
                    fb_off = 1 * 1024 + c * 8 + b;
                    got    = u_mock.fb[fb_off];
                    exp_v  = m2_px(c[7:0] ^ 8'd1, b);
                    if (got !== exp_v) begin
                        if (fail_count < 8) begin
                            $display("FAIL mode2 r1 c=%0d b=%0d got $%02h exp $%02h",
                                     c, b, got, exp_v);
                        end
                        fail_count++;
                    end
                end
            end
        end
        test_count++;
        $display("[char_modes] mode 2 verified");
        dump_ppm("visual/char_mode2.ppm", 320, 8, 3);

        // ==== Mode 4: 40-col 2bpp multi-color =========================
        // Same DL pattern but mode 4. Atari px at cell_idx c (cell_idx_idx 0..3
        // within a char): both atari px in the cell_idx take m4_px.
        // Reset: re-init mock fb, reload DL.
        // Easier: just rewrite the DL to mode 4 and re-run; the FB will
        // be over-written for row 0..7.
        load_byte(16'hD000, 8'h44);    // mode 4 + LMS
        do_parse_and_compose();
        $display("[char_modes] mode 4 compose done; sets=%0d", mock_set_count);

        begin : v4
            integer      fb_off;
            integer      cell_idx;
            integer      c;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  glyph_byte;
            for (c = 0; c < 40; c = c + 1) begin
                glyph_byte = c[7:0] ^ 8'd0;     // sub_row 0 → glyph[c][0] = c
                for (cell_idx = 0; cell_idx < 4; cell_idx = cell_idx + 1) begin
                    exp_v = m4_px(glyph_byte, cell_idx, c[7]);
                    fb_off = c * 8 + cell_idx * 2;
                    got    = u_mock.fb[fb_off];
                    if (got !== exp_v) begin
                        if (fail_count < 16) begin
                            $display("FAIL mode4 r0 c=%0d cell_idx=%0d/lo got $%02h exp $%02h glyph=$%02h",
                                     c, cell_idx, got, exp_v, glyph_byte);
                        end
                        fail_count++;
                    end
                    fb_off = c * 8 + cell_idx * 2 + 1;
                    got    = u_mock.fb[fb_off];
                    if (got !== exp_v) begin
                        if (fail_count < 16) begin
                            $display("FAIL mode4 r0 c=%0d cell_idx=%0d/hi got $%02h exp $%02h",
                                     c, cell_idx, got, exp_v);
                        end
                        fail_count++;
                    end
                end
            end
        end
        test_count++;
        $display("[char_modes] mode 4 verified");
        dump_ppm("visual/char_mode4.ppm", 320, 8, 3);

        // ==== Mode 6: 20-col 4-color text ==============================
        // 16 atari px per char, 20 chars per row. atari px doubled per
        // glyph bit. Char code bits 6-7 select PF.
        load_byte(16'hD000, 8'h46);    // mode 6 + LMS
        do_parse_and_compose();
        $display("[char_modes] mode 6 compose done; sets=%0d", mock_set_count);

        begin : v6
            integer      fb_off;
            integer      c;
            integer      b;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            logic [7:0]  glyph_byte;
            for (c = 0; c < 20; c = c + 1) begin
                glyph_byte = (c[7:0] & 8'h3F) ^ 8'd0;
                for (b = 0; b < 8; b = b + 1) begin
                    exp_v = m6_px(glyph_byte, b, c[7:6]);
                    fb_off = c * 16 + b * 2;
                    got    = u_mock.fb[fb_off];
                    if (got !== exp_v) begin
                        if (fail_count < 16) begin
                            $display("FAIL mode6 r0 c=%0d b=%0d/lo got $%02h exp $%02h",
                                     c, b, got, exp_v);
                        end
                        fail_count++;
                    end
                    fb_off = c * 16 + b * 2 + 1;
                    got    = u_mock.fb[fb_off];
                    if (got !== exp_v) begin
                        if (fail_count < 16) begin
                            $display("FAIL mode6 r0 c=%0d b=%0d/hi got $%02h exp $%02h",
                                     c, b, got, exp_v);
                        end
                        fail_count++;
                    end
                end
            end
        end
        test_count++;
        $display("[char_modes] mode 6 verified");
        dump_ppm("visual/char_mode6.ppm", 320, 8, 3);

        // ==== Mode 3: descender support ================================
        // Mode 3 has 10 scan lines per char (vs 8 for mode 2). Codes
        // 0..95 use rows 0..7 of the glyph in sub 0..7, and blank in
        // sub 8/9. Codes 96..127 (code[6:5]=11) are descenders: sub 0/1
        // shows glyph rows 6/7, sub 2..9 shows rows 0..7.
        load_byte(16'hD000, 8'h43);    // mode 3 + LMS
        do_parse_and_compose();
        $display("[char_modes] mode 3 compose done; sets=%0d", mock_set_count);

        begin : v3
            integer      fb_off;
            integer      c, b, sub_row;
            integer      eff_row;
            logic [7:0]  code;
            logic [7:0]  exp_glyph;
            logic [7:0]  exp_v;
            logic [7:0]  got;
            for (c = 0; c < 40; c = c + 1) begin
                code = c[7:0];
                for (sub_row = 0; sub_row < 10; sub_row = sub_row + 1) begin
                    // Compute expected glyph row per the mode-3 rules.
                    if (code[6:5] == 2'b11) begin                // descender
                        if (sub_row < 2) eff_row = sub_row + 6;
                        else             eff_row = sub_row - 2;
                    end else if (sub_row >= 8) begin              // normal blank
                        eff_row = -1;                              // → glyph all 0
                    end else begin
                        eff_row = sub_row;
                    end
                    if (eff_row < 0)
                        exp_glyph = 8'h00;
                    else
                        exp_glyph = code ^ eff_row[7:0];           // tb's charset rule
                    for (b = 0; b < 8; b = b + 1) begin
                        fb_off = sub_row * 1024 + c * 8 + b;
                        exp_v  = m2_px(exp_glyph, b);              // mode-3 px = mode-2 px
                        got    = u_mock.fb[fb_off];
                        if (got !== exp_v) begin
                            if (fail_count < 16)
                                $display("FAIL mode3 r%0d c=%0d b=%0d got $%02h exp $%02h (eff_row=%0d)",
                                         sub_row, c, b, got, exp_v, eff_row);
                            fail_count++;
                        end
                    end
                end
            end
        end
        test_count++;
        $display("[char_modes] mode 3 verified (descender + blank)");
        dump_ppm("visual/char_mode3.ppm", 320, 10, 3);

        // ---- Trap counters --------------------------------------------
        if (mock_bad_tag_count != 32'h0) begin
            $display("FAIL: mock_bad_tag_count=%0d", mock_bad_tag_count);
            fail_count++;
        end
        if (mock_set_misalign_count != 32'h0) begin
            $display("FAIL: mock_set_misalign_count=%0d", mock_set_misalign_count);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** CHAR_MODES OK *** %0d modes verified; mock_sets=%0d",
                     test_count, mock_set_count);
            $finish;
        end else begin
            $display("*** CHAR_MODES FAIL *** %0d failures across %0d modes",
                     fail_count, test_count);
            $fatal(1);
        end
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_char_modes watchdog expired (cmp_count=%0d, sets=%0d)",
                 cmp_count, mock_set_count);
        $fatal(1);
    end

endmodule

`default_nettype wire
