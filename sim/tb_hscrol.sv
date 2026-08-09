// tb_hscrol.sv — exhaustive HSCROL fine-scroll check for the compositor.
//
// Drives the `compositor` directly (like tb_antic_modes) with meta_hscrol_en=1
// and hscrol = 0..15, for text mode 2 and map mode 4, using pseudo-random
// content and a full-row software oracle:
//
//     screen[x] == source[x + 2*hscrol]      (x = 0..319 atari px)
//
// where source[] is the UNSHIFTED per-atari-pixel owner-code stream built from
// the char codes + char ROM.  A pass proves the fine sub-pixel shift is applied
// smoothly (2 atari px per hscrol step) across the whole range and real content
// — NOT byte-granular.  Any dropped fractional shift shows as a mismatch.
//
// Build: iverilog -g2012 -I ../hdl compositor.sv tb_hscrol.sv

`default_nettype none
`timescale 1ns / 1ps

module tb_hscrol;

    localparam logic [15:0] LMS = 16'h1000;
    localparam logic [7:0]  CHB = 8'h20;
    localparam int          UNITS = 40;            // displayed chars (normal width)

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [3:0]  m_mode;
    logic        hscrol_en;
    logic [3:0]  hscrol_v;
    logic        start;

    wire [7:0]  meta_row;
    wire [15:0] cmp_raddr;
    wire [1:0]  cmd_tag;
    wire [23:0] cmd_addr, cmd_data;
    wire        cmd_valid;
    wire        compose_done;

    logic [7:0] mem [0:65535];
    wire [7:0]  mrdata = mem[cmp_raddr];

    compositor dut (
        .clk(clk), .rst(rst),
        .start_compose(start), .row_in(8'd0),
        .meta_row(meta_row), .meta_mode(m_mode), .meta_lms_addr(LMS),
        .meta_sub_row(4'd0), .meta_hscrol_en(hscrol_en), .meta_vscrol_en(1'b0),
        .chbase(CHB), .chactl(8'h0), .pmbase(8'h0), .dmactl(8'h0), .gractl(8'h0),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0), .hscrol(hscrol_v), .vscrol(4'h0), .prior(8'h0),
        .mem_raddr(cmp_raddr), .mem_rdata(mrdata), .mem_req(), .mem_ready(1'b1),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1),
        .mpf_q(), .ppf_q(), .mpl_q(), .ppl_q(), .hitclr(1'b0),
        .compose_done(compose_done), .compose_count());

    // per-atari-x capture (emitted left->right, one pair = 2 atari px per cmd)
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

    // ---- software oracle: source[] owner code at atari position k ----------
    // mode 2: 1 atari/bit;  mode 4: 2 atari/cell.  code b7=0 in our content so
    // v=3 -> $04 (never $08).
    function automatic logic [7:0] src_px(input logic [3:0] mode, input int k);
        int          byteidx, inbyte;
        logic [7:0]  code, glyph;
        logic [2:0]  bit_idx;
        logic [1:0]  cell_idx, cv;
        byteidx = k / 8;
        inbyte  = k % 8;
        code    = mem[LMS + byteidx];
        glyph   = mem[(CHB<<8) + ((code & 8'h7F) << 3) + 0];   // sub row 0
        if (mode == 4'h2) begin
            bit_idx = 3'd7 - inbyte[2:0];
            src_px  = glyph[bit_idx] ? 8'h02 : 8'h04;
        end else begin // mode 4
            cell_idx = inbyte[2:1];
            cv       = {glyph[3'd7 - {cell_idx,1'b0}], glyph[3'd6 - {cell_idx,1'b0}]};
            case (cv) 2'd0: src_px=8'h00; 2'd1: src_px=8'h01;
                      2'd2: src_px=8'h02; default: src_px=8'h04; endcase
        end
    endfunction

    integer i;
    int seed;

    task automatic load_content(input logic [3:0] mode);
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        // 64 char codes (b7 forced 0), + a char ROM. Wide fetch reads up to
        // ~byte 43; give plenty of margin.
        seed = 32'h1234_5678;
        for (i = 0; i < 64; i = i + 1) begin
            mem[LMS+i] = 8'($random(seed)) & 8'h7F;
        end
        for (i = 0; i < 128*8; i = i + 1)
            mem[(CHB<<8) + i] = 8'($random(seed));
    endtask

    task automatic run(input logic [3:0] mode, input logic [3:0] hv);
        int g, x, errs;
        @(negedge clk);
        m_mode = mode; hscrol_en = (hv != 0); hscrol_v = hv;
        cap_rst = 1'b1; @(negedge clk); cap_rst = 1'b0;
        start = 1'b1;   @(negedge clk); start = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 100000);
        repeat (4) @(posedge clk);
        // compare all 320 displayed atari px against the oracle
        errs = 0;
        for (x = 0; x < UNITS*8; x++) begin
            if (px[x] !== src_px(mode, x + 2*hv)) begin
                if (errs < 4)
                    $display("    mode%0h h=%0d x=%0d: got %02h exp %02h (src idx %0d)",
                             mode, hv, x, px[x], src_px(mode, x+2*hv), x+2*hv);
                errs++;
            end
        end
        if (errs != 0) begin
            $display("  mode%0h hscrol=%2d : %0d/%0d px mismatch  <-- JERKY/WRONG", mode, hv, errs, UNITS*8);
            fail++;
        end else
            $display("  mode%0h hscrol=%2d : all %0d px == source[x+%0d]  (smooth)", mode, hv, UNITS*8, 2*hv);
    endtask

    integer hv;
    initial begin
        $display("=== HSCROL EXHAUSTIVE PROBE (hscrol 0..15, modes 2 & 4) ===");
        m_mode=4'h0; hscrol_en=0; hscrol_v=0; start=0; cap_rst=0;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        $display("-- mode 2 (text, the title-scroll case) --");
        load_content(4'h2);
        for (hv = 0; hv <= 15; hv++) run(4'h2, hv[3:0]);

        $display("-- mode 4 (map, the DR bottom-view case) --");
        load_content(4'h4);
        for (hv = 0; hv <= 15; hv++) run(4'h4, hv[3:0]);

        if (fail == 0) $display("*** HSCROL OK *** fine scroll smooth = 2*hscrol atari px, all 0..15, modes 2 & 4");
        else           $display("*** HSCROL FAIL *** %0d hscrol values wrong", fail);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("FAIL: tb_hscrol watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
