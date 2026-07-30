`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_pixel_shift — the one datapath every display mode runs through.
//
// Driven through the REAL antic_mode_tbl, so these are mode names rather than
// hand-set parameters: if the table and the shifter ever disagree about what a
// mode means, this catches it.
//
// The headline check is that every mode emits exactly 320 hi-res pixels for a
// normal-width line — the same physical invariant the mode table is built on,
// but measured through the datapath rather than asserted about the table.
//
module tb_antic_pixel_shift;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [3:0] mode;
    wire        is_char, descender, is_display;
    wire [1:0]  bpp;
    wire [3:0]  px_width;
    wire [4:0]  rows;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows), .descender(descender), .is_display(is_display)
    );

    logic       load, px_tick;
    logic [7:0] data;
    wire [1:0]  px_val;
    wire        exhausted;

    antic_pixel_shift dut (
        .clk(clk), .rst(rst),
        .bpp(bpp), .px_width(px_width),
        .load(load), .data(data), .px_tick(px_tick),
        .px_val(px_val), .exhausted(exhausted)
    );

    int fail = 0;
    logic [1:0] seen [0:63];
    int nseen;

    task automatic do_load(input [7:0] b);
        begin
            @(negedge clk); data = b; load = 1'b1;
            @(negedge clk); load = 1'b0;
        end
    endtask

    // px_val is combinational from the shifter, so sample it WHILE the tick is
    // asserted — after the tick the shifter may already have advanced.
    task automatic tick_px;
        begin
            @(negedge clk); px_tick = 1'b1;
            if (nseen < 64) seen[nseen] = px_val;
            nseen++;
            @(negedge clk); px_tick = 1'b0;
        end
    endtask

    // Emit one byte's worth of pixels and report how many hi-res pixels it took.
    task automatic run_byte(input [3:0] m, input [7:0] b, output int npx);
        begin
            mode = m; #1;
            do_load(b);
            nseen = 0;
            npx = 0;
            while (!exhausted && npx < 64) begin
                tick_px();
                npx++;
            end
        end
    endtask

    // Module scope: iverilog rejects `automatic` locals inside procedural
    // blocks ("Overriding the default variable lifetime is not yet supported").
    int npx, total, bytes_per_line;
    logic [1:0] want;

    initial begin
        load = 0; px_tick = 0; data = 0; mode = 4'hF;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: mode F — 1bpp, 1 hi-res wide, MSB first -----------------
        run_byte(4'hF, 8'b1000_0000, npx);
        if (npx != 8) begin $display("FAIL T1: mode F took %0d px, expected 8", npx); fail++; end
        if (seen[0] !== 2'b01) begin $display("FAIL T1b: px0=%b expected 01", seen[0]); fail++; end
        for (int i = 1; i < 8; i++)
            if (seen[i] !== 2'b00) begin
                $display("FAIL T1c: px%0d=%b expected 00", i, seen[i]); fail++;
            end

        // ---- T2: mode F alternating — proves the shift order --------------
        run_byte(4'hF, 8'b1010_1010, npx);
        for (int i = 0; i < 8; i++)
            if (seen[i] !== ((i % 2 == 0) ? 2'b01 : 2'b00)) begin
                $display("FAIL T2: px%0d=%b", i, seen[i]); fail++;
            end

        // ---- T3: mode E — 2bpp, 2 hi-res wide ----------------------------
        // $1B = 00 01 10 11 -> indices 0,1,2,3, each drawn twice.
        run_byte(4'hE, 8'h1B, npx);
        if (npx != 8) begin $display("FAIL T3: mode E took %0d px, expected 8", npx); fail++; end
        for (int i = 0; i < 8; i++) begin
            want = 2'(i / 2);
            if (seen[i] !== want) begin
                $display("FAIL T3b: px%0d=%b expected %b", i, seen[i], want); fail++;
            end
        end

        // ---- T4: mode 8 — 2bpp, EIGHT hi-res wide ------------------------
        // Same source byte, same index sequence, but each pixel is 4x wider.
        // Mode 8 and mode E differ ONLY by px_width — that is the whole claim.
        run_byte(4'h8, 8'h1B, npx);
        if (npx != 32) begin $display("FAIL T4: mode 8 took %0d px, expected 32", npx); fail++; end
        for (int i = 0; i < 32; i++) begin
            want = 2'(i / 8);
            if (seen[i] !== want) begin
                $display("FAIL T4b: px%0d=%b expected %b", i, seen[i], want); fail++;
            end
        end

        // ---- T5: mode 9 — 1bpp, four wide --------------------------------
        run_byte(4'h9, 8'b1100_0000, npx);
        if (npx != 32) begin $display("FAIL T5: mode 9 took %0d px, expected 32", npx); fail++; end
        for (int i = 0; i < 32; i++) begin
            want = (i < 8) ? 2'b01 : 2'b00;
            if (seen[i] !== want) begin
                $display("FAIL T5b: px%0d=%b expected %b", i, seen[i], want); fail++;
            end
        end

        // ---- T6: THE INVARIANT, measured through the datapath ------------
        // Every display mode must paint exactly 320 hi-res pixels across a
        // normal-width line. Asserted about the table in tb_antic_mode_tbl;
        // here it is measured by actually running the bytes through.
        for (int m = 2; m < 16; m++) begin
            case (m)
                2,3,4,5,13,14,15: bytes_per_line = 40;
                6,7,10,11,12:     bytes_per_line = 20;
                default:          bytes_per_line = 10;   // modes 8, 9
            endcase
            total = 0;
            for (int b = 0; b < bytes_per_line; b++) begin
                run_byte(4'(m), 8'hE4, npx);
                total += npx;
            end
            if (total != 320) begin
                $display("FAIL T6: mode %0X painted %0d hi-res px, expected 320", m, total);
                fail++;
            end
        end

        // ---- T7: a byte does not keep emitting once exhausted -------------
        run_byte(4'hF, 8'hFF, npx);
        if (!exhausted) begin $display("FAIL T7: not exhausted after 8 px"); fail++; end
        tick_px();
        if (!exhausted) begin
            $display("FAIL T7b: exhausted cleared by a tick with no reload"); fail++;
        end

        if (fail == 0) $display("tb_antic_pixel_shift: all checks PASS");
        else           $display("tb_antic_pixel_shift: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
