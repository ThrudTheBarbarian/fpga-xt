// tb_antic_modes.sv — ANTIC compositor per-mode pixel-rendering regression.
//
// Restores the playfield-mode coverage lost when the rp_bus-era mode tests
// (tb_char_modes / tb_gfx_modes / tb_mode_f / tb_scroll / tb_visual) were
// retired (2f3f03e, f50eb49).  Instead of the old serial-link mock it drives
// the `compositor` directly — exactly as tb_antic_seq does — and captures the
// per-pair SET command stream, checking it against a software oracle.
//
// Scope: the core per-mode pixel unpack, with the complicating features held
// off so the oracle stays small and independent:
//   - P/M graphics off (gractl=0, dmactl=0)        -> no overlay, cmd_data[23:16]=0
//   - GTIA modes off   (prior[7:6]=0)
//   - fine scroll off  (hscrol=0, vscrol=0, meta_hscrol_en/vscrol_en=0)
//   - CHACTL=0         (no reflect / invert)        -> glyph = raw char-ROM byte
//
// With P/M off, cmd_data[15:0] = {hi_pixel, lo_pixel} as 8-bit playfield owner
// codes, emitted unit-major / pair-minor, left to right — which is the order
// the writeback tap streams into the line buffer.  Three representative modes:
//   - F : 1bpp hi-res (GR.8)    bit set -> $02 (COLPF1-luma), clear -> $04 (COLPF2)
//   - 2 : 40-col text 1bpp      glyph bit set -> $02 (COLPF1), clear -> $04 (COLPF2)
//   - E : 160px 2bpp map        2-bit cell -> {$00,$01,$02,$04}
//
// The compositor composes ONE row per start_compose (task-0014 option (b)),
// so each sub-test is a single start_compose pulse over a freshly-loaded RAM.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_modes;

    localparam logic [15:0] LMS = 16'h1000;   // screen-data base in fake RAM
    localparam logic [7:0]  CHB = 8'h20;      // CHBASE -> char ROM at $2000
    localparam int          UNITS = 40;       // source units/row for F/2/E
    localparam int          PAIRS = 4;        // pairs/unit for F/2/E
    localparam int          NPAIR = UNITS*PAIRS;   // 160 pairs = 320 atari px

    // Collision golden values for the P/M scenario in the collision sub-test,
    // captured from the reference (pre-refactor) compositor.  The clk_sys
    // collision-pipeline refactor must reproduce these exactly.
    // Hi-res (mode F) lit pixels DISPLAY as COLPF1-luma but COLLIDE as PF2 (the
    // Atari GR.0/GR.8 quirk — see compositor collision_combine).  Each missile/
    // player over a lit mode-F pixel therefore latches PF2 ($4) per 4-bit nibble.
    localparam logic [15:0] EXP_MPF = 16'h4444;   // each missile over lit hi-res PF -> PF2
    localparam logic [15:0] EXP_PPF = 16'h4444;   // each player  over lit hi-res PF -> PF2
    localparam logic [15:0] EXP_MPL = 16'h0c03;   // missile-vs-player matrix
    localparam logic [15:0] EXP_PPL = 16'h4812;   // player-vs-player matrix

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- meta + config driven by the tb ---------------------------------
    logic [3:0]  m_mode;
    logic [15:0] m_lms;
    logic [3:0]  m_sub;
    logic [7:0]  chbase_r;
    logic        start;

    // P/M graphics config (default 0 -> off, so the F/2/E sub-tests are
    // unaffected; the collision sub-test drives them).
    logic [7:0]  pmbase_r, dmactl_r, gractl_r, sizem_r, vdelay_r;
    logic [7:0]  hposp_r [0:3], hposm_r [0:3];
    logic [1:0]  sizep_r [0:3];
    logic [7:0]  grafp_r [0:3];             // GRAFP0-3 shape registers ($D00D-$D010)
    logic [7:0]  grafm_r;                    // GRAFM shape register ($D011)
    logic        hitclr_r;                   // HITCLR strobe (clears collision latches)
    logic [7:0]  row_in_r = 8'd0;            // playfield row (ar_atari_row) to compose

    // The compositor adds PM_ROW_OFFSET (= antic_raster DISPLAY_TOP) to the
    // composed playfield row to get the PHYSICAL scanline the P/M DMA vertical
    // counter uses to index player/missile memory.  Mirror it here so the
    // directed P/M tests plant shape bytes at the address the fetch will read.
    localparam int PM_ROW_OFFSET = 8;

    // ---- compositor I/O --------------------------------------------------
    wire [7:0]  meta_row;
    wire [15:0] cmp_raddr;
    wire        cmp_req;
    wire [1:0]  cmd_tag;
    wire [23:0] cmd_addr, cmd_data;
    wire        cmd_valid;
    wire [15:0] mpf, ppf, mpl, ppl;
    wire        compose_done;
    wire [31:0] compose_count;

    // ---- fake combinational RAM (screen data + char ROM + P/M zeros) -----
    logic [7:0] mem [0:65535];
    wire [7:0]  mrdata = mem[cmp_raddr];

    compositor dut (
        .clk(clk), .rst(rst),
        .start_compose(start), .row_in(row_in_r),
        .meta_row(meta_row), .meta_mode(m_mode), .meta_lms_addr(m_lms),
        .meta_sub_row(m_sub), .meta_hscrol_en(1'b0), .meta_vscrol_en(1'b0),
        .chbase(chbase_r), .chactl(8'h0), .pmbase(pmbase_r), .dmactl(dmactl_r), .gractl(gractl_r),
        .hposp0(hposp_r[0]), .hposp1(hposp_r[1]), .hposp2(hposp_r[2]), .hposp3(hposp_r[3]),
        .hposm0(hposm_r[0]), .hposm1(hposm_r[1]), .hposm2(hposm_r[2]), .hposm3(hposm_r[3]),
        // No mid-line register changes in this harness: park every change-x at
        // the CHG_NONE sentinel so the per-pixel selects take the live value.
        // (Leaving these dangling resolves the select to X and blanks the
        // players, which is exactly what a missing tie-off looked like.)
        .hposp_early_flat({hposp_r[3], hposp_r[2], hposp_r[1], hposp_r[0]}),
        .hposp_chg_x_flat({4{12'h800}}),
        .sizep_early_flat({sizep_r[3][1:0], sizep_r[2][1:0],
                           sizep_r[1][1:0], sizep_r[0][1:0]}),
        .sizep_chg_x_flat({4{12'h800}}),
        .sizep0(sizep_r[0]), .sizep1(sizep_r[1]), .sizep2(sizep_r[2]), .sizep3(sizep_r[3]),
        .sizem(sizem_r), .vdelay(vdelay_r), .hscrol(4'h0), .vscrol(4'h0), .prior(8'h0),
        .grafp0(grafp_r[0]), .grafp1(grafp_r[1]), .grafp2(grafp_r[2]), .grafp3(grafp_r[3]),
        .grafm(grafm_r),
        .mem_raddr(cmp_raddr), .mem_rdata(mrdata), .mem_req(cmp_req), .mem_ready(1'b1),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1),
        .mpf_q(mpf), .ppf_q(ppf), .mpl_q(mpl), .ppl_q(ppl), .hitclr(hitclr_r),
        .compose_done(compose_done), .compose_count(compose_count)
    );

    // ---- SET-stream capture (cmd_ready tied high) ------------------------
    logic [7:0] cap_lo [0:255];
    logic [7:0] cap_hi [0:255];
    int         cap_n;
    logic       cap_rst;
    logic       allow_pm_nibble = 1'b0;   // set during P/M collision sub-tests
    int         fail = 0;

    always_ff @(posedge clk) begin
        if (cap_rst) begin
            cap_n <= 0;
        end else if (cmd_valid) begin
            // With P/M off (the F/2/E sub-tests) the M-only nibble must be 0.
            // The collision sub-tests deliberately drive missiles from the
            // register with gractl=0, so guard those with allow_pm_nibble.
            if (gractl_r == 8'h00 && !allow_pm_nibble && cmd_data[23:16] != 8'h00) begin
                $display("FAIL P/M nibble nonzero @pair %0d: %02h", cap_n, cmd_data[23:16]);
                fail++;
            end
            cap_lo[cap_n] <= cmd_data[7:0];
            cap_hi[cap_n] <= cmd_data[15:8];
            cap_n         <= cap_n + 1;
        end
    end

    // ---- Software oracle (independent of the compositor) -----------------
    function automatic logic [7:0] mode4_px(input logic [1:0] v);
        case (v) 2'd0: mode4_px = 8'h00; 2'd1: mode4_px = 8'h01;
                 2'd2: mode4_px = 8'h02; default: mode4_px = 8'h04; endcase
    endfunction

    // {hi_px, lo_px} for pair p of source byte/glyph `b`.
    function automatic logic [15:0] orc_F(input logic [7:0] b, input int p);
        orc_F = {b[6-2*p] ? 8'h02 : 8'h04, b[7-2*p] ? 8'h02 : 8'h04};  // set=COLPF1-luma, clear=COLPF2 (matches mode 2 / GR.8 fix c338d98)
    endfunction
    // Mode 2 (GR.0): set glyph bit -> PF1 ($02, text), clear -> PF2 ($04,
    // text-area background = COLPF2).  The clear case is PF2, NOT background
    // ($00) — GR.0's field is COLPF2 (blue), only the border is COLBK.
    function automatic logic [15:0] orc_2(input logic [7:0] g, input int p);
        orc_2 = {g[6-2*p] ? 8'h02 : 8'h04, g[7-2*p] ? 8'h02 : 8'h04};
    endfunction
    function automatic logic [15:0] orc_E(input logic [7:0] b, input int p);
        logic [7:0] px;
        px    = mode4_px({b[7-2*p], b[6-2*p]});
        orc_E = {px, px};                       // both atari px of a cell equal
    endfunction

    // ---- helpers ---------------------------------------------------------
    integer i;
    task automatic clear_mem;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    endtask

    // Drive one full-row compose and wait for completion.
    task automatic compose_row(input logic [3:0] mode, input logic [3:0] sub,
                               input logic [7:0] chb);
        int g;
        @(negedge clk);
        m_mode = mode;  m_sub = sub;  m_lms = LMS;  chbase_r = chb;
        cap_rst = 1'b1;  @(negedge clk);  cap_rst = 1'b0;
        start = 1'b1;    @(negedge clk);  start = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 100000);
        if (g >= 100000) begin $display("FAIL: compose_row(%01h) never completed", mode); fail++; end
        repeat (4) @(posedge clk);       // settle final capture + collision pipeline drain
    endtask

    // As compose_row but with an explicit LMS base — used by the 4K screen-data
    // wrap directed test (drives an LMS that straddles a $x000 boundary).
    task automatic compose_row_lms(input logic [3:0] mode, input logic [3:0] sub,
                                   input logic [7:0] chb, input logic [15:0] lms);
        int g;
        @(negedge clk);
        m_mode = mode;  m_sub = sub;  m_lms = lms;  chbase_r = chb;
        cap_rst = 1'b1;  @(negedge clk);  cap_rst = 1'b0;
        start = 1'b1;    @(negedge clk);  start = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 100000);
        if (g >= 100000) begin $display("FAIL: compose_row_lms(%01h) never completed", mode); fail++; end
        repeat (4) @(posedge clk);
    endtask

    // As compose_row but composes an explicit playfield row (ar_atari_row) —
    // used by the per-line P/M DMA directed test (antic_pmdma line 8).  The
    // compositor fetches the P/M shape for physical scanline row+PM_ROW_OFFSET.
    task automatic compose_row_at(input logic [3:0] mode, input logic [3:0] sub,
                                  input logic [7:0] chb, input logic [7:0] row);
        int g;
        @(negedge clk);
        m_mode = mode;  m_sub = sub;  m_lms = LMS;  chbase_r = chb;  row_in_r = row;
        cap_rst = 1'b1;  @(negedge clk);  cap_rst = 1'b0;
        start = 1'b1;    @(negedge clk);  start = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 100000);
        if (g >= 100000) begin $display("FAIL: compose_row_at(%01h,row=%0d) never completed", mode, row); fail++; end
        repeat (4) @(posedge clk);
        row_in_r = 8'd0;                 // restore default for the other sub-tests
    endtask

    // Compare the captured stream against the oracle for the active mode.
    int idx;
    logic [15:0] exp;
    logic [7:0]  src, code, glyph;
    task automatic check_row(input logic [3:0] mode, input logic [3:0] sub,
                             input logic [7:0] chb, input string label);
        int u, p, errs;
        errs = 0;
        if (cap_n != NPAIR) begin
            $display("FAIL %s: captured %0d pairs (expected %0d)", label, cap_n, NPAIR);
            fail++;
        end
        for (u = 0; u < UNITS; u++) begin
            for (p = 0; p < PAIRS; p++) begin
                idx = u*PAIRS + p;
                case (mode)
                    4'hF: begin src = mem[LMS+u];                 exp = orc_F(src, p); end
                    4'hE: begin src = mem[LMS+u];                 exp = orc_E(src, p); end
                    4'h2: begin code  = mem[LMS+u];
                                glyph = mem[(chb<<8) + ((code & 8'h7F) << 3) + {12'h0, sub[2:0]}];
                                exp   = orc_2(glyph, p); end
                    default: exp = 16'h0;
                endcase
                if (cap_lo[idx] !== exp[7:0] || cap_hi[idx] !== exp[15:8]) begin
                    if (errs < 8)
                        $display("FAIL %s u=%0d p=%0d: got {hi=%02h,lo=%02h} exp {hi=%02h,lo=%02h}",
                                 label, u, p, cap_hi[idx], cap_lo[idx], exp[15:8], exp[7:0]);
                    errs++; fail++;
                end
            end
        end
        if (errs == 0) $display("  %s OK (%0d pairs match)", label, NPAIR);
    endtask

    // ---- Test sequence ---------------------------------------------------
    initial begin
        $display("=== ANTIC_MODES TEST ===");
        m_mode = 4'h0; m_sub = 4'h0; m_lms = LMS; chbase_r = CHB;
        start = 1'b0; cap_rst = 1'b0;
        pmbase_r = 8'h0; dmactl_r = 8'h0; gractl_r = 8'h0; sizem_r = 8'h0; vdelay_r = 8'h0;
        grafm_r = 8'h0; hitclr_r = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            hposp_r[i] = 8'h0; hposm_r[i] = 8'h0; sizep_r[i] = 2'h0; grafp_r[i] = 8'h0;
        end
        clear_mem;
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---- Mode F: 1bpp hi-res. Varied bytes incl. all-0 / all-1 edges.
        clear_mem;
        mem[LMS+0] = 8'h00;  mem[LMS+1] = 8'hFF;  mem[LMS+2] = 8'h80;  mem[LMS+3] = 8'h01;
        for (i = 4; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'((i*8'h2B) ^ 8'h6D);
        compose_row(4'hF, 4'd0, CHB);
        check_row (4'hF, 4'd0, CHB, "modeF");

        // ---- Mode E: 160px 2bpp. Bytes chosen to exercise all 4 cell values.
        clear_mem;
        mem[LMS+0] = 8'h1B;  // cells 00 01 10 11 -> $00 $01 $02 $04
        mem[LMS+1] = 8'hE4;  // cells 11 10 01 00 -> $04 $02 $01 $00
        mem[LMS+2] = 8'hFF;  mem[LMS+3] = 8'h00;
        for (i = 4; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'((i*8'h4D) ^ 8'h27);
        compose_row(4'hE, 4'd0, CHB);
        check_row (4'hE, 4'd0, CHB, "modeE");

        // ---- Mode 2: 40-col text. Codes 0..39; char ROM filled per (code,row).
        clear_mem;
        for (i = 0; i < UNITS; i = i + 1) mem[LMS+i] = 8'(i);             // codes 0..39
        for (i = 0; i < 128*8; i = i + 1)                                 // char ROM rows
            mem[(CHB<<8) + i] = 8'((i*8'h3B) ^ 8'h5A);
        compose_row(4'h2, 4'd5, CHB);                                     // sub_row 5
        check_row (4'h2, 4'd5, CHB, "mode2");

        // ---- P/M collisions: players + missiles over a set (mode F) PF.
        // Locks the collision-latch behaviour (mpf/ppf/mpl/ppl) so the
        // clk_sys collision-pipeline refactor is regression-checked.  Golden
        // values are whatever the (correct) compositor produces for this
        // fixed scenario — refactor must reproduce them.
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;            // PF all set -> $04
        gractl_r = 8'h03;                 // player + missile presence enable
        dmactl_r = 8'h1C;                 // bits 2,3 = M/P DMA, bit 4 = 1-line res
        pmbase_r = 8'h30;                 // P/M base $3000
        vdelay_r = 8'h00; sizem_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) sizep_r[i] = 2'd0;                  // 1x
        hposp_r[0] = 8'd80;  hposp_r[1] = 8'd80;                          // P0/P1 overlap
        hposp_r[2] = 8'd120; hposp_r[3] = 8'd120;                         // P2/P3 overlap
        hposm_r[0] = 8'd80;  hposm_r[1] = 8'd88;
        hposm_r[2] = 8'd120; hposm_r[3] = 8'd128;
        // Shapes are fetched at physical scanline = row_in(0) + PM_ROW_OFFSET(8),
        // so plant them at offset 8 within each per-object region.
        mem[16'h3300 + PM_ROW_OFFSET] = 8'hFF;            // missile byte (all missiles shape 11)
        mem[16'h3400 + PM_ROW_OFFSET] = 8'hFF; mem[16'h3500 + PM_ROW_OFFSET] = 8'hFF;   // P0/P1 shapes
        mem[16'h3600 + PM_ROW_OFFSET] = 8'hFF; mem[16'h3700 + PM_ROW_OFFSET] = 8'hFF;   // P2/P3 shapes
        compose_row(4'hF, 4'd0, CHB);
        $display("  collisions: mpf=%04h ppf=%04h mpl=%04h ppl=%04h", mpf, ppf, mpl, ppl);
        // NOTE mpl/ppl (M-vs-P, P-vs-P) are NO LONGER produced here: they
        // moved to hdl/gtia_pm_collide.sv, which accumulates in beam time so a
        // mid-line HPOSP move or HITCLR lands at the right point in the line.
        // Their golden lives in sim/tb_pm_collide.sv.  Only the PLAYFIELD
        // collisions (mpf/ppf) are the compositor's job now.
        if (mpf === 16'h0 && ppf === 16'h0) begin
            $display("FAIL collision: PF latches zero (scenario did not exercise P/M vs playfield)");
            fail++;
        end
        if (mpf !== EXP_MPF || ppf !== EXP_PPF) begin
            $display("FAIL collision golden: got mpf=%04h ppf=%04h  exp mpf=%04h ppf=%04h",
                     mpf, ppf, EXP_MPF, EXP_PPF);
            fail++;
        end else $display("  PF collisions OK (match golden)");

        // ---- P/M from the shape REGISTER, no DMA (the $D00D-$D011 fix) ------
        // Real GTIA renders players/missiles from the live GRAFPx/GRAFM shape
        // registers positioned by HPOSPx/SIZEPx — display does NOT depend on
        // player/missile DMA being enabled (DMA just reloads the register each
        // scanline). This directed check writes GRAFP0 straight to the register
        // with BOTH player-DMA gates OFF (gractl[1]=0, dmactl[3]=0) and asserts
        // that P0 still renders and still collides with the playfield. Before
        // the fix p0_shape came ONLY from DMA and this read back all-zero.
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;   // clear latches from the golden test
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;   // PF all set -> $02 (mode F set=COLPF1)
        gractl_r = 8'h00;                 // NO player/missile presence-DMA enable
        dmactl_r = 8'h00;                 // NO P/M DMA bits — display must not depend on these
        pmbase_r = 8'h00;
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h0;   // all players off...
        end
        grafp_r[0] = 8'h80;               // ...except P0: leftmost shape bit set, CPU-written
        hposp_r[0] = 8'd80;               // x_left = (80-48)*2 = atari-x 64; covers px 64,65
        sizep_r[0] = 2'd0;                // 1x
        compose_row(4'hF, 4'd0, CHB);
        $display("  reg-path: cap_lo[32]=%02h cap_hi[32]=%02h ppf=%04h", cap_lo[32], cap_hi[32], ppf);
        // (a) P0 renders: the P|M shared bit ($10) is set at atari-x 64/65 (pair 32).
        if (!(cap_lo[32] & 8'h10) || !(cap_hi[32] & 8'h10)) begin
            $display("FAIL reg-path render: P0 shared bit not set @pair 32 (lo=%02h hi=%02h) with DMA off",
                     cap_lo[32], cap_hi[32]);
            fail++;
        end
        // (b) P0-vs-playfield collision latched ($D004 P0PF = ppf[3:0]) despite no DMA.
        if (ppf[3:0] == 4'h0) begin
            $display("FAIL reg-path collision: P0PF (ppf[3:0]) zero with a register-written shape and DMA off");
            fail++;
        end
        if ((cap_lo[32] & 8'h10) && (cap_hi[32] & 8'h10) && ppf[3:0] != 4'h0)
            $display("  reg-path OK (P0 renders + collides from GRAFP0 register, no DMA)");

        // ---- P/M shape from DMA FETCH (the pm_addr_for PMBASE-align fix) ----
        // Mirrors the acid800 antic_pmdma setup: 1-line resolution + player
        // DMA on, PMBASE=$37.  In 1-line mode the P/M region is 2KB-aligned so
        // PMBASE[2:0] are ignored -> region base $3000, player-0 shape byte for
        // the composed line.  P/M DMA indexes by the PHYSICAL scanline, so with
        // row_in=0 the fetch reads physical scanline PM_ROW_OFFSET(8):
        // $3000+$400+8 = $3408.  We plant $80 there with GRAFP0=0 and assert the
        // compositor FETCHED it (dut.p0_shape==$80), that P0 renders (shared bit
        // $10 @ pair 32) and that P0PF collision latches.
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;   // clear latches from reg-path test
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;   // PF all set -> $02 (mode F set=COLPF1)
        gractl_r = 8'h02;                 // player presence + DMA enable (GRACTL[1])
        dmactl_r = 8'h18;                 // bit3 = player DMA, bit4 = 1-line resolution
        pmbase_r = 8'h37;                 // 1-line: region = ($37 & $F8)<<8 = $3000
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;  // registers all zero...
        end
        mem[16'h3400 + PM_ROW_OFFSET] = 8'h80;   // ...P0 shape supplied ONLY by DMA (physical-scanline byte)
        hposp_r[0] = 8'd80;               // x_left = (80-48)*2 = atari-x 64; covers pair 32
        sizep_r[0] = 2'd0;                // 1x
        compose_row(4'hF, 4'd0, CHB);
        $display("  dma-path: p0_shape=%02h cap_lo[32]=%02h cap_hi[32]=%02h ppf=%04h",
                 dut.p0_shape, cap_lo[32], cap_hi[32], ppf);
        // (a) the fetch delivered the DMA byte, not $00 and not the (zero) register.
        if (dut.p0_shape !== 8'h80) begin
            $display("FAIL dma-path fetch: p0_shape=%02h (expected $80 from $3408 via PMBASE=$37 1-line)",
                     dut.p0_shape);
            fail++;
        end
        // (b) P0 renders from the DMA-fetched shape (shared P|M bit $10 @ pair 32).
        if (!(cap_lo[32] & 8'h10) || !(cap_hi[32] & 8'h10)) begin
            $display("FAIL dma-path render: P0 shared bit not set @pair 32 (lo=%02h hi=%02h)",
                     cap_lo[32], cap_hi[32]);
            fail++;
        end
        // (c) P0-vs-playfield collision latched from the DMA-fetched shape.
        if (ppf[3:0] == 4'h0) begin
            $display("FAIL dma-path collision: P0PF (ppf[3:0]) zero from a DMA-fetched shape");
            fail++;
        end
        if (dut.p0_shape === 8'h80 && (cap_lo[32] & 8'h10) && (cap_hi[32] & 8'h10) && ppf[3:0] != 4'h0)
            $display("  dma-path OK (P0 shape fetched from $3408 via PMBASE=$37 1-line, renders + collides)");

        // ---- Per-LINE P/M DMA row index (acid800 antic_pmdma "line 8") ------
        // The heart of the antic_pmdma failure.  The test writes a per-line
        // pattern $3400,x = x&$0f then, from physical scanline x=8 upward, reads
        // P0PF and asserts it reflects $3400,x.  P/M DMA indexes player memory
        // by the PHYSICAL scanline (frame-spanning vertical counter), not the
        // playfield-relative row — playfield row r displays at physical scanline
        // r+PM_ROW_OFFSET, so P0's byte for row r is at $3400 + (r+8).
        //
        // The bug: pm_addr_for indexed by cur_row (playfield row) alone, so
        // composing playfield row 0 (physical scanline 8) fetched $3400+0 = $00
        // instead of $3400+8 = $08 -> P0PF read $00, the reported
        // "One-line P0 data bad at line 8: $00 != $08".
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;   // lit mode-F PF (collides as PF2)
        // Per-line P0 shape pattern exactly like the test's initloop.
        for (i = 0; i < 32; i = i + 1) mem[16'h3400 + i] = 8'(i & 8'h0f);
        gractl_r = 8'h02;                 // player presence + DMA enable
        dmactl_r = 8'h18;                 // player DMA + 1-line resolution
        pmbase_r = 8'h37;                 // region base $3000 (2KB-aligned)
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        hposp_r[0] = 8'd80;  sizep_r[0] = 2'd0;
        begin : line8_block
            logic [7:0] r, exp_byte;
            int  errs8;
            errs8 = 0;
            // Compose several playfield rows; at each the DMA-fetched P0 shape
            // must equal $3400 + (row + PM_ROW_OFFSET) — the acid800 line index.
            for (r = 8'd0; r < 8'd16; r = r + 8'd1) begin
                hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
                compose_row_at(4'hF, 4'd0, CHB, r);
                exp_byte = mem[16'h3400 + r + PM_ROW_OFFSET[7:0]];
                // acid800 "line" number = physical scanline = row + PM_ROW_OFFSET.
                if (dut.p0_shape !== exp_byte) begin
                    $display("FAIL pmdma-line row=%0d (acid800 line %0d): p0_shape=%02h exp %02h",
                             r, r + PM_ROW_OFFSET, dut.p0_shape, exp_byte);
                    errs8++; fail++;
                end
                // The reported failure: acid800 line 8 = playfield row 0.  Byte
                // there is $3408 = $08, which must NOT read back as stale $00.
                if (r == 8'd0) begin
                    $display("  pmdma-line8: acid800 line 8 -> p0_shape=%02h (want $08, bug read $00)  P0PF=%01h",
                             dut.p0_shape, ppf[3:0]);
                    if (dut.p0_shape !== 8'h08) begin
                        $display("FAIL pmdma-line8: p0_shape=%02h expected $08 (row-0 byte $00 fetched -> the bug)",
                                 dut.p0_shape);
                        fail++;
                    end
                    if (ppf[3:0] == 4'h0) begin
                        $display("FAIL pmdma-line8: P0PF=$0 — player not colliding, P0 shape stale/zero at line 8");
                        fail++;
                    end
                end
            end
            if (errs8 == 0)
                $display("  pmdma-line OK (per-line P0 shape tracks physical scanline; acid800 line 8 = $08)");
        end
        row_in_r = 8'd0;

        // ---- 4K screen-data wrap + hi-res collision (acid800 antic_addresswrap)
        // The ANTIC screen-memory fetch counter wraps at a 4KB boundary: an LMS
        // of $0FF0 fetching 40 mode-F bytes reads $0FF0..$0FFF then WRAPS to
        // $0000.., NOT into $1000.  Two things are locked here:
        //   (b) display path: units 16..39 come from the wrapped $0000 region
        //       ($00 -> $04), not the $1000 decoy ($FF -> $02).
        //   (c) collision:   a player over a $00 (unlit) hi-res region latches
        //       NO P{i}PF (background is displayed COLPF2 but never collides).
        // ---- (b) display path -----------------------------------------------
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        for (i = 0; i < 16; i = i + 1)  mem[16'h0FF0 + i] = 8'hFF;   // units 0..15 lit
        for (i = 0; i < 24; i = i + 1)  mem[16'h0000 + i] = 8'h00;   // wrap target: unlit
        for (i = 0; i < 24; i = i + 1)  mem[16'h1000 + i] = 8'hFF;   // decoy (broken-wrap dest)
        compose_row_lms(4'hF, 4'd0, CHB, 16'h0FF0);
        $display("  wrap-disp: unit15 cap=%02h (exp 02)  unit16 cap=%02h (exp 04)",
                 cap_lo[15*4], cap_lo[16*4]);
        if (cap_lo[15*4] != 8'h02) begin
            $display("FAIL wrap-disp: unit15 (pre-wrap $FF) cap=%02h expected $02", cap_lo[15*4]);
            fail++;
        end
        if (cap_lo[16*4] != 8'h04) begin
            $display("FAIL wrap-disp: unit16 read $1000 decoy ($FF->$02) instead of wrapped $0000 ($00->$04): cap=%02h",
                     cap_lo[16*4]);
            fail++;
        end else $display("  wrap-disp OK (4K screen-data fetch wrapped $0FF0->$0000)");

        // ---- (c) hi-res collision + wrap via P/M (mirrors antic_addresswrap) --
        // P0 over the pre-boundary $00 region (units 8..15) must NOT collide;
        // P1 over the WRAPPED $00 region (units 24..31) must NOT collide; P2 over
        // a lit patch proves the collision path is live (non-vacuous).
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00;   // shapes from registers
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        for (i = 0; i < 8;  i = i + 1)  mem[16'h0FF0 + i] = 8'hFF;   // units 0..7 lit (P2)
        // units 8..15 ($0FF8..$0FFF) stay $00 (P0 region, unlit)
        for (i = 0; i < 24; i = i + 1)  mem[16'h0000 + i] = 8'h00;   // wrap target unlit (P1)
        for (i = 0; i < 24; i = i + 1)  mem[16'h1000 + i] = 8'hFF;   // decoy: lit (broken wrap)
        grafp_r[0] = 8'hFF; hposp_r[0] = 8'd80;  sizep_r[0] = 2'd3;  // P0 -> units 8..15
        grafp_r[1] = 8'hFF; hposp_r[1] = 8'd144; sizep_r[1] = 2'd3;  // P1 -> units 24..31
        grafp_r[2] = 8'hFF; hposp_r[2] = 8'd48;  sizep_r[2] = 2'd3;  // P2 -> units 0..7 (lit)
        compose_row_lms(4'hF, 4'd0, CHB, 16'h0FF0);
        $display("  wrap-coll: ppf=%04h  P0PF=%01h P1PF=%01h P2PF=%01h",
                 ppf, ppf[3:0], ppf[7:4], ppf[11:8]);
        if (ppf[11:8] == 4'h0) begin
            $display("FAIL wrap-coll: P2PF zero — collision path not exercised (vacuous)");
            fail++;
        end
        if (ppf[3:0] != 4'h0) begin
            $display("FAIL wrap-coll: P0PF=%01h nonzero — player over $00 hi-res region false-positive collision",
                     ppf[3:0]);
            fail++;
        end
        if (ppf[7:4] != 4'h0) begin
            $display("FAIL wrap-coll: P1PF=%01h nonzero — 4K wrap missed (read $1000 decoy $FF) or unlit collided",
                     ppf[7:4]);
            fail++;
        end
        if (ppf[11:8] != 4'h0 && ppf[3:0] == 4'h0 && ppf[7:4] == 4'h0)
            $display("  wrap-coll OK (unlit hi-res under P0/P1 no collision; wrapped fetch read $00)");

        // ---- Directed: hi-res (GR.0 mode 2) player-vs-PF collision = PF2 -----
        // Atari GR.0/GR.8 quirk: hi-res pixels are drawn with COLPF1 luminance
        // but register/prioritise as PLAYFIELD 2.  acid800 antic_charcontrol's
        // readval does `lda pXpf; and #$04` (PF2 bit) and expects a hit where a
        // player overlaps a LIT text pixel.  Mirror one row of that here.
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00;
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00; hposm_r[i] = 8'h0;
        end
        mem[LMS+4] = 8'h01;                              // char code 1 at unit 4 (atari-x 32..39)
        mem[(CHB<<8) + (1<<3) + 0] = 8'h03;              // glyph row 0 = $03 -> pixels 38,39 LIT
        grafp_r[0] = 8'h80; hposp_r[0] = 8'd64;          // P0 -> atari-x 32,33 (unlit)
        grafp_r[1] = 8'h80; hposp_r[1] = 8'd65;          // P1 -> atari-x 34,35 (unlit)
        grafp_r[2] = 8'h80; hposp_r[2] = 8'd66;          // P2 -> atari-x 36,37 (unlit)
        grafp_r[3] = 8'h80; hposp_r[3] = 8'd67;          // P3 -> atari-x 38,39 (LIT)
        compose_row(4'h2, 4'd0, CHB);
        $display("  hires-coll(mode2): ppf=%04h  P3PF=%01h (want PF2=$4)  P0/1/2PF=%03h (want 0)",
                 ppf, ppf[15:12], ppf[11:0]);
        if (ppf[15:12] != 4'h4) begin
            $display("FAIL hires-coll: P3 over LIT GR.0 pixel latched P3PF=%01h, expected PF2 ($4)", ppf[15:12]);
            fail++;
        end
        if (ppf[11:0] != 12'h0) begin
            $display("FAIL hires-coll: P0/P1/P2 over UNLIT GR.0 pixels false-positive ppf[11:0]=%03h", ppf[11:0]);
            fail++;
        end
        if (ppf[15:12] == 4'h4 && ppf[11:0] == 12'h0)
            $display("  hires-coll OK (lit GR.0 pixel collides as PF2; unlit no collision)");

        // ---- Directed: mode-E (lo-res 2bpp) missile-vs-PF per-cell collision --
        // Mirrors acid800 antic_linebuffering check1: byte $E4 -> cells
        // PF2,PF1,PF0,BAK; four missiles one colour-clock apart land one per
        // cell and must read m0pf=$04, m1pf=$02, m2pf=$01, m3pf=$00.
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00; vdelay_r = 8'h00;
        grafm_r = 8'hAA; sizem_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        mem[LMS+5] = 8'hE4;                              // unit 5 -> atari-x 40..47
        hposm_r[0] = 8'd68; hposm_r[1] = 8'd69; hposm_r[2] = 8'd70; hposm_r[3] = 8'd71;
        allow_pm_nibble = 1'b1;                          // missiles from register with gractl=0
        compose_row(4'hE, 4'd0, CHB);
        allow_pm_nibble = 1'b0;
        $display("  lores-coll(modeE): mpf=%04h  M0=%01h M1=%01h M2=%01h M3=%01h (want 4,2,1,0)",
                 mpf, mpf[3:0], mpf[7:4], mpf[11:8], mpf[15:12]);
        if (mpf !== 16'h0124) begin
            $display("FAIL lores-coll(modeE): mpf=%04h expected $0124 (M0=$4 M1=$2 M2=$1 M3=$0)", mpf);
            fail++;
        end else $display("  lores-coll OK (mode-E cells collide PF2/PF1/PF0/BAK)");

        // ---- Directed: left-BORDER P/M mutual collisions (acid800 gtia_collision)
        // "Missing M/P collisions on left at $22": all 4 players + all 4 missiles
        // stacked at hpos $22 (= colour clock 34 -> atari-x -28), a lit pixel each
        // (GRAFP=$80, GRAFM=$AA -> each missile %10).  This lands in the LEFT
        // BORDER, outside the playfield pixel window (atari-x 0..).  The mutual
        // collisions (M-vs-P, P-vs-P) must still register — real GTIA accumulates
        // them across the whole visible scanline.  Expected (acid800 asserts):
        //   m?pl each = $0F (each missile hits P0..P3)  -> mpl = $FFFF
        //   p0pl=$0E p1pl=$0D p2pl=$0B p3pl=$07         -> ppl = $7BDE
        //   no playfield under the (off-screen) objects   -> mpf = ppf = $0000
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;   // lit mode-F PF (render, not blank)
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00; vdelay_r = 8'h00;
        grafm_r  = 8'hAA; sizem_r = 8'h00;                        // 4 missiles, each shape %10
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h22; grafp_r[i] = 8'h80;   // players at $22
            hposm_r[i] = 8'h22;                                          // missiles at $22
        end
        compose_row(4'hF, 4'd0, CHB);
        $display("  border-coll($22): mpl=%04h ppl=%04h mpf=%04h ppf=%04h  m&=%01h p:%01h%01h%01h%01h",
                 mpl, ppl, mpf, ppf,
                 mpl[3:0]&mpl[7:4]&mpl[11:8]&mpl[15:12],
                 ppl[3:0], ppl[7:4], ppl[11:8], ppl[15:12]);
        // mpl/ppl border behaviour now lives in sim/tb_pm_collide.sv (T7/T8),
        // which pins the same $22-collides / $21-does-not boundary against the
        // beam-time engine.  Only the "no false PF collision" half is the
        // compositor's business here.
        if (mpf !== 16'h0 || ppf !== 16'h0) begin
            $display("FAIL border-coll: off-screen objects false-positive PF collision mpf=%04h ppf=%04h", mpf, ppf);
            fail++;
        end
        if (mpf === 16'h0 && ppf === 16'h0)
            $display("  border-coll OK (off-screen objects make no PF collision)");

        // ---- Negative control: hpos $21 = HBLANK, one colour clock further left
        // ($21 -> atari-x -30), past the visible edge -> NO collision at all.
        // Pins the exact left boundary (acid800 checks $21 = none, $22 = full).
        hitclr_r = 1'b1;  @(negedge clk);  hitclr_r = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            hposp_r[i] = 8'h21; hposm_r[i] = 8'h21;
        end
        compose_row(4'hF, 4'd0, CHB);
        // The $21/$22 left-bound discrimination moved to tb_pm_collide T7/T8.
        $display("  border-coll($21 HBLANK): PF-only check (mpl/ppl now in tb_pm_collide)");

        if (fail == 0) begin
            $display("*** ANTIC_MODES OK *** modes F/2/E, %0d pairs each", NPAIR);
            $finish;
        end else begin
            $display("*** ANTIC_MODES FAIL *** %0d mismatches", fail);
            $fatal(1);
        end
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_antic_modes watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
