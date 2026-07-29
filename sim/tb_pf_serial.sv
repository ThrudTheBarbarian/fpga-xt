`timescale 1ns/1ps
`default_nettype none
//
// tb_pf_serial — playfield byte stream -> per-colour-clock nibble, chained
// into gtia_stream so the whole beam-time pixel path is exercised end to end.
//
// The point is not just that the unpack is right, but that a mid-line COLPF
// write changes only the pixels from that colour clock onward — the thing the
// burst compositor structurally cannot do (docs/video/gtia-streaming.md).
//
module tb_pf_serial;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [3:0] mode;
    logic       pf_valid;
    logic [7:0] pf_byte;
    logic       cc_tick;

    wire [3:0] pf_nibble;
    wire       pf_active;

    antic_pf_serial u_pf (
        .clk(clk), .rst(rst),
        .mode(mode), .pf_valid(pf_valid), .pf_byte(pf_byte),
        .cc_tick(cc_tick), .pf_nibble(pf_nibble), .pf_active(pf_active)
    );

    logic [7:0] colpf0, colpf1, colpf2, colpf3, colbk;
    wire [7:0]  color_out;
    wire        color_valid;
    wire [8:0]  color_cc;

    gtia_stream u_gs (
        .clk(clk), .rst(rst),
        .cc_valid(cc_tick), .cc_index(9'd0),
        .pf_nibble(pf_nibble), .pm_presence(8'h00),
        .prior(8'h01),
        .colpm0(8'h00), .colpm1(8'h00), .colpm2(8'h00), .colpm3(8'h00),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk(colbk), .colpf1_luma_only(1'b0),
        .color_out(color_out), .color_valid(color_valid), .color_cc(color_cc)
    );

    int fail = 0;
    logic [3:0] seen [0:15];
    int         nseen;

    // Stimulus on the negedge — driving at the posedge races the always_ff.
    task automatic feed(input [7:0] b);
        begin
            @(negedge clk); pf_byte = b; pf_valid = 1'b1;
            @(negedge clk); pf_valid = 1'b0;
        end
    endtask

    task automatic tick_cc;
        begin
            @(negedge clk); cc_tick = 1'b1;
            @(negedge clk); cc_tick = 1'b0;
            @(negedge clk);
        end
    endtask

    // pf_nibble is COMBINATIONAL, so the pixel a tick consumes must be sampled
    // WHILE cc_tick is asserted — after the tick the shifter has already
    // advanced and the reading is the next pixel.  That is exactly what
    // gtia_stream sees, so sampling here matches the real consumer.
    task automatic collect(input int n);
        begin
            nseen = 0;
            for (int i = 0; i < n; i++) begin
                @(negedge clk); cc_tick = 1'b1;
                seen[nseen] = pf_nibble; nseen++;
                @(negedge clk); cc_tick = 1'b0;
                @(negedge clk);
            end
        end
    endtask

    initial begin
        mode = 4'hF; pf_valid = 0; pf_byte = 8'h00; cc_tick = 0;
        colpf0 = 8'h10; colpf1 = 8'h20; colpf2 = 8'h30; colpf3 = 8'h40;
        colbk  = 8'h00;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: mode F, $FF -> four colour clocks all lit (PF1) ---------
        feed(8'hFF);
        collect(4);
        for (int i = 0; i < 4; i++)
            if (seen[i] !== 4'b0010) begin
                $display("FAIL T1 mode F all-lit: cc%0d nibble=%b expected 0010", i, seen[i]);
                fail++;
            end

        // ---- T2: mode F, $00 -> background throughout --------------------
        feed(8'h00);
        collect(4);
        for (int i = 0; i < 4; i++)
            if (seen[i] !== 4'b0000) begin
                $display("FAIL T2 mode F blank: cc%0d nibble=%b expected 0000", i, seen[i]);
                fail++;
            end

        // ---- T3: mode F, $80 -> only the FIRST colour clock lit ----------
        // Proves the shift order: MSB first, two pixels per colour clock.
        feed(8'h80);
        collect(4);
        if (seen[0] !== 4'b0010) begin
            $display("FAIL T3 mode F msb: cc0 nibble=%b expected 0010", seen[0]); fail++;
        end
        for (int i = 1; i < 4; i++)
            if (seen[i] !== 4'b0000) begin
                $display("FAIL T3 mode F msb: cc%0d nibble=%b expected 0000", i, seen[i]);
                fail++;
            end

        // ---- T4: mode E (2bpp hires) bit-pair -> PF index ----------------
        // $1B = 00 01 10 11 -> bg, PF0, PF1, PF2
        mode = 4'hE;
        feed(8'h1B);
        collect(4);
        if (seen[0] !== 4'b0000) begin $display("FAIL T4 cc0=%b want bg",   seen[0]); fail++; end
        if (seen[1] !== 4'b0001) begin $display("FAIL T4 cc1=%b want PF0",  seen[1]); fail++; end
        if (seen[2] !== 4'b0010) begin $display("FAIL T4 cc2=%b want PF1",  seen[2]); fail++; end
        if (seen[3] !== 4'b0100) begin $display("FAIL T4 cc3=%b want PF2",  seen[3]); fail++; end

        // ---- T5: the stream runs dry -> background, not stale data -------
        collect(2);
        for (int i = 0; i < 2; i++)
            if (seen[i] !== 4'b0000) begin
                $display("FAIL T5 dry stream: cc%0d nibble=%b expected 0000", i, seen[i]);
                fail++;
            end
        if (pf_active) begin
            $display("FAIL T5b: pf_active still asserted with no byte"); fail++;
        end

        // ---- T6: END TO END — mid-line COLPF change --------------------
        // Same playfield source, colour register rewritten between colour
        // clocks: only pixels from that point on take the new value.  This is
        // what the burst cannot express, and it is the whole reason for the
        // streaming path.
        mode = 4'hF;
        feed(8'hFF);
        tick_cc();
        if (color_out !== 8'h20) begin
            $display("FAIL T6 pre-change colour=$%02h expected $20", color_out); fail++;
        end
        colpf1 = 8'hC7;
        tick_cc();
        if (color_out !== 8'hC7) begin
            $display("FAIL T6 post-change colour=$%02h expected $C7", color_out); fail++;
        end
        colpf1 = 8'h20;

        if (fail == 0) $display("tb_pf_serial: all checks PASS");
        else           $display("tb_pf_serial: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
