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
//   - F : 1bpp 320px hi-res     bit set -> $04 (COLPF2), clear -> $00
//   - 2 : 40-col text 1bpp      glyph bit set -> $02 (COLPF1), clear -> $00
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

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- meta + config driven by the tb ---------------------------------
    logic [3:0]  m_mode;
    logic [15:0] m_lms;
    logic [3:0]  m_sub;
    logic [7:0]  chbase_r;
    logic        start;

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
        .start_compose(start), .row_in(8'd0),
        .meta_row(meta_row), .meta_mode(m_mode), .meta_lms_addr(m_lms),
        .meta_sub_row(m_sub), .meta_hscrol_en(1'b0), .meta_vscrol_en(1'b0),
        .chbase(chbase_r), .chactl(8'h0), .pmbase(8'h0), .dmactl(8'h0), .gractl(8'h0),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0), .hscrol(4'h0), .vscrol(4'h0), .prior(8'h0),
        .mem_raddr(cmp_raddr), .mem_rdata(mrdata), .mem_req(cmp_req), .mem_ready(1'b1),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1),
        .mpf_q(mpf), .ppf_q(ppf), .mpl_q(mpl), .ppl_q(ppl), .hitclr(1'b0),
        .compose_done(compose_done), .compose_count(compose_count)
    );

    // ---- SET-stream capture (cmd_ready tied high) ------------------------
    logic [7:0] cap_lo [0:255];
    logic [7:0] cap_hi [0:255];
    int         cap_n;
    logic       cap_rst;
    int         fail = 0;

    always_ff @(posedge clk) begin
        if (cap_rst) begin
            cap_n <= 0;
        end else if (cmd_valid) begin
            if (cmd_data[23:16] != 8'h00) begin
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
        orc_F = {b[6-2*p] ? 8'h04 : 8'h00, b[7-2*p] ? 8'h04 : 8'h00};
    endfunction
    function automatic logic [15:0] orc_2(input logic [7:0] g, input int p);
        orc_2 = {g[6-2*p] ? 8'h02 : 8'h00, g[7-2*p] ? 8'h02 : 8'h00};
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
        @(posedge clk);                  // let the final capture settle
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
