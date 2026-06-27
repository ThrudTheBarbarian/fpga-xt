// tb_cdc_flag_data.sv — regression for the multi-bit CDC primitive.
//
// Drives a free-running counter in src_clk and pulses src_valid periodically,
// across an incommensurate clock ratio (the condition that tore fetch_row /
// pix_next_vcount when they were free-running 2-FF bus-synced).  Verifies every
// delivered dst_data equals exactly the counter value latched at its src_valid
// edge, in order, with none lost or torn.

`timescale 1ns/1ps
`default_nettype none

module tb_cdc_flag_data;
    localparam int WIDTH = 8;

    logic src_clk = 0, dst_clk = 0;
    always #3.5 src_clk = ~src_clk;   // ~142.9 MHz
    always #6.5 dst_clk = ~dst_clk;   // ~76.9 MHz  (incommensurate ratio)

    logic [WIDTH-1:0] src_data;
    logic             src_valid;
    logic [WIDTH-1:0] dst_data;
    logic             dst_valid;

    cdc_flag_data #(.WIDTH(WIDTH)) dut (
        .src_clk(src_clk), .src_data(src_data), .src_valid(src_valid),
        .dst_clk(dst_clk), .dst_data(dst_data), .dst_valid(dst_valid));

    // free-running source counter — the value that crosses on each pulse
    logic [WIDTH-1:0] cnt = 0;
    always_ff @(posedge src_clk) cnt <= cnt + 1'b1;

    // expected-word FIFO, pushed in src domain, popped in dst domain
    logic [WIDTH-1:0] expq [$];
    logic [WIDTH-1:0] exp;
    int sent = 0, got = 0, errs = 0;

    // pulse src_valid one src cycle every 9 — wide enough spacing for the
    // toggle to be seen by the slower dst clock; src_data = the counter value.
    int phase = 0;
    always_ff @(posedge src_clk) begin
        src_valid <= 1'b0;
        phase <= (phase == 8) ? 0 : phase + 1;
        if (phase == 0 && sent < 200) begin
            src_data  <= cnt;
            src_valid <= 1'b1;
            expq.push_back(cnt);
            sent      <= sent + 1;
        end
    end

    always_ff @(posedge dst_clk) begin
        if (dst_valid) begin
            if (expq.size() == 0) begin
                $display("  ERROR: dst_valid with empty expected queue (data=%0d)", dst_data);
                errs++;
            end else begin
                exp = expq.pop_front();
                if (dst_data !== exp) begin
                    $display("  MISMATCH #%0d: got %0d, expected %0d", got, dst_data, exp);
                    errs++;
                end
                got++;
            end
        end
    end

    initial begin
        src_data = 0; src_valid = 0;
        // run long enough to drain all 200 transfers
        repeat (5000) @(posedge dst_clk);
        $display("cdc_flag_data: sent=%0d got=%0d leftover=%0d errs=%0d",
                 sent, got, expq.size(), errs);
        if (sent == got && expq.size() == 0 && errs == 0)
            $display("PASS: tb_cdc_flag_data — all words delivered in order, untorn");
        else
            $display("FAIL: tb_cdc_flag_data");
        $finish;
    end
endmodule

`default_nettype wire
