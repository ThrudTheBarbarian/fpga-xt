// tb_scroll.sv — M11 HSCROL + VSCROL verification.
//
// Phase A (HSCROL on mode F): drives a mode-F DL line with the HSCROL
// bit set, walks several HSCROL register values and asserts that
// u_mock.fb has the source content shifted left by 2*HSCROL atari px.
//
// Phase B (VSCROL): builds a 3-line DL where the middle two lines have
// the VSCROL bit set. With VSCROL=3, the first VSCROL row should have
// sub_row=3 (top crop) and the second should have sub_row=0 (continuing
// the block). Read the dl_parser metadata directly via hierarchical ref.
//
// Scope: M11a (mode F HSCROL) + M11b (VSCROL start-of-block). Char
// modes / graphics modes 8-E HSCROL deferred. VSCROL last-row truncate
// also deferred (needs DL-line lookahead).

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_scroll;

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
    logic [3:0]  vscrol_reg = 4'h0;
    wire  [7:0]  meta_row_w;
    wire  [3:0]  dl_meta_mode;
    wire         dl_meta_dli;
    wire  [15:0] dl_meta_lms;
    wire  [3:0]  dl_meta_sub;
    wire         dl_meta_hscrol_en;
    wire         dl_meta_vscrol_en;
    wire         dl_done;
    wire  [31:0] dl_count;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(dl_start),
        .dlistl(dlistl), .dlisth(dlisth),
        .vscrol(vscrol_reg),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata),
        .mem_req(), .mem_ready(1'b1),
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
    logic [3:0]  hscrol_reg = 4'h0;
    logic [7:0]  prior_reg  = 8'h00;

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .chbase(8'h00), .chactl(8'h00),
        .pmbase(8'h00), .dmactl(8'h00), .gractl(8'h00),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0),
        .hscrol(hscrol_reg), .vscrol(4'h0),
        .prior(prior_reg),
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

    localparam int FB_BYTES = 4 * 1024;
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

    int fail_count = 0;

    // Oracle: source atari_x → expected idx_buf byte. With $FF/$00
    // alternating bytes the source byte for atari_x_src is $FF when
    // (atari_x_src >> 3) is even, else $00. Mode F maps bit-set → $04.
    function automatic logic [7:0] expected_at(input integer atari_x_src);
        integer byte_idx, bit_pos;
        logic [7:0] byte_val;
        byte_idx = atari_x_src >> 3;
        bit_pos  = 7 - (atari_x_src & 7);
        byte_val = (byte_idx & 1) ? 8'h00 : 8'hFF;
        return byte_val[bit_pos] ? 8'h04 : 8'h00;
    endfunction

    task automatic verify_phase(input string tag,
                                 input integer hs_value);
        integer dest_x, src_x;
        logic [7:0] got, exp_v;
        for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
            src_x = dest_x + 2 * hs_value;
            // The compositor only fetches up to byte 40 + hs_byte_offset+1
            // = up to byte 43 for HSCROL=15. Anything past that reads as
            // 0 (BRAM default). Match that in the oracle.
            if (src_x >= 44 * 8) exp_v = 8'h00;
            else                 exp_v = expected_at(src_x);
            got = u_mock.fb[dest_x];
            if (got !== exp_v) begin
                if (fail_count < 16)
                    $display("[%s] FAIL hs=%0d dest_x=%0d src_x=%0d got=$%02h exp=$%02h",
                             tag, hs_value, dest_x, src_x, got, exp_v);
                fail_count++;
            end
        end
    endtask

    initial begin
        $display("[scroll] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // PF source: alternating $FF/$00 across 44 bytes (covers
        // HSCROL up to 15 → byte_offset up to 3, plus 41 needed).
        begin : load_pf
            integer i;
            for (i = 0; i < 44; i = i + 1)
                load_byte(16'h3000 + 16'(i), (i & 1) ? 8'h00 : 8'hFF);
        end

        // DL: one mode F line with HSCROL bit set + LMS=$3000, then JVB.
        // bit 4 of mode byte = HSCROL enable.
        load_byte(16'hD000, 8'h5F);   // 0101_1111: HSCROL + LMS + mode F
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);   // JVB
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);

        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);

        // Sweep representative HSCROL values: 0 (no shift), 1 (sub-byte),
        // 4 (byte-aligned), 7 (mid), 15 (max).
        begin : sweep
            integer i;
            integer values [0:4];
            string  tags   [0:4];
            values[0] = 0;  tags[0] = "hs0";
            values[1] = 1;  tags[1] = "hs1";
            values[2] = 4;  tags[2] = "hs4";
            values[3] = 7;  tags[3] = "hs7";
            values[4] = 15; tags[4] = "hs15";
            for (i = 0; i < 5; i = i + 1) begin
                hscrol_reg <= values[i][3:0];
                clear_fb();
                @(posedge clk);
                run_compose();
                $display("[scroll/%s] sets=%0d", tags[i], mock_set_count);
                verify_phase(tags[i], values[i]);
                dump_ppm({"visual/scroll_", tags[i], ".ppm"}, 320, 1, 8);
            end
        end

        // ===== Phase B: VSCROL start-of-block =============================
        // Build a 3-line mode-2 DL: line A (vscrol=0), line B (vscrol=1),
        // line C (vscrol=1), then JVB. With VSCROL=3, the first row of
        // line B should have sub_row=3 (entry into the block); line C's
        // first row stays at 0 (continuation, not first).
        //
        // Mode 2 DL byte: $42 = mode 2 + LMS. $62 = mode 2 + LMS + VSCROL.
        // For lines without LMS we use $02 / $22.
        load_byte(16'hD000, 8'h42);    // line A: mode 2 + LMS
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h22);    // line B: mode 2 + VSCROL bit
        load_byte(16'hD004, 8'h22);    // line C: mode 2 + VSCROL bit
        load_byte(16'hD005, 8'h41);    // JVB
        load_byte(16'hD006, 8'h00);
        load_byte(16'hD007, 8'hD0);

        vscrol_reg <= 4'd3;
        @(posedge clk);
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        repeat (4) @(posedge clk);

        // Mode 2 has scan_count = 8. With VSCROL=3:
        //   Line A (no vscrol):     atari rows 0..7, sub 0..7 (8 rows)
        //   Line B (first-of-blk):  atari rows 8..12, sub 3..7 (5 rows, top crop)
        //   Line C (last-of-blk):   atari rows 13..16, sub 0..3 (4 rows, bottom crop = V+1)
        //   total emitted: 17 rows. Row 17 retains 0 (no DL line covers it).
        if (u_dl.line_sub_row[0] !== 4'd0) begin
            $display("[v/A] FAIL line A first sub_row=%0d, expected 0",
                     u_dl.line_sub_row[0]);
            fail_count++;
        end
        if (u_dl.line_sub_row[8] !== 4'd3) begin
            $display("[v/B0] FAIL line B (first VSCROL) sub_row=%0d, expected 3 (vscrol)",
                     u_dl.line_sub_row[8]);
            fail_count++;
        end
        if (u_dl.line_sub_row[12] !== 4'd7) begin
            $display("[v/B1] FAIL line B last sub_row=%0d at row 12, expected 7",
                     u_dl.line_sub_row[12]);
            fail_count++;
        end
        if (u_dl.line_sub_row[13] !== 4'd0) begin
            $display("[v/C0] FAIL line C (continuation) sub_row=%0d, expected 0",
                     u_dl.line_sub_row[13]);
            fail_count++;
        end
        if (u_dl.line_sub_row[16] !== 4'd3) begin
            $display("[v/C1] FAIL line C last sub_row=%0d at row 16, expected 3 (= VSCROL)",
                     u_dl.line_sub_row[16]);
            fail_count++;
        end
        if (u_dl.line_mode[16] !== 4'h2) begin
            $display("[v/C2] FAIL line_mode[16]=%0h, expected 2",
                     u_dl.line_mode[16]);
            fail_count++;
        end
        if (u_dl.line_mode[17] !== 4'h0) begin
            $display("[v/PAST] FAIL line_mode[17]=%0h, expected 0 (past last-of-block)",
                     u_dl.line_mode[17]);
            fail_count++;
        end
        $display("[scroll/vscrol] A0=%0d B0=%0d B12=%0d C13=%0d C16=%0d M17=%0h",
                 u_dl.line_sub_row[0], u_dl.line_sub_row[8],
                 u_dl.line_sub_row[12], u_dl.line_sub_row[13],
                 u_dl.line_sub_row[16], u_dl.line_mode[17]);

        // ===== Phase C: GTIA mode 9 mode-F encoding =======================
        // Reload PF source at $3000 with a recognisable nibble pattern:
        //   byte b = (b*2)<<4 | (b*2+1)   so byte 0 = $01, byte 1 = $23, ...
        // Set PRIOR=$40 (GTIA 9). The compositor's mode-F path should now
        // emit the source nibble directly into idx_buf[3:0] for each
        // atari pixel (4 px per nibble). High nibble of idx_buf carries
        // P/M bits — none here, so it stays 0.
        load_byte(16'hD000, 8'h4F);     // mode F (no HSCROL, no VSCROL)
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);
        begin : load_gtia_pf
            integer i;
            logic [3:0] hi_nib, lo_nib;
            for (i = 0; i < 40; i = i + 1) begin
                hi_nib = (i*2)     & 4'hF;
                lo_nib = (i*2 + 1) & 4'hF;
                load_byte(16'h3000 + 16'(i), {hi_nib, lo_nib});
            end
        end
        prior_reg  <= 8'h40;            // PRIOR[7:6] = 01 → GTIA 9
        hscrol_reg <= 4'h0;
        clear_fb();
        @(posedge clk);
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/gtia9] sets=%0d", mock_set_count);

        // Verify nibble values land in fb[]. atari_x in [u*8 .. u*8+3]
        // → nibble = (u*2 & $F) (high nibble of byte u). atari_x in
        // [u*8+4 .. u*8+7] → nibble = (u*2+1) & $F (low nibble).
        begin : verify_gtia
            integer u, x_in_unit, atari_x;
            logic [3:0] exp_nib;
            logic [7:0] got;
            for (u = 0; u < 40; u = u + 1) begin
                for (x_in_unit = 0; x_in_unit < 8; x_in_unit = x_in_unit + 1) begin
                    atari_x = u*8 + x_in_unit;
                    if (x_in_unit < 4) exp_nib = (u*2)     & 4'hF;
                    else               exp_nib = (u*2 + 1) & 4'hF;
                    got = u_mock.fb[atari_x];
                    if (got !== {4'h0, exp_nib}) begin
                        if (fail_count < 8)
                            $display("[gtia] FAIL atari_x=%0d got=$%02h exp=$0%01h",
                                     atari_x, got, exp_nib);
                        fail_count++;
                    end
                end
            end
        end

        // ===== Phase D: HSCROL for graphics modes 8-E =====================
        // For each gfx mode, drive a known PF-source pattern through a
        // single-line DL with HSCROL ∈ {0, 4, 7} and verify the FB
        // matches the per-mode oracle.
        //
        // Source pattern: byte b = b ^ $A5 (deterministic, non-trivial).
        // Each phase uses an oracle that mirrors `gfx_pixel_extract` in
        // the compositor — the compositor and oracle should both produce
        // the same per-mode 8-bit pixel for any (byte, atari_in_byte).
        prior_reg  <= 8'h00;
        vscrol_reg <= 4'h0;

        // ----- mode 8 + HSCROL=4 -----------------------------------------
        // Mode 8: 32 atari px / source byte. HSCROL=4 → 8 atari px shift.
        load_byte(16'hD000, 8'h58);    // mode 8 + HSCROL bit + LMS
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);    // JVB
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);
        // Load enough source bytes for any of the gfx-mode HSCROL phases:
        // mode F/D/E (40 src + extras), mode A/B/C (20 src + extras),
        // mode 8/9 (10 src + extras). 48 covers all + HSCROL=15 spill.
        begin : load_pf_gfx
            integer i;
            for (i = 0; i < 48; i = i + 1)
                load_byte(16'h3000 + 16'(i), i[7:0] ^ 8'hA5);
        end
        hscrol_reg <= 4'h4;
        clear_fb();
        @(posedge clk);
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/gfx-m8-hs4] sets=%0d", mock_set_count);

        begin : verify_m8
            integer dest_x, src_x, byte_idx, atari_in_byte;
            integer cell_idx;
            logic [7:0] byte_val, exp_v, got;
            logic [1:0] cell_v;
            for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
                src_x         = dest_x + 8;     // 2*HSCROL = 8
                byte_idx      = src_x / 32;
                atari_in_byte = src_x % 32;
                cell_idx      = atari_in_byte / 8;
                byte_val      = byte_idx[7:0] ^ 8'hA5;
                cell_v        = (byte_val >> (6 - 2*cell_idx)) & 2'b11;
                case (cell_v)
                    2'd0: exp_v = 8'h00;
                    2'd1: exp_v = 8'h01;
                    2'd2: exp_v = 8'h02;
                    2'd3: exp_v = 8'h04;
                endcase
                got = u_mock.fb[dest_x];
                if (got !== exp_v) begin
                    if (fail_count < 8)
                        $display("[gfx-m8-hs4] FAIL dest_x=%0d byte=%0d (=$%02h) cell=%0d got=$%02h exp=$%02h",
                                 dest_x, byte_idx, byte_val, cell_idx, got, exp_v);
                    fail_count++;
                end
            end
        end

        // ----- mode 9 + HSCROL=7 (sub-bit shift) -------------------------
        // Mode 9: 4 atari px / bit, 32 atari px / byte. HSCROL=7 → 14
        // atari px shift = 3 atari-per-bit positions + 2 extra atari px.
        load_byte(16'hD000, 8'h59);    // mode 9 + HSCROL + LMS
        hscrol_reg <= 4'h7;
        clear_fb();
        @(posedge clk);
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/gfx-m9-hs7] sets=%0d", mock_set_count);

        begin : verify_m9
            integer dest_x, src_x, byte_idx, atari_in_byte, bit_idx;
            logic [7:0] byte_val, exp_v, got;
            for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
                src_x         = dest_x + 14;    // 2*HSCROL = 14
                byte_idx      = src_x / 32;
                atari_in_byte = src_x % 32;
                bit_idx       = 7 - (atari_in_byte / 4);
                byte_val      = byte_idx[7:0] ^ 8'hA5;
                exp_v = ((byte_val >> bit_idx) & 1'b1) ? 8'h04 : 8'h00;
                got = u_mock.fb[dest_x];
                if (got !== exp_v) begin
                    if (fail_count < 8)
                        $display("[gfx-m9-hs7] FAIL dest_x=%0d byte=%0d (=$%02h) bit=%0d got=$%02h exp=$%02h",
                                 dest_x, byte_idx, byte_val, bit_idx, got, exp_v);
                    fail_count++;
                end
            end
        end

        // ----- mode B + HSCROL=4 (16 atari px/byte) -----------------------
        load_byte(16'hD000, 8'h5B);    // mode B + HSCROL + LMS
        hscrol_reg <= 4'h4;
        clear_fb();
        @(posedge clk);
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/gfx-mB-hs4] sets=%0d", mock_set_count);

        begin : verify_mB
            integer dest_x, src_x, byte_idx, atari_in_byte, bit_idx;
            logic [7:0] byte_val, exp_v, got;
            for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
                src_x         = dest_x + 8;
                byte_idx      = src_x / 16;
                atari_in_byte = src_x % 16;
                bit_idx       = 7 - (atari_in_byte / 2);
                byte_val      = byte_idx[7:0] ^ 8'hA5;
                exp_v = ((byte_val >> bit_idx) & 1'b1) ? 8'h04 : 8'h00;
                got = u_mock.fb[dest_x];
                if (got !== exp_v) begin
                    if (fail_count < 8)
                        $display("[gfx-mB-hs4] FAIL dest_x=%0d byte=%0d (=$%02h) bit=%0d got=$%02h exp=$%02h",
                                 dest_x, byte_idx, byte_val, bit_idx, got, exp_v);
                    fail_count++;
                end
            end
        end

        // ===== Phase E: char-mode HSCROL — mode 2 ========================
        // Sub-byte HSCROL test. HSCROL=5 → atari shift=10; mode 2 has
        // 8 atari/byte, so byte_offset=1, sub=2. Pair p=3 of each unit
        // crosses into the nxt char (src_lo=8 ≥ 8). Pairs 0..2 stay in
        // the cur char.
        prior_reg  <= 8'h00;
        vscrol_reg <= 4'h0;

        // Synthetic charset at $0000 (chbase=$00 in compositor inst):
        // glyph[code][row] = code XOR row. 42 chars × 8 rows = 336 bytes.
        begin : load_chset_e
            integer code, row;
            for (code = 0; code < 42; code = code + 1)
                for (row = 0; row < 8; row = row + 1)
                    load_byte(16'(code*8 + row), code[7:0] ^ row[7:0]);
        end
        // Char codes at $3000: 42 chars (codes = i). HSCROL=5 with
        // byte_offset=1 needs char up to (39+1+1) = 41.
        begin : load_codes_e
            integer i;
            for (i = 0; i < 42; i = i + 1)
                load_byte(16'h3000 + 16'(i), i[7:0]);
        end
        // DL: mode 2 with HSCROL bit + LMS=$3000, then JVB.
        load_byte(16'hD000, 8'h52);    // HSCROL + LMS + mode 2
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);

        hscrol_reg <= 4'h5;
        clear_fb();
        @(posedge clk); @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/txt-m2-hs5] sets=%0d", mock_set_count);

        begin : verify_m2_hs5
            integer dest_x, src_x, char, in_char;
            logic [7:0] glyph, exp_v, got;
            for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
                src_x   = dest_x + 10;            // 2 * HSCROL
                char    = src_x / 8;
                in_char = src_x % 8;
                glyph   = (char < 42) ? char[7:0] : 8'h00;     // sub_row 0
                exp_v   = ((glyph >> (7 - in_char)) & 1'b1)
                            ? 8'h02 : 8'h00;
                got = u_mock.fb[dest_x];
                if (got !== exp_v) begin
                    if (fail_count < 8)
                        $display("[txt-m2-hs5] FAIL dest_x=%0d char=%0d in_char=%0d glyph=$%02h got=$%02h exp=$%02h",
                                 dest_x, char, in_char, glyph, got, exp_v);
                    fail_count++;
                end
            end
        end

        // ===== Phase F: char-mode HSCROL — mode 6 ========================
        // Mode 6: 16 atari/byte, 20 chars/row. HSCROL=11 → shift=22 atari,
        // byte_offset=1 (22/16), sub=6 (22%16). Cross-window: src_lo for
        // p∈{5,6,7} lands ≥ 16 → use nxt.
        load_byte(16'hD000, 8'h56);    // HSCROL + LMS + mode 6
        hscrol_reg <= 4'd11;
        clear_fb();
        @(posedge clk); @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        run_compose();
        $display("[scroll/txt-m6-hs11] sets=%0d", mock_set_count);

        begin : verify_m6_hs11
            integer dest_x, src_x, char, in_char, bit_idx;
            logic [7:0] glyph, exp_v, got;
            for (dest_x = 0; dest_x < 320; dest_x = dest_x + 1) begin
                src_x   = dest_x + 22;            // 2 * HSCROL
                char    = src_x / 16;
                in_char = src_x % 16;
                bit_idx = 7 - (in_char / 2);
                // glyph[code][row=0] = code (0..41 loaded; 0 elsewhere).
                // Mode 6 masks code with $3F for the glyph fetch but
                // our codes are all < 64, so the mask is a no-op.
                glyph = (char < 42) ? char[7:0] : 8'h00;
                // Mode 6 PF select: code[7:6]=00 (chars are 0..21) → $01.
                exp_v = ((glyph >> bit_idx) & 1'b1) ? 8'h01 : 8'h00;
                got   = u_mock.fb[dest_x];
                if (got !== exp_v) begin
                    if (fail_count < 8)
                        $display("[txt-m6-hs11] FAIL dest_x=%0d char=%0d in_char=%0d bit=%0d glyph=$%02h got=$%02h exp=$%02h",
                                 dest_x, char, in_char, bit_idx, glyph, got, exp_v);
                    fail_count++;
                end
            end
        end

        if (fail_count == 0) begin
            $display("*** SCROLL OK *** HSCROL + VSCROL + GTIA9 + gfx 8/9/B HSCROL + char 2/6 HSCROL");
            $finish;
        end else begin
            $display("*** SCROLL FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000_000;
        $display("FAIL: tb_scroll watchdog (sets=%0d)", mock_set_count);
        $fatal(1);
    end

endmodule

`default_nettype wire
