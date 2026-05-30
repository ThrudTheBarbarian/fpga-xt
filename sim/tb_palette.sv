// tb_palette.sv — M14 palette LUT + chiplet-ext write path.
//
// Drives $D483/$D484/$D485 (latch R/G/B) followed by $D486 (commit at
// IDX) for every entry 0..255 and verifies the LUT read port returns
// the expected RGB888 value for each.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_palette;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    // ---- antic_regs --------------------------------------------------
    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h0;
    logic [7:0]  wdata = 8'h0;
    wire  [7:0]  rdata;
    wire         wsync_pending;
    wire         nmires_strobe;
    wire         pal_write_strobe;
    wire  [7:0]  pal_r_q, pal_g_q, pal_b_q, pal_idx_q;
    wire  [7:0]  nmien_q;
    wire  [7:0]  dmactl_q, chactl_q, dlistl_q, dlisth_q;
    wire  [7:0]  hscrol_q, vscrol_q, pmbase_q, chbase_q;
    wire         mode_snoop_q;
    wire  [7:0]  clock_mult_q, output_mode_q;

    antic_regs u_antic_regs (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(8'h00), .rdata(rdata),
        .wsync_pending(wsync_pending),
        .nmires_strobe(nmires_strobe),
        .pal_write_strobe(pal_write_strobe),
        .pal_r_q(pal_r_q), .pal_g_q(pal_g_q),
        .pal_b_q(pal_b_q), .pal_idx_q(pal_idx_q),
        .dmactl_q(dmactl_q), .chactl_q(chactl_q),
        .dlistl_q(dlistl_q), .dlisth_q(dlisth_q),
        .hscrol_q(hscrol_q), .vscrol_q(vscrol_q),
        .pmbase_q(pmbase_q), .chbase_q(chbase_q),
        .nmien_q(nmien_q),
        .mode_snoop_q(mode_snoop_q),
        .clock_mult_q(clock_mult_q),
        .output_mode_q(output_mode_q),
        .vcount_in(8'h00),
        .nmist_in(8'h00),
        .serial_clock_mult_in(8'h00)
    );

    // ---- palette_lut -------------------------------------------------
    logic [7:0]  raddr = 8'h0;
    wire  [23:0] rgb;

    palette_lut #(.ADDR_W(8)) u_lut (
        .clk(clk),
        .we(pal_write_strobe),
        .waddr(pal_idx_q),
        .wdata({pal_r_q, pal_g_q, pal_b_q}),
        .raddr(raddr),
        .rdata(rgb)
    );

    task automatic write_reg(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk);
        waddr <= a; wdata <= d; we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        we <= 1'b0;
    endtask

    task automatic write_palette_entry(input logic [7:0] idx,
                                        input logic [7:0] r,
                                        input logic [7:0] g,
                                        input logic [7:0] b);
        // Order is order-independent at the chiplet-ext write level —
        // commit happens on the $D486 (PAL_IDX) write. We write R, G,
        // B first, then IDX which strobes pal_write_strobe.
        write_reg(8'h83, r);
        write_reg(8'h84, g);
        write_reg(8'h85, b);
        write_reg(8'h86, idx);
    endtask

    int fail_count = 0;

    initial begin
        $display("[palette] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Phase 1: write a few representative entries and verify.
        write_palette_entry(8'h00, 8'h11, 8'h22, 8'h33);
        write_palette_entry(8'hAB, 8'hDE, 8'hAD, 8'hBE);
        write_palette_entry(8'hFF, 8'hCA, 8'hFE, 8'hBA);

        @(negedge clk);
        raddr <= 8'h00;
        @(posedge clk);
        @(negedge clk);
        if (rgb !== 24'h112233) begin
            $display("[p1/00] FAIL got $%06h expected $112233", rgb);
            fail_count++;
        end

        @(negedge clk);
        raddr <= 8'hAB;
        @(posedge clk);
        @(negedge clk);
        if (rgb !== 24'hDEADBE) begin
            $display("[p1/AB] FAIL got $%06h expected $DEADBE", rgb);
            fail_count++;
        end

        @(negedge clk);
        raddr <= 8'hFF;
        @(posedge clk);
        @(negedge clk);
        if (rgb !== 24'hCAFEBA) begin
            $display("[p1/FF] FAIL got $%06h expected $CAFEBA", rgb);
            fail_count++;
        end

        // Phase 2: full sweep — every entry gets a unique value, then
        // every entry is read back and compared.
        begin : sweep_write
            integer i;
            for (i = 0; i < 256; i = i + 1) begin
                write_palette_entry(i[7:0],
                                    i[7:0],         // R = i
                                    ~i[7:0],        // G = ~i
                                    {i[3:0], i[7:4]}); // B = nibble-swap
            end
        end

        begin : sweep_read
            integer i;
            logic [23:0] expected;
            for (i = 0; i < 256; i = i + 1) begin
                @(negedge clk);
                raddr <= i[7:0];
                @(posedge clk);
                @(negedge clk);
                expected = {i[7:0], ~i[7:0], {i[3:0], i[7:4]}};
                if (rgb !== expected) begin
                    if (fail_count < 8)
                        $display("[p2/%02h] FAIL got $%06h expected $%06h",
                                 i[7:0], rgb, expected);
                    fail_count++;
                end
            end
        end

        // Phase 3: re-write entry $00 and confirm it overwrites cleanly.
        write_palette_entry(8'h00, 8'hFE, 8'hED, 8'hF0);
        @(negedge clk);
        raddr <= 8'h00;
        @(posedge clk);
        @(negedge clk);
        if (rgb !== 24'hFEEDF0) begin
            $display("[p3/rewrite] FAIL got $%06h expected $FEEDF0", rgb);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** PALETTE OK *** all 256 entries write/read clean + 3 spot + rewrite");
            $finish;
        end else begin
            $display("*** PALETTE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_palette watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
