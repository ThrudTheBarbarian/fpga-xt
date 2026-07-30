`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_pf_fetch — ANTIC's internal playfield line buffer.
//
// T6 is the reason this module exists at all: the fetch must consume exactly
// bytes_per_line bytes and leave the scan pointer there, INDEPENDENTLY of how
// much of the line the display window later shows. A scrolled narrow line
// fetches 40 and displays 32; if fetching were driven by emission the scan
// pointer would drift 8 bytes every scanline.
//
// T2 mirrors antic_hscrolbug's own buffer dump: a mode E line of $55/$AA lands
// in the buffer as 55 AA 55 AA ...
//
module tb_antic_pf_fetch;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        start, first_row;
    logic [3:0]  mode;
    logic [15:0] scan_addr_in;
    logic [4:0]  row;
    logic [7:0]  chbase, bytes_per_line;
    logic [2:0]  chactl;

    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    logic [5:0] rd_idx;
    wire [7:0]  rd_data, rd_code;
    wire [15:0] scan_addr_out;
    wire        busy, done;

    antic_pf_fetch dut (
        .clk(clk), .rst(rst),
        .start(start), .first_row(first_row), .mode(mode), .scan_addr_in(scan_addr_in), .row(row),
        .chbase(chbase), .chactl(chactl), .bytes_per_line(bytes_per_line),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .scan_addr_out(scan_addr_out), .busy(busy), .done(done)
    );

    // Behavioural memory, 1-clock read latency.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    int fail = 0;
    int fetches;

    // Count real memory fetches, so "how much DMA did this line cost" is
    // measurable rather than assumed.
    always @(posedge clk) if (!rst && busy) fetches++;

    task automatic fetch_line(input [3:0] m, input [15:0] sa, input [4:0] r,
                              input [7:0] nb);
        int guard;
        begin
            mode = m; scan_addr_in = sa; row = r; bytes_per_line = nb;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while (!done && guard < 2000) begin @(negedge clk); guard++; end
            if (guard >= 2000) begin
                $display("FAIL: fetch never completed"); fail++;
            end
            @(negedge clk);
        end
    endtask

    task automatic chk(input int i, input [7:0] want, input string tag);
        begin
            rd_idx = 6'(i); #1;
            if (rd_data !== want) begin
                $display("FAIL %s: buffer[%0d] = $%02h, expected $%02h",
                         tag, i, rd_data, want);
                fail++;
            end
        end
    endtask

    initial begin
        start = 0; first_row = 1'b1; mode = 0; scan_addr_in = 0; row = 0; chbase = 8'hE0;
        bytes_per_line = 0; chactl = 3'b000; rd_idx = 0; fetches = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

        // A mode E line of alternating $55/$AA, as antic_hscrolbug uses.
        for (int i = 0; i < 48; i++)
            mem[16'h2000 + i] = (i % 2 == 0) ? 8'h55 : 8'hAA;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: a bitmap line lands in the buffer in order
        // ================================================================
        fetch_line(4'hE, 16'h2000, 5'd0, 8'd40);
        for (int i = 0; i < 40; i++)
            chk(i, (i % 2 == 0) ? 8'h55 : 8'hAA, "T1");

        // ================================================================
        // T2: the antic_hscrolbug buffer dump, verbatim
        // ================================================================
        // "the first 32 bytes of the internal contents to be:
        //  55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA
        //  55 AA 55 AA 55 AA 55 AA FF 00 00 00 00 00 00 00"
        // We reproduce the shape: 24 alternating bytes then an $FF marker at
        // buffer position $18, which is what the test looks for.
        for (int i = 0; i < 24; i++)
            mem[16'h3000 + i] = (i % 2 == 0) ? 8'h55 : 8'hAA;
        mem[16'h3000 + 16'h18] = 8'hFF;
        for (int i = 25; i < 32; i++) mem[16'h3000 + i] = 8'h00;
        fetch_line(4'hE, 16'h3000, 5'd0, 8'd32);
        for (int i = 0; i < 24; i++)
            chk(i, (i % 2 == 0) ? 8'h55 : 8'hAA, "T2");
        chk(24, 8'hFF, "T2b");          // $18
        for (int i = 25; i < 32; i++) chk(i, 8'h00, "T2c");

        // ================================================================
        // T3: the scan pointer advances once per BYTE
        // ================================================================
        fetch_line(4'hE, 16'h2000, 5'd0, 8'd40);
        if (scan_addr_out !== 16'h2028) begin
            $display("FAIL T3: bitmap scan advanced to $%04h, expected $2028",
                     scan_addr_out);
            fail++;
        end
        // Character modes fetch TWICE per character but step the pointer once.
        mem[16'h4000] = 8'h41;
        mem[16'hE208] = 8'hC0;
        fetch_line(4'h2, 16'h4000, 5'd0, 8'd40);
        if (scan_addr_out !== 16'h4028) begin
            $display("FAIL T3b: char scan advanced to $%04h, expected $4028",
                     scan_addr_out);
            fail++;
        end

        // ================================================================
        // T4: the 4K wrap (antic_addresswrap)
        // ================================================================
        fetch_line(4'hE, 16'h2FFF, 5'd0, 8'd1);
        if (scan_addr_out !== 16'h2000) begin
            $display("FAIL T4: $2FFF+1 gave $%04h, expected $2000 (4K wrap)",
                     scan_addr_out);
            fail++;
        end

        // ================================================================
        // T5: character modes store the GLYPH and the CODE
        // ================================================================
        // Char $41 at $4000, CHBASE $E0 -> glyph row 0 at $E208 = $C0.
        fetch_line(4'h2, 16'h4000, 5'd0, 8'd1);
        chk(0, 8'hC0, "T5 glyph");
        rd_idx = 6'd0; #1;
        if (rd_code !== 8'h41) begin
            $display("FAIL T5b: buffer[0] code = $%02h, expected $41", rd_code);
            fail++;
        end
        // The code is what picks the colour in modes 4/5/6/7, so it has to
        // survive into the buffer.
        mem[16'h4001] = 8'hC1;
        fetch_line(4'h6, 16'h4001, 5'd0, 8'd1);
        rd_idx = 6'd0; #1;
        if (rd_code !== 8'hC1) begin
            $display("FAIL T5c: mode 6 code = $%02h, expected $C1", rd_code);
            fail++;
        end

        // ================================================================
        // T6: fetching is INDEPENDENT of the display window
        // ================================================================
        // The renderer never even connects here: whatever the window does, the
        // fetch consumes bytes_per_line bytes and leaves the pointer there.
        // This is the scrolled-narrow case: 40 fetched, 32 displayed.
        fetch_line(4'hE, 16'h2000, 5'd0, 8'd40);
        if (scan_addr_out !== 16'h2028) begin
            $display("FAIL T6: scrolled line advanced to $%04h, expected $2028 (40 bytes)",
                     scan_addr_out);
            fail++;
        end
        // ...and all 40 entries really are in the buffer, not just the first 32.
        chk(39, 8'hAA, "T6b");

        // ================================================================
        // T7: character DMA costs twice as much as bitmap DMA
        // ================================================================
        fetches = 0;
        fetch_line(4'hE, 16'h2000, 5'd0, 8'd40);
        if (fetches < 80) begin
            $display("FAIL T7: 40 bitmap bytes took %0d clocks, expected >= 80",
                     fetches);
            fail++;
        end
        begin
            int bitmap_clocks;
            bitmap_clocks = fetches;
            fetches = 0;
            fetch_line(4'h2, 16'h4000, 5'd0, 8'd40);
            if (fetches < bitmap_clocks * 2 - 8) begin
                $display("FAIL T7b: 40 chars took %0d clocks vs %0d for bitmap — char modes fetch TWICE per byte",
                         fetches, bitmap_clocks);
                fail++;
            end
        end

        // ================================================================
        // T8: CHACTL is applied on the way into the buffer
        // ================================================================
        mem[16'h4002] = 8'hC1;          // inverse-video character
        chactl = 3'b000;
        fetch_line(4'h2, 16'h4002, 5'd0, 8'd1);
        chk(0, 8'hC0, "T8 baseline");
        chactl = 3'b010;                // invert
        fetch_line(4'h2, 16'h4002, 5'd0, 8'd1);
        chk(0, 8'h3F, "T8b invert");
        chactl = 3'b001;                // blank
        fetch_line(4'h2, 16'h4002, 5'd0, 8'd1);
        chk(0, 8'h00, "T8c blank");
        chactl = 3'b100;                // reflect: row 0 pulls glyph row 7
        mem[16'hE20F] = 8'h03;
        fetch_line(4'h2, 16'h4002, 5'd0, 8'd1);
        chk(0, 8'h03, "T8d reflect");
        chactl = 3'b000;

        // ================================================================
        // T9: mode 3 descenders and blank rows
        // ================================================================
        mem[16'h5000] = 8'h60;                      // code[6:5]==11: descender
        mem[16'hE000 + 16'h60*8 + 6] = 8'hFF;       // glyph row 6
        fetch_line(4'h3, 16'h5000, 5'd0, 8'd1);
        chk(0, 8'hFF, "T9 descender row 0 pulls glyph row 6");
        mem[16'h5001] = 8'h41;                      // ordinary character
        fetch_line(4'h3, 16'h5001, 5'd8, 8'd1);
        chk(0, 8'h00, "T9b ordinary char is blank on mode 3 row 8");

        // ================================================================
        // T10: 16-row modes show each glyph row twice
        // ================================================================
        mem[16'h6000] = 8'h41;
        mem[16'hE209] = 8'h18;          // glyph row 1 of char $41
        fetch_line(4'h5, 16'h6000, 5'd2, 8'd1);
        chk(0, 8'h18, "T10 mode 5 row 2 -> glyph row 1");
        fetch_line(4'h5, 16'h6000, 5'd3, 8'd1);
        chk(0, 8'h18, "T10b mode 5 row 3 -> glyph row 1 as well");

        // ================================================================
        // T11: a non-display mode fetches nothing
        // ================================================================
        fetch_line(4'h0, 16'h2000, 5'd0, 8'd40);
        if (scan_addr_out !== 16'h2000) begin
            $display("FAIL T11: a blank line moved the scan pointer to $%04h",
                     scan_addr_out);
            fail++;
        end

        // ================================================================
        // T12: a character NAME is fetched once per mode line
        // ================================================================
        // From antic_dmapattern's own maps: a later scanline of a narrow mode 2
        // line has exactly 32 fetches for 32 characters, where the first has 64.
        // The names stay in the buffer; only the glyph row changes.
        mem[16'h4100] = 8'h41;
        mem[16'hE208] = 8'hC0;                  // char $41 glyph row 0
        mem[16'hE209] = 8'h18;                  // ...row 1
        first_row = 1'b1;
        fetch_line(4'h2, 16'h4100, 5'd0, 8'd1);
        chk(0, 8'hC0, "T12 first row glyph");

        // Now the LATER row: the name is not re-read, but the glyph is, from
        // the new row of the SAME character.
        first_row = 1'b0;
        mem[16'h4100] = 8'h7F;                  // change memory to prove it is
                                                // not re-read
        fetch_line(4'h2, 16'h4100, 5'd1, 8'd1);
        chk(0, 8'h18, "T12b later row re-reads the glyph, not the name");
        rd_idx = 6'd0; #1;
        if (rd_code !== 8'h41) begin
            $display("FAIL T12c: the later row re-read the name (code $%02h, expected $41)",
                     rd_code);
            fail++;
        end
        // ...and the scan pointer does NOT move, because it is the name fetch
        // that steps it.  Advancing every scanline would run a mode 2 block
        // through 320 bytes instead of 40.
        if (scan_addr_out !== 16'h4100) begin
            $display("FAIL T12d: a later character row moved the scan pointer to $%04h",
                     scan_addr_out);
            fail++;
        end
        mem[16'h4100] = 8'h41;

        // A later row costs HALF the DMA of a first row.
        first_row = 1'b1;
        fetches = 0;
        fetch_line(4'h2, 16'h4100, 5'd0, 8'd40);
        begin
            int first_clocks;
            first_clocks = fetches;
            first_row = 1'b0;
            fetches = 0;
            fetch_line(4'h2, 16'h4100, 5'd1, 8'd40);
            if (fetches > first_clocks * 3 / 5) begin
                $display("FAIL T12e: a later character row took %0d clocks against %0d for the first — it should be about half",
                         fetches, first_clocks);
                fail++;
            end
        end

        // ================================================================
        // T13: a multi-row BITMAP mode fetches nothing on later rows
        // ================================================================
        // mode8b, mode9b, modeAb, modeBb and modeDb in the maps are refresh
        // cycles and nothing else: the bytes are read once and replayed.
        for (int i = 0; i < 16; i++) mem[16'h4200 + i] = 8'hA5;
        first_row = 1'b1;
        fetch_line(4'h8, 16'h4200, 5'd0, 8'd10);
        chk(0, 8'hA5, "T13 first row of a mode 8 block");
        first_row = 1'b0;
        for (int i = 0; i < 16; i++) mem[16'h4200 + i] = 8'h5A;
        fetches = 0;
        fetch_line(4'h8, 16'h4200, 5'd1, 8'd10);
        if (fetches > 4) begin
            $display("FAIL T13b: a later bitmap row took %0d clocks — it should fetch nothing",
                     fetches);
            fail++;
        end
        chk(0, 8'hA5, "T13c the buffer still holds the first row's bytes");
        if (scan_addr_out !== 16'h4200) begin
            $display("FAIL T13d: a later bitmap row moved the scan pointer to $%04h",
                     scan_addr_out);
            fail++;
        end
        first_row = 1'b1;

        if (fail == 0) $display("tb_antic_pf_fetch: all checks PASS");
        else           $display("tb_antic_pf_fetch: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
