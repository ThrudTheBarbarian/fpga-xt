// tb_pm.sv — M9b/c P/M overlay verification.
//
// Drives 4 separate compose passes ("phases") through the same
// dl_parser/compositor/rp_tx/rp_bus_mock stack, each with a different
// PM configuration. After each pass, an oracle re-derives the expected
// framebuffer for atari_x 0..143 and compares to u_mock.fb.
//
//   Phase 1: SIZEP=00, SIZEM=00, 1-line resolution, no VDELAY (M9b baseline).
//   Phase 2: P0 SIZEP=01 (2x, 32 px wide) + M2 SIZEM=01 (2x, 8 px wide).
//   Phase 3: 2-line resolution (DMACTL[4]=0). Verify on atari_row=2 (which
//            indexes byte (cur_row >> 1) = 1 in the PM area).
//   Phase 4: VDELAY=$10 (P0 only). Verify on atari_row=1: P0 should use
//            byte at row 0 instead of row 1.
//
// PMBASE=$80 in 1-line modes; PM bytes laid out at:
//   missile : $8300 + atari_row
//   P0..P3  : $8400/$8500/$8600/$8700 + atari_row
// In 2-line mode (DMACTL[4]=0) PMBASE-relative offsets halve:
//   missile : $8180 + (atari_row >> 1)
//   P0..P3  : $8200/$8280/$8300/$8380 + (atari_row >> 1)
//
// All players have HPOSP at the same position across phases:
//   P0=64 → atari_x_left=32; P1=80 → 64; P2=96 → 96; P3=112 → 128
//   M2=56 → atari_x_left=16

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_pm;

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
        .vscrol(4'h0),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata), .mem_req(), .mem_ready(1'b1),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_dli(dl_meta_dli),
        .meta_lms_addr(dl_meta_lms), .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
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

    // Per-phase configuration (all settable via <=).
    logic [7:0]  pmbase_reg = 8'h80;
    logic [7:0]  dmactl_reg = 8'h1C;       // bits 2/3 = M+P DMA; bit 4 = 1-line
    logic [7:0]  gractl_reg = 8'h03;       // bit 0 = missile, bit 1 = player presence
    logic [7:0]  hposp0_reg = 8'd64;
    logic [7:0]  hposp1_reg = 8'd80;
    logic [7:0]  hposp2_reg = 8'd96;
    logic [7:0]  hposp3_reg = 8'd112;
    logic [7:0]  hposm0_reg = 8'd200;
    logic [7:0]  hposm1_reg = 8'd200;
    logic [7:0]  hposm2_reg = 8'd56;
    logic [7:0]  hposm3_reg = 8'd200;
    logic [1:0]  sizep0_reg = 2'd0;
    logic [1:0]  sizep1_reg = 2'd0;
    logic [1:0]  sizep2_reg = 2'd0;
    logic [1:0]  sizep3_reg = 2'd0;
    logic [7:0]  sizem_reg  = 8'h00;
    logic [7:0]  vdelay_reg = 8'h00;
    logic        hitclr_reg = 1'b0;
    wire  [15:0] cmp_mpf, cmp_ppf, cmp_mpl, cmp_ppl;

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .chbase(8'h00), .chactl(8'h00),
        .pmbase(pmbase_reg), .dmactl(dmactl_reg), .gractl(gractl_reg),
        .hposp0(hposp0_reg), .hposp1(hposp1_reg), .hposp2(hposp2_reg), .hposp3(hposp3_reg),
        .hposm0(hposm0_reg), .hposm1(hposm1_reg), .hposm2(hposm2_reg), .hposm3(hposm3_reg),
        .sizep0(sizep0_reg), .sizep1(sizep1_reg), .sizep2(sizep2_reg), .sizep3(sizep3_reg),
        .sizem(sizem_reg),
        .vdelay(vdelay_reg),
        .hscrol(4'h0), .vscrol(4'h0),
        .prior(8'h00),
        .mpf_q(cmp_mpf), .ppf_q(cmp_ppf), .mpl_q(cmp_mpl), .ppl_q(cmp_ppl),
        .hitclr(hitclr_reg),
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

    localparam int DL_ROWS  = 32;
    localparam int FB_BYTES = 64 * 1024;
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

    `include "dump_ppm.svh"

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

    // ---- Oracle helpers ------------------------------------------------
    // player_oracle: presence of a player at atari_x, given size (0..3).
    function automatic logic player_oracle(input integer atari_x,
                                            input integer hposp,
                                            input logic [7:0] shape,
                                            input logic [1:0] sizep);
        integer x_left, dx, width, bit_idx;
        if (shape == 8'h00) return 1'b0;
        x_left = (hposp - 48) * 2;
        dx     = atari_x - x_left;
        case (sizep)
            2'd1:    begin width = 32; bit_idx = 7 - (dx >> 2); end
            2'd3:    begin width = 64; bit_idx = 7 - (dx >> 3); end
            default: begin width = 16; bit_idx = 7 - (dx >> 1); end
        endcase
        if (dx < 0 || dx >= width) return 1'b0;
        return (shape >> bit_idx) & 1'b1;
    endfunction

    function automatic logic missile_oracle(input integer atari_x,
                                             input integer hposm,
                                             input logic [1:0] m_shape,
                                             input logic [1:0] m_size);
        integer x_left, dx, width, bit_idx;
        if (m_shape == 2'h0) return 1'b0;
        x_left = (hposm - 48) * 2;
        dx     = atari_x - x_left;
        case (m_size)
            2'd1:    begin width = 8;  bit_idx = 1 - (dx >> 2); end
            2'd3:    begin width = 16; bit_idx = 1 - (dx >> 3); end
            default: begin width = 4;  bit_idx = 1 - (dx >> 1); end
        endcase
        if (dx < 0 || dx >= width) return 1'b0;
        return (m_shape >> bit_idx) & 1'b1;
    endfunction

    // verify_row: oracle-compares u_mock.fb starting at row*1024.
    task automatic verify_row(input string tag,
                               input integer row,
                               input logic [7:0] p0_sh,
                               input logic [7:0] p1_sh,
                               input logic [7:0] p2_sh,
                               input logic [7:0] p3_sh,
                               input logic [1:0] m0_sh,
                               input logic [1:0] m1_sh,
                               input logic [1:0] m2_sh,
                               input logic [1:0] m3_sh);
        integer atari_x;
        integer pf_byte_idx, pf_bit;
        logic [7:0] pf_byte_val, exp_v, got;
        for (atari_x = 0; atari_x < 144; atari_x = atari_x + 1) begin
            pf_byte_idx = atari_x >> 3;
            pf_bit      = 7 - (atari_x & 7);
            pf_byte_val = (pf_byte_idx & 1) ? 8'h00 : 8'hFF;
            exp_v       = pf_byte_val[pf_bit] ? 8'h04 : 8'h00;
            if (player_oracle(atari_x, hposp0_reg, p0_sh, sizep0_reg) ||
                missile_oracle(atari_x, hposm0_reg, m0_sh, sizem_reg[1:0]))
                exp_v = exp_v | 8'h10;
            if (player_oracle(atari_x, hposp1_reg, p1_sh, sizep1_reg) ||
                missile_oracle(atari_x, hposm1_reg, m1_sh, sizem_reg[3:2]))
                exp_v = exp_v | 8'h20;
            if (player_oracle(atari_x, hposp2_reg, p2_sh, sizep2_reg) ||
                missile_oracle(atari_x, hposm2_reg, m2_sh, sizem_reg[5:4]))
                exp_v = exp_v | 8'h40;
            if (player_oracle(atari_x, hposp3_reg, p3_sh, sizep3_reg) ||
                missile_oracle(atari_x, hposm3_reg, m3_sh, sizem_reg[7:6]))
                exp_v = exp_v | 8'h80;
            got = u_mock.fb[row * 1024 + atari_x];
            if (got !== exp_v) begin
                if (fail_count < 16)
                    $display("[%s] FAIL r=%0d x=%0d got $%02h exp $%02h",
                             tag, row, atari_x, got, exp_v);
                fail_count++;
            end
        end
    endtask

    // ---- Main ----------------------------------------------------------
    initial begin
        $display("[pm] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // PF source @ $3000: alternating $FF, $00 across all DL_ROWS×40
        // bytes. LMS auto-advances 40 per row.
        begin : load_pf
            integer i;
            for (i = 0; i < DL_ROWS * 40; i = i + 1)
                load_byte(16'h3000 + 16'(i), (i & 1) ? 8'h00 : 8'hFF);
        end

        // PM tables, 1-line layout. Same byte every row so we can verify
        // any row uniformly. Phase 3 (2-line) and phase 4 (VDELAY) install
        // row-varying data below.
        begin : load_pm_1line
            integer r;
            for (r = 0; r < DL_ROWS; r = r + 1) begin
                load_byte(16'h8300 + 16'(r), 8'h30); // M2 = bits[5:4]=11
                load_byte(16'h8400 + 16'(r), 8'hAA);
                load_byte(16'h8500 + 16'(r), 8'hF0);
                load_byte(16'h8600 + 16'(r), 8'h0F);
                load_byte(16'h8700 + 16'(r), 8'hC3);
            end
        end

        // 2-line PM tables (used in phase 3 only). With DMACTL[4]=0 each
        // byte covers 2 atari rows, and area offsets halve.
        //   missile  : $8180 + (atari_row >> 1)
        //   P0..P3   : $8200/$8280/$8300/$8380 + (atari_row >> 1)
        // Note P2 area in 2-line ($8300) is the same address space as the
        // 1-line missile area; that's fine because we only use one mode at
        // a time. We pre-load both area sets.
        begin : load_pm_2line
            integer r;
            // 2-line addressing halves: byte_idx = atari_row >> 1, so
            // DL_ROWS atari rows need DL_ROWS/2 bytes. Round up.
            for (r = 0; r < (DL_ROWS + 1) / 2; r = r + 1) begin
                load_byte(16'h8180 + 16'(r), 8'h30);
                load_byte(16'h8200 + 16'(r), 8'hAA);
                load_byte(16'h8280 + 16'(r), 8'hF0);
                // P2 / P3 in 2-line mode collide with 1-line missile/P0 at
                // $8300/$8380. Phase 3 inherits whatever was loaded into
                // those slots by load_pm_1line (P2 sees $30; P3 sees $00).
            end
        end

        // DL: DL_ROWS × mode F (first w/ LMS=$3000), then JVB.
        load_byte(16'hD000, 8'h4F);   // mode F + LMS
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        begin : build_dl
            integer i;
            for (i = 0; i < DL_ROWS - 1; i = i + 1)
                load_byte(16'hD003 + 16'(i), 8'h0F);   // mode F, LMS auto-advances
            load_byte(16'hD003 + 16'(DL_ROWS - 1) + 16'd0, 8'h41);  // JVB
            load_byte(16'hD003 + 16'(DL_ROWS - 1) + 16'd1, 8'h00);
            load_byte(16'hD003 + 16'(DL_ROWS - 1) + 16'd2, 8'hD0);
        end

        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);

        // ===== Phase 1: 1-line, all sizes 1x =================================
        clear_fb();
        sizep0_reg <= 2'd0; sizep1_reg <= 2'd0; sizep2_reg <= 2'd0; sizep3_reg <= 2'd0;
        sizem_reg  <= 8'h00;
        vdelay_reg <= 8'h00;
        dmactl_reg <= 8'h1C;             // 1-line resolution
        @(posedge clk);
        run_compose();
        $display("[pm/p1] sets=%0d", mock_set_count);
        verify_row("p1", 0, 8'hAA, 8'hF0, 8'h0F, 8'hC3, 2'h0, 2'h0, 2'h3, 2'h0);
        dump_ppm("visual/pm_p1_baseline.ppm", 320, DL_ROWS, 3);

        // ===== Phase 2: P0=2x, M2=2x =========================================
        clear_fb();
        sizep0_reg <= 2'd1;              // P0 → 2x
        sizep1_reg <= 2'd0;
        sizep2_reg <= 2'd0;
        sizep3_reg <= 2'd0;
        sizem_reg  <= 8'h10;             // M2 (bits 5:4) = 01 → 2x
        vdelay_reg <= 8'h00;
        dmactl_reg <= 8'h1C;
        @(posedge clk);
        run_compose();
        $display("[pm/p2] sets=%0d", mock_set_count);
        verify_row("p2", 0, 8'hAA, 8'hF0, 8'h0F, 8'hC3, 2'h0, 2'h0, 2'h3, 2'h0);
        dump_ppm("visual/pm_p2_scaled.ppm", 320, DL_ROWS, 3);

        // ===== Phase 3: 2-line resolution, verify on row 2 ====================
        // In 2-line mode, atari_row 2 reads byte index 1 from the (halved)
        // area offsets. We loaded $8180+1 / $8200+1 / $8280+1 already.
        // To verify a row other than 0 we skip P2/P3 (they collide with the
        // 1-line missile/P0 area in this layout) and validate just P0/P1/M2.
        clear_fb();
        sizep0_reg <= 2'd0; sizep1_reg <= 2'd0; sizep2_reg <= 2'd0; sizep3_reg <= 2'd0;
        sizem_reg  <= 8'h00;
        vdelay_reg <= 8'h00;
        dmactl_reg <= 8'h0C;             // 2-line resolution: bit 4 = 0
        @(posedge clk);
        run_compose();
        $display("[pm/p3] sets=%0d (2-line)", mock_set_count);
        // P2 in 2-line mode reads $8301 which was loaded for 1-line missile
        // ($30); P3 reads $8381 which was never loaded (0).
        verify_row("p3", 2, 8'hAA, 8'hF0, 8'h30, 8'h00, 2'h0, 2'h0, 2'h3, 2'h0);
        dump_ppm("visual/pm_p3_2line.ppm", 320, DL_ROWS, 3);

        // ===== Phase 4: VDELAY P0 (bit 4), verify on row 1 ====================
        // Override P0 row 0 = $55. With VDELAY=$10, on row 1 the compositor
        // fetches from row 0 (=$55) instead of row 1 (=$AA from load_pm_1line).
        load_byte(16'h8400, 8'h55);
        clear_fb();
        sizep0_reg <= 2'd0; sizep1_reg <= 2'd0; sizep2_reg <= 2'd0; sizep3_reg <= 2'd0;
        sizem_reg  <= 8'h00;
        vdelay_reg <= 8'h10;             // P0 VDELAY only
        dmactl_reg <= 8'h1C;             // 1-line again
        @(posedge clk);
        run_compose();
        $display("[pm/p4] sets=%0d (vdelay)", mock_set_count);
        verify_row("p4", 1, 8'h55, 8'hF0, 8'h0F, 8'hC3, 2'h0, 2'h0, 2'h3, 2'h0);
        dump_ppm("visual/pm_p4_vdelay.ppm", 320, DL_ROWS, 3);

        // ===== Phase 5: collision latches + HITCLR ===========================
        // HITCLR first to start from a clean slate (phases 1-4 accumulated).
        @(posedge clk);
        hitclr_reg <= 1'b1;
        @(posedge clk);
        hitclr_reg <= 1'b0;
        @(posedge clk);
        if (cmp_mpf !== 16'h0 || cmp_ppf !== 16'h0
            || cmp_mpl !== 16'h0 || cmp_ppl !== 16'h0) begin
            $display("[p5/hitclr-pre] FAIL mpf=$%04h ppf=$%04h mpl=$%04h ppl=$%04h",
                     cmp_mpf, cmp_ppf, cmp_mpl, cmp_ppl);
            fail_count++;
        end

        // Configure overlapping P0/P1 + M2 to exercise every collision type.
        //   P0  HPOSP=64 (atari_x_left=32), shape $FF, 1x → covers [32,47]
        //   P1  HPOSP=68 (atari_x_left=40), shape $FF, 1x → covers [40,55]
        //   P2  shape 0 (inactive)
        //   P3  shape 0 (inactive)
        //   M2  HPOSM=68 (atari_x_left=40), shape 11, 1x → covers [40,43]
        //   PF  alternating $FF/$00 bytes (= $04, $00 nibbles per 8 px).
        //
        // Expected per-pixel oracle:
        //   atari_x [32..39]: PF=$04, P0 only       → P0PF[2]=1 (PF2 hit)
        //   atari_x [40..43]: PF=$00, P0+P1+M2      → P0PL[1], P1PL[0],
        //                                              M2PL[0], M2PL[1]
        //   atari_x [44..47]: PF=$00, P0+P1         → P0PL[1], P1PL[0]
        //   atari_x [48..55]: PF=$04, P1 only       → P1PF[2]=1
        //
        // Latch expectations:
        //   mpf=$0000   (M2 only at PF=0 region)
        //   ppf=$0044   (P0PF=$4, P1PF=$4)
        //   mpl=$0300   (M2PL bits[1:0]=11 → nibble at [11:8])
        //   ppl=$0012   (P0PL[1]=1 → bit 1; P1PL[0]=1 → bit 4)
        // The compositor composes DL_ROWS atari rows of mode F, so
        // populate every row's PM data. Otherwise stale data from earlier
        // phases would fire on later rows.
        begin : load_p5_pm
            integer r;
            for (r = 0; r < DL_ROWS; r = r + 1) begin
                load_byte(16'h8300 + 16'(r), 8'h30);  // M2 active each row
                load_byte(16'h8400 + 16'(r), 8'hFF);  // P0 active each row
                load_byte(16'h8500 + 16'(r), 8'hFF);  // P1 active each row
                load_byte(16'h8600 + 16'(r), 8'h00);  // P2 disabled
                load_byte(16'h8700 + 16'(r), 8'h00);  // P3 disabled
            end
        end

        clear_fb();
        sizep0_reg <= 2'd0; sizep1_reg <= 2'd0; sizep2_reg <= 2'd0; sizep3_reg <= 2'd0;
        sizem_reg  <= 8'h00;
        vdelay_reg <= 8'h00;
        dmactl_reg <= 8'h1C;
        hposp1_reg <= 8'd68;          // overlap P0
        hposm2_reg <= 8'd68;          // M2 inside the overlap
        @(posedge clk);
        run_compose();

        if (cmp_mpf !== 16'h0000) begin
            $display("[p5/mpf] FAIL got $%04h exp $0000", cmp_mpf); fail_count++;
        end
        if (cmp_ppf !== 16'h0044) begin
            $display("[p5/ppf] FAIL got $%04h exp $0044", cmp_ppf); fail_count++;
        end
        if (cmp_mpl !== 16'h0300) begin
            $display("[p5/mpl] FAIL got $%04h exp $0300", cmp_mpl); fail_count++;
        end
        if (cmp_ppl !== 16'h0012) begin
            $display("[p5/ppl] FAIL got $%04h exp $0012", cmp_ppl); fail_count++;
        end
        $display("[pm/p5] mpf=$%04h ppf=$%04h mpl=$%04h ppl=$%04h",
                 cmp_mpf, cmp_ppf, cmp_mpl, cmp_ppl);
        dump_ppm("visual/pm_p5_collide.ppm", 320, DL_ROWS, 3);

        // HITCLR strobe should clear all four latches.
        @(posedge clk);
        hitclr_reg <= 1'b1;
        @(posedge clk);
        hitclr_reg <= 1'b0;
        @(posedge clk);
        if (cmp_mpf !== 16'h0 || cmp_ppf !== 16'h0
            || cmp_mpl !== 16'h0 || cmp_ppl !== 16'h0) begin
            $display("[p5/hitclr-post] FAIL mpf=$%04h ppf=$%04h mpl=$%04h ppl=$%04h",
                     cmp_mpf, cmp_ppf, cmp_mpl, cmp_ppl);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** PM OK *** mock_sets=%0d", mock_set_count);
            $finish;
        end else begin
            $display("*** PM FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_500_000_000;
        $display("FAIL: tb_pm watchdog (sets=%0d)", mock_set_count);
        $fatal(1);
    end

endmodule

`default_nettype wire
