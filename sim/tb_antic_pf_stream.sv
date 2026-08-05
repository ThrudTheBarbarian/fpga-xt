`timescale 1ns/1ps
//
// tb_antic_pf_stream -- the progressive playfield fetcher.
//
// What is actually worth checking here is not "does it read memory" but the
// three rules that make it different from a burst fetcher:
//
//   * the index is a RUNNING COUNT, so fetches at arbitrary, uneven cycles
//     still fill consecutive buffer entries;
//   * the scan pointer advances per ACTUAL fetch, and wraps within 4 KB;
//   * a character pair is TWO accesses and ONE entry, while a later character
//     row is one access per entry and steps the pointer not at all.
//
// The schedule is driven by hand rather than by antic_dma_sched, so the fetcher
// is tested against the CONTRACT and not against the scheduler's current
// behaviour -- if the two ever disagree, this still says which one moved.
//
module tb_antic_pf_stream;

    logic        clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        line_start = 0, first_row = 1;
    logic [3:0]  mode = 4'hF;
    logic [4:0]  row = 0;
    logic [7:0]  chbase = 8'hE0;
    logic [2:0]  chactl = 3'b000;
    logic [7:0]  bytes_per_line = 8'd0;
    logic        pf_fetch = 0, pf_fetch_glyph = 0;
    logic [15:0] scan_addr_in = 0;
    logic        scan_load = 0;
    logic [5:0]  rd_idx = 0;

    wire [15:0] mem_addr, scan_addr_out;
    wire        mem_req;
    wire [7:0]  rd_data, rd_code;
    wire [6:0]  lb_len;

    // ---- memory: mem_valid is mem_req delayed exactly one clock ----------
    logic [7:0] ram [0:65535];
    logic [7:0] mem_data;
    logic       mem_valid;

    always_ff @(posedge clk) begin
        mem_valid <= mem_req;
        if (mem_req) mem_data <= ram[mem_addr];
    end

    antic_pf_stream dut (
        .clk(clk), .rst(rst),
        .line_start(line_start), .first_row(first_row), .mode(mode), .row(row),
        .chbase(chbase), .chactl(chactl), .bytes_per_line(bytes_per_line),
        .pf_fetch(pf_fetch), .pf_fetch_glyph(pf_fetch_glyph),
        .scan_addr_in(scan_addr_in), .scan_load(scan_load),
        .scan_addr_out(scan_addr_out),
        .mem_addr(mem_addr), .mem_req(mem_req),
        .mem_data(mem_data), .mem_valid(mem_valid),
        .rd_idx(rd_idx), .rd_origin(6'd0),
        .rd_data(rd_data), .rd_code(rd_code), .lb_len(lb_len)
    );

    integer errors = 0;

    task check(input [255:0] what, input [15:0] got, input [15:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got $%04h expected $%04h", what, got, exp);
                errors = errors + 1;
            end else begin
                $display("  PASS %0s = $%04h", what, got);
            end
        end
    endtask

    // One scheduled fetch, at a deliberately arbitrary spacing.
    task do_fetch(input is_glyph, input integer gap);
        begin
            repeat (gap) @(posedge clk);
            pf_fetch <= 1'b1; pf_fetch_glyph <= is_glyph;
            @(posedge clk);
            pf_fetch <= 1'b0; pf_fetch_glyph <= 1'b0;
            // let the access land
            repeat (3) @(posedge clk);
        end
    endtask

    task new_line(input [3:0] m, input fr, input [7:0] bpl, input [4:0] r);
        begin
            mode <= m; first_row <= fr; bytes_per_line <= bpl; row <= r;
            @(posedge clk);
            line_start <= 1'b1; @(posedge clk); line_start <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer i;

    initial begin
        // Graphics bytes, and a character set at $E000.
        for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
        for (i = 0; i < 256; i = i + 1) ram[16'h1000 + i] = 8'(8'hA0 + i);
        // Character names at $2000, glyphs at $E000 (chbase $E0).
        for (i = 0; i < 64; i = i + 1)  ram[16'h2000 + i] = 8'(i);
        for (i = 0; i < 2048; i = i + 1) ram[16'hE000 + i] = 8'(8'h50 + i);
        // For the 4 KB wrap: the bottom of the page the pointer starts in.
        ram[16'h1000] = 8'hA0;

        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- 1. bitmap first row: singles, each stepping the pointer -----
        $display("mode F, first row: singles, running count, pointer steps");
        scan_addr_in <= 16'h1000; scan_load <= 1'b1;
        @(posedge clk); scan_load <= 1'b0;
        new_line(4'hF, 1'b1, 8'd8, 5'd0);
        for (i = 0; i < 8; i = i + 1) do_fetch(1'b0, i);   // uneven spacing
        check("lb_len", {9'd0, lb_len}, 16'd8);
        check("scan advanced by 8", scan_addr_out, 16'h1008);
        for (i = 0; i < 8; i = i + 1) begin
            rd_idx = 6'(i); #1;
            check("byte", {8'h00, rd_data}, {8'h00, 8'(8'hA0 + i)});
        end

        // ---- 2. bitmap later row: the schedule issues nothing ------------
        $display("mode F, later row: nothing fetched, buffer replayed");
        new_line(4'hF, 1'b0, 8'd8, 5'd1);
        check("scan unmoved", scan_addr_out, 16'h1008);
        rd_idx = 6'd3; #1;
        check("entry 3 still there", {8'h00, rd_data}, 16'h00A3);

        // ---- 3. character first row: pairs, two accesses one entry -------
        $display("mode 2, first row: pairs, one entry each, pointer steps once");
        scan_addr_in <= 16'h2000; scan_load <= 1'b1;
        @(posedge clk); scan_load <= 1'b0;
        new_line(4'h2, 1'b1, 8'd4, 5'd0);
        for (i = 0; i < 4; i = i + 1) begin
            do_fetch(1'b0, 1);      // name
            do_fetch(1'b1, 1);      // glyph of that name
        end
        check("scan advanced by 4 only", scan_addr_out, 16'h2004);
        for (i = 0; i < 4; i = i + 1) begin
            rd_idx = 6'(i); #1;
            check("code", {8'h00, rd_code}, {8'h00, 8'(i)});
            // glyph of character i, row 0, chbase $E0 -> $E000 + i*8
            check("glyph", {8'h00, rd_data}, {8'h00, 8'(8'h50 + i*8)});
        end

        // ---- 4. character later row: singles, glyphs, pointer frozen -----
        $display("mode 2, later row: singles are glyphs, name from the buffer");
        new_line(4'h2, 1'b0, 8'd4, 5'd3);
        for (i = 0; i < 4; i = i + 1) do_fetch(1'b0, 2);
        check("scan frozen", scan_addr_out, 16'h2004);
        for (i = 0; i < 4; i = i + 1) begin
            rd_idx = 6'(i); #1;
            check("code kept", {8'h00, rd_code}, {8'h00, 8'(i)});
            check("glyph row 3", {8'h00, rd_data}, {8'h00, 8'(8'h50 + i*8 + 3)});
        end

        // ---- 5. the 4 KB wrap --------------------------------------------
        $display("mode F: the scan pointer wraps within its 4 KB page");
        scan_addr_in <= 16'h1FFF; scan_load <= 1'b1;
        @(posedge clk); scan_load <= 1'b0;
        new_line(4'hF, 1'b1, 8'd2, 5'd0);
        do_fetch(1'b0, 1);
        check("wrapped to page bottom", scan_addr_out, 16'h1000);

        if (errors == 0) $display("tb_antic_pf_stream: all checks PASS");
        else             $display("tb_antic_pf_stream: %0d FAIL", errors);
        $finish;
    end

endmodule
