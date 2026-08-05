`timescale 1ns/1ps
//
// tb_antic_pf_pair -- the PROGRESSIVE fetcher driving the real renderer.
//
// tb_antic_line_render already tests antic_line_render, but it pairs it with
// antic_pf_fetch, the burst fetcher that stage 3 retires.  That test therefore
// says nothing about whether antic_pf_stream satisfies the same buffer
// contract, and "it exposes ports of the same name" is not evidence.
//
// STANDALONE-CORRECT IS NOT CORRECT IN SITU.  Each module passes its own
// testbench; what is unproven is the SEAM between them -- that the renderer's
// rd_idx lands on an entry the fetcher has actually filled, that rd_data and
// rd_code come back for the same character, and that a later character row
// (where the fetcher's index and pointer rules diverge) still presents the row
// the renderer expects.  That seam is what this exercises, and it is the last
// thing checkable without a full-system run.
//
module tb_antic_pf_pair;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        line_start = 0, first_row = 1;
    logic [3:0]  mode = 4'hF;
    logic [4:0]  row = 0;
    logic [7:0]  chbase = 8'hE0;
    logic [2:0]  chactl = 3'b000;
    logic [7:0]  bytes_per_line = 8'd4;
    logic        pf_fetch = 0, pf_fetch_glyph = 0;
    logic [15:0] scan_addr_in = 0;
    logic        scan_load = 0;
    logic        r_start = 0;

    logic [7:0]  colbk = 8'h00, colpf0 = 8'h11, colpf1 = 8'h22,
                 colpf2 = 8'h33, colpf3 = 8'h44;

    wire [5:0]  rd_idx;
    wire [7:0]  rd_data, rd_code;
    wire [6:0]  lb_len;
    wire [15:0] pf_mem_addr, scan_addr_out;
    wire        pf_mem_req;
    wire        lb_wr, r_busy, r_done;
    wire [7:0]  lb_color;
    wire [2:0]  lb_pf_src;

    logic [7:0] ram [0:65535];
    logic [7:0] mem_data;
    logic       mem_valid;

    always_ff @(posedge clk) begin
        mem_valid <= pf_mem_req;
        if (pf_mem_req) mem_data <= ram[pf_mem_addr];
    end

    antic_pf_stream u_pf (
        .clk(clk), .rst(rst),
        .line_start(line_start), .first_row(first_row), .mode(mode), .row(row),
        .chbase(chbase), .chactl(chactl), .bytes_per_line(bytes_per_line),
        .pf_fetch(pf_fetch), .pf_fetch_glyph(pf_fetch_glyph),
        .scan_addr_in(scan_addr_in), .scan_load(scan_load),
        .scan_addr_out(scan_addr_out),
        .mem_addr(pf_mem_addr), .mem_req(pf_mem_req),
        .mem_data(mem_data), .mem_valid(mem_valid),
        .rd_idx(rd_idx), .rd_origin(6'd0),
        .rd_data(rd_data), .rd_code(rd_code), .lb_len(lb_len)
    );

    antic_line_render u_render (
        .clk(clk), .rst(rst),
        .start(r_start), .emit_en(1'b1),
        .mode(mode), .bytes_per_line(bytes_per_line),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_pf_src(lb_pf_src),
        .lb_px_val(), .lb_is_hires(),
        .busy(r_busy), .done(r_done)
    );

    integer errors = 0;
    integer emitted = 0;
    logic [7:0] seen [0:1023];

    always_ff @(posedge clk)
        if (!rst && lb_wr) begin
            if (emitted < 1024) seen[emitted] = lb_color;
            emitted <= emitted + 1;
        end

    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got %0d expected %0d", what, got, exp);
                errors = errors + 1;
            end else $display("  PASS %0s = %0d", what, got);
        end
    endtask

    task do_fetch(input is_glyph);
        begin
            pf_fetch <= 1'b1; pf_fetch_glyph <= is_glyph;
            @(posedge clk);
            pf_fetch <= 1'b0; pf_fetch_glyph <= 1'b0;
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
        for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
        // Bitmap bytes: alternating bits so the renderer has something to say.
        for (i = 0; i < 64; i = i + 1) ram[16'h1000 + i] = 8'hAA;
        // Character names, and a glyph set at $E000 with a known pattern.
        for (i = 0; i < 64; i = i + 1) ram[16'h2000 + i] = 8'(i);
        for (i = 0; i < 2048; i = i + 1) ram[16'hE000 + i] = 8'hF0;

        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- mode F, first row: four graphics bytes ----------------------
        $display("mode F first row: fetch four bytes, then render them");
        scan_addr_in <= 16'h1000; scan_load <= 1'b1;
        @(posedge clk); scan_load <= 1'b0;
        new_line(4'hF, 1'b1, 8'd4, 5'd0);
        for (i = 0; i < 4; i = i + 1) do_fetch(1'b0);
        check("buffer length", {25'd0, lb_len}, 32'd4);

        emitted = 0;
        r_start <= 1'b1; @(posedge clk); r_start <= 1'b0;
        wait (r_done);
        @(posedge clk);
        // Mode F is one bit per hi-res pixel: 4 bytes -> 32 pixels.
        check("mode F pixels emitted", emitted[31:0], 32'd32);
        // $AA alternates, so the first two pixels must differ.
        if (seen[0] === seen[1]) begin
            $display("  FAIL mode F: $AA rendered as a flat run");
            errors = errors + 1;
        end else $display("  PASS mode F alternates: %02h %02h", seen[0], seen[1]);

        // ---- mode 2, first row: pairs, then render -----------------------
        $display("mode 2 first row: name+glyph pairs, then render");
        scan_addr_in <= 16'h2000; scan_load <= 1'b1;
        @(posedge clk); scan_load <= 1'b0;
        new_line(4'h2, 1'b1, 8'd4, 5'd0);
        for (i = 0; i < 4; i = i + 1) begin
            do_fetch(1'b0);     // name
            do_fetch(1'b1);     // its glyph
        end
        check("buffer length", {25'd0, lb_len}, 32'd4);
        check("pointer stepped once per character", {16'd0, scan_addr_out},
              32'h00002004);

        emitted = 0;
        r_start <= 1'b1; @(posedge clk); r_start <= 1'b0;
        wait (r_done);
        @(posedge clk);
        check("mode 2 pixels emitted", emitted[31:0], 32'd32);

        // ---- mode 2, LATER row: singles are glyphs -----------------------
        // The case where the fetcher's index and pointer rules diverge, and so
        // the one most likely to hand the renderer a mis-indexed row.
        $display("mode 2 later row: singles are glyphs, names from the buffer");
        new_line(4'h2, 1'b0, 8'd4, 5'd3);
        for (i = 0; i < 4; i = i + 1) do_fetch(1'b0);
        check("pointer frozen on a later row", {16'd0, scan_addr_out},
              32'h00002004);

        emitted = 0;
        r_start <= 1'b1; @(posedge clk); r_start <= 1'b0;
        wait (r_done);
        @(posedge clk);
        check("later-row pixels emitted", emitted[31:0], 32'd32);

        if (errors == 0) $display("tb_antic_pf_pair: all checks PASS");
        else             $display("tb_antic_pf_pair: %0d FAIL", errors);
        $finish;
    end

endmodule
