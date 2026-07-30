`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_line_render — a whole scanline, pixel-perfect, fetch through emit.
//
// These are the STATIC tests from docs/ANTIC-rewrite.md: a known display mode
// over known memory, compared against a hand-computed expectation. No CPU, no
// display list — just "put these bytes in memory and check every pixel".
//
// It drives the real pair, antic_pf_fetch -> antic_line_render, because the
// interesting failures live at the join: a byte fetched into the wrong buffer
// slot and a byte shifted out at the wrong moment look identical from either
// side alone.
//
module tb_antic_line_render;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        f_start, r_start;
    logic [3:0]  mode;
    logic [15:0] scan_addr_in;
    logic [4:0]  row;
    logic [7:0]  chbase, bytes_per_line;
    logic [2:0]  chactl;
    logic [7:0]  colbk, colpf0, colpf1, colpf2, colpf3;

    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    wire [15:0] scan_addr_out;
    wire        f_busy, f_done;

    wire [5:0]  rd_idx;
    wire [7:0]  rd_data, rd_code;

    wire        lb_wr, r_busy, r_done;
    wire [7:0]  lb_color;

    antic_pf_fetch u_fetch (
        .clk(clk), .rst(rst),
        .start(f_start), .mode(mode), .scan_addr_in(scan_addr_in), .row(row),
        .chbase(chbase), .chactl(chactl), .bytes_per_line(bytes_per_line),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .scan_addr_out(scan_addr_out), .busy(f_busy), .done(f_done)
    );

    antic_line_render u_render (
        .clk(clk), .rst(rst),
        .start(r_start), .emit_en(1'b1),
        .mode(mode), .bytes_per_line(bytes_per_line),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .lb_wr(lb_wr), .lb_color(lb_color),
        .busy(r_busy), .done(r_done)
    );

    // Behavioural memory: 1-clock read latency, like a BRAM.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    int fail = 0;
    int npx;
    logic [7:0] px [0:511];

    always @(posedge clk) if (!rst && lb_wr) begin
        if (npx < 512) px[npx] = lb_color;
        npx++;
    end

    task automatic render(input [3:0] m, input [15:0] sa, input [4:0] r,
                          input [7:0] nb);
        int guard;
        begin
            mode = m; scan_addr_in = sa; row = r; bytes_per_line = nb;
            @(negedge clk); f_start = 1'b1;
            @(negedge clk); f_start = 1'b0;
            guard = 0;
            while (!f_done && guard < 2000) begin @(negedge clk); guard++; end
            if (guard >= 2000) begin
                $display("FAIL: fetch never completed"); fail++;
            end
            @(negedge clk); r_start = 1'b1;
            @(negedge clk); r_start = 1'b0;
            // Count from the restart, not from the fetch: emit_en is tied high
            // here, so a line left part-emitted would otherwise keep trickling
            // pixels out during the next line's fetch.  In the real design the
            // window gate stops it.
            npx = 0;
            guard = 0;
            while (!r_done && guard < 4000) begin @(negedge clk); guard++; end
            if (guard >= 4000) begin
                $display("FAIL: render never completed"); fail++;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        f_start = 0; r_start = 0; mode = 0; scan_addr_in = 0; row = 0;
        chbase = 8'hE0; chactl = 3'b000; bytes_per_line = 0;
        colbk = 8'h00; colpf0 = 8'h28; colpf1 = 8'h3A; colpf2 = 8'h94;
        colpf3 = 8'h56;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: MODE F (1bpp hi-res) — 2 bytes, alternating bits
        // ================================================================
        // $80 = 1000_0000 -> lit, then 7 background.
        // Hi-res: lit = PF2 hue + PF1 luma.  COLPF2=$94 hue 9,
        // COLPF1=$3A luma bits [3:1] = 101 -> $9A.  Background = COLPF2 = $94.
        mem[16'h1000] = 8'h80;
        mem[16'h1001] = 8'hFF;
        render(4'hF, 16'h1000, 5'd0, 8'd2);

        if (npx != 16) begin
            $display("FAIL T1: mode F 2 bytes gave %0d px, expected 16", npx); fail++;
        end
        if (px[0] !== 8'h9A) begin
            $display("FAIL T1b: px0=$%02h expected $9A (PF2 hue + PF1 luma)", px[0]); fail++;
        end
        for (int i = 1; i < 8; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T1c: px%0d=$%02h expected $94 (hi-res bg is PF2)", i, px[i]);
                fail++;
            end
        for (int i = 8; i < 16; i++)
            if (px[i] !== 8'h9A) begin
                $display("FAIL T1d: px%0d=$%02h expected $9A", i, px[i]); fail++;
            end

        // ================================================================
        // T2: MODE E (2bpp) — index -> PF0/PF1/PF2, background COLBK
        // ================================================================
        mem[16'h2000] = 8'h1B;          // 00 01 10 11
        render(4'hE, 16'h2000, 5'd0, 8'd1);

        if (npx != 8) begin
            $display("FAIL T2: mode E gave %0d px, expected 8", npx); fail++;
        end
        // each index is 2 hi-res px wide
        if (px[0] !== 8'h00 || px[1] !== 8'h00) begin
            $display("FAIL T2b: 00 -> $%02h,$%02h expected COLBK", px[0], px[1]); fail++;
        end
        if (px[2] !== 8'h28 || px[3] !== 8'h28) begin
            $display("FAIL T2c: 01 -> $%02h expected COLPF0 $28", px[2]); fail++;
        end
        if (px[4] !== 8'h3A || px[5] !== 8'h3A) begin
            $display("FAIL T2d: 10 -> $%02h expected COLPF1 $3A", px[4]); fail++;
        end
        if (px[6] !== 8'h94 || px[7] !== 8'h94) begin
            $display("FAIL T2e: 11 -> $%02h expected COLPF2 $94", px[6]); fail++;
        end

        // ================================================================
        // T3: MODE 2 (char) — name fetch then glyph fetch
        // ================================================================
        // Character $41 at scan $3000; CHBASE $E0 -> glyph base $E000.
        // Glyph row 0 of char $41 lives at $E000 + $41*8 + 0 = $E208.
        mem[16'h3000] = 8'h41;
        mem[16'hE208] = 8'hC0;          // top two pixels lit
        render(4'h2, 16'h3000, 5'd0, 8'd1);

        if (npx != 8) begin
            $display("FAIL T3: mode 2 gave %0d px, expected 8", npx); fail++;
        end
        if (px[0] !== 8'h9A || px[1] !== 8'h9A) begin
            $display("FAIL T3b: lit px = $%02h,$%02h expected $9A", px[0], px[1]); fail++;
        end
        for (int i = 2; i < 8; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T3c: px%0d=$%02h expected $94", i, px[i]); fail++;
            end

        // ---- T4: the glyph ROW is selected by `row` ----------------------
        mem[16'hE20B] = 8'h81;          // row 3 of the same character
        render(4'h2, 16'h3000, 5'd3, 8'd1);
        if (px[0] !== 8'h9A || px[7] !== 8'h9A) begin
            $display("FAIL T4: row 3 glyph not fetched (px0=$%02h px7=$%02h)",
                     px[0], px[7]);
            fail++;
        end
        for (int i = 1; i < 7; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T4b: px%0d=$%02h expected bg", i, px[i]); fail++;
            end

        // ================================================================
        // T5: the scan pointer advances once per BYTE, not per fetch
        // ================================================================
        render(4'h2, 16'h3000, 5'd0, 8'd4);
        if (scan_addr_out !== 16'h3004) begin
            $display("FAIL T5: char mode scan advanced to $%04h, expected $3004",
                     scan_addr_out);
            fail++;
        end
        render(4'hE, 16'h2000, 5'd0, 8'd4);
        if (scan_addr_out !== 16'h2004) begin
            $display("FAIL T5b: bitmap scan advanced to $%04h, expected $2004",
                     scan_addr_out);
            fail++;
        end

        // ================================================================
        // T6: the scan pointer wraps within 4K (antic_addresswrap)
        // ================================================================
        render(4'hE, 16'h2FFF, 5'd0, 8'd1);
        if (scan_addr_out !== 16'h2000) begin
            $display("FAIL T6: $2FFF+1 gave $%04h, expected $2000 (4K wrap)",
                     scan_addr_out);
            fail++;
        end

        // ================================================================
        // T7: a full normal-width line is exactly 320 hi-res pixels
        // ================================================================
        render(4'hE, 16'h2000, 5'd0, 8'd40);
        if (npx != 320) begin
            $display("FAIL T7: mode E 40 bytes gave %0d px, expected 320", npx); fail++;
        end
        render(4'h8, 16'h2000, 5'd0, 8'd10);
        if (npx != 320) begin
            $display("FAIL T7b: mode 8 10 bytes gave %0d px, expected 320", npx); fail++;
        end
        // ...and a wide line is 384, which is the widest the buffer holds.
        render(4'hE, 16'h2000, 5'd0, 8'd48);
        if (npx != 384) begin
            $display("FAIL T7c: mode E 48 bytes gave %0d px, expected 384", npx); fail++;
        end

        // ================================================================
        // T8: MODE 3 descender — codes with bits[6:5]==11 rotate their rows
        // ================================================================
        // Char $60 (bits[6:5]=11) at row 0 must pull GLYPH row 6.
        mem[16'h4000] = 8'h60;
        mem[16'hE000 + 16'h60*8 + 6] = 8'hFF;   // glyph row 6 all lit
        render(4'h3, 16'h4000, 5'd0, 8'd1);
        for (int i = 0; i < 8; i++)
            if (px[i] !== 8'h9A) begin
                $display("FAIL T8: descender row 0 px%0d=$%02h expected lit", i, px[i]);
                fail++;
            end

        // A NON-descender on mode-3 row 8 must be blank.
        mem[16'h4001] = 8'h41;
        render(4'h3, 16'h4001, 5'd8, 8'd1);
        for (int i = 0; i < 8; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T8b: row 8 of a normal char px%0d=$%02h expected bg",
                         i, px[i]);
                fail++;
            end

        // ================================================================
        // T9: CHACTL, end to end through the real pixel path
        // ================================================================
        // Char $C1 is $41 with the inverse-video bit set; its glyph is the
        // same one T3 used, so the expected pixels are known.
        mem[16'h5000] = 8'hC1;

        chactl = 3'b000;                    // baseline: an inverse char is
        render(4'h2, 16'h5000, 5'd0, 8'd1); // drawn exactly like a plain one
        if (px[0] !== 8'h9A || px[1] !== 8'h9A) begin
            $display("FAIL T9: chactl $00 px0=$%02h px1=$%02h expected $9A",
                     px[0], px[1]);
            fail++;
        end
        for (int i = 2; i < 8; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T9b: chactl $00 px%0d=$%02h expected bg", i, px[i]);
                fail++;
            end

        chactl = 3'b010;                    // invert: $C0 -> $3F
        render(4'h2, 16'h5000, 5'd0, 8'd1);
        if (px[0] !== 8'h94 || px[1] !== 8'h94) begin
            $display("FAIL T9c: inverted px0=$%02h px1=$%02h expected bg $94",
                     px[0], px[1]);
            fail++;
        end
        for (int i = 2; i < 8; i++)
            if (px[i] !== 8'h9A) begin
                $display("FAIL T9d: inverted px%0d=$%02h expected lit $9A", i, px[i]);
                fail++;
            end

        chactl = 3'b001;                    // blank: the whole cell is bg
        render(4'h2, 16'h5000, 5'd0, 8'd1);
        for (int i = 0; i < 8; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T9e: blanked px%0d=$%02h expected bg", i, px[i]);
                fail++;
            end

        // Reflect pulls the glyph from the mirrored row: row 0 of a reflected
        // cell is glyph row 7.
        chactl = 3'b100;
        mem[16'h5001] = 8'h41;
        mem[16'hE20F] = 8'h03;              // glyph row 7 of char $41
        render(4'h2, 16'h5001, 5'd0, 8'd1);
        if (px[6] !== 8'h9A || px[7] !== 8'h9A) begin
            $display("FAIL T9f: reflected row 0 px6=$%02h px7=$%02h expected $9A",
                     px[6], px[7]);
            fail++;
        end
        for (int i = 0; i < 6; i++)
            if (px[i] !== 8'h94) begin
                $display("FAIL T9g: reflected px%0d=$%02h expected bg", i, px[i]);
                fail++;
            end
        chactl = 3'b000;

        // ================================================================
        // T10: emission can be cut short without disturbing the fetch
        // ================================================================
        // The scrolled case in miniature: fetch a full line, then stop emitting
        // partway.  The scan pointer must still reflect the whole FETCH.
        mode = 4'hE; scan_addr_in = 16'h2000; row = 5'd0; bytes_per_line = 8'd40;
        @(negedge clk); f_start = 1'b1;
        @(negedge clk); f_start = 1'b0;
        while (!f_done) @(negedge clk);
        @(negedge clk); r_start = 1'b1;
        @(negedge clk); r_start = 1'b0;
        npx = 0;
        repeat (60) @(negedge clk);         // let only part of the line emit
        if (npx >= 320) begin
            $display("FAIL T10: the whole line emitted before it could be cut short");
            fail++;
        end
        if (scan_addr_out !== 16'h2028) begin
            $display("FAIL T10b: a part-emitted line left the scan pointer at $%04h, expected $2028",
                     scan_addr_out);
            fail++;
        end
        // A fresh start must abandon the leftovers and begin at pixel 0 again.
        render(4'hE, 16'h2000, 5'd0, 8'd40);
        if (npx != 320) begin
            $display("FAIL T10c: restart after a cut-short line gave %0d px, expected 320",
                     npx);
            fail++;
        end

        if (fail == 0) $display("tb_antic_line_render: all checks PASS");
        else           $display("tb_antic_line_render: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
