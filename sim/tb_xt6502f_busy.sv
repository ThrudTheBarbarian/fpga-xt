// tb_xt6502f_busy.sv — validate the fidelity core's stall contract against a sally_mem-style
// `busy` (banked/DDR cache-miss). The core has a FIXED sub-schedule (latch @SUB_DATA=N-7,
// commit @SUB_COMMIT=N-3); a slow read must not let it commit stale data. The integration
// gates the core's rdy with a "memory was ready at the data slot" latch (`mem_ok`, sampled at
// SUB_DATA) — this tb replicates exactly what fpga_xt_top will do, and proves reads that clear
// busy before / straddling / after the data slot all return the correct value.
//   iverilog -g2012 -o /tmp/busy.vvp -s tb_xt6502f_busy sim/tb_xt6502f_busy.sv hdl/xt6502f/xt6502f.sv
//   vvp /tmp/busy.vvp +M=11
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_busy;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 16 * PHI2_HZ;    // N = 16: SUB_DATA=9, SUB_COMMIT=13
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;
    localparam int unsigned SUB_DATA = N - 7;

    reg [4:0] tc = 0;
    always @(posedge clk) tc <= (tc == N-1) ? 5'd0 : tc + 5'd1;
    wire phi2_tick = (tc == N-1);

    wire [15:0] addr; wire [7:0] data_out; wire rw; wire sync;
    reg  [7:0]  data_in;
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, dbg_sub, dbg_ir;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;

    // ---- rdy = base gate AND "memory was ready at the data slot" (the integration rule) ----
    reg mem_ok;
    wire mem_busy;                         // 1 = slow access in flight
    always @(posedge clk) if (dbg_sub == SUB_DATA[7:0]) mem_ok <= ~mem_busy;
    wire rdy = mem_ok;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(rdy), .irq_n(1'b1), .nmi_n(1'b1), .sync(sync),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub), .dbg_ir(dbg_ir),
        .dbg_load(1'b0), .dbg_pc_in(16'd0), .dbg_a_in(8'd0), .dbg_x_in(8'd0),
        .dbg_y_in(8'd0), .dbg_s_in(8'd0), .dbg_p_in(8'd0),
        .dbg_cyc_addr(cyc_addr), .dbg_cyc_val(cyc_val), .dbg_cyc_rw(cyc_rw), .dbg_cyc_valid(cyc_valid)
    );

    // ---- memory: normal RAM combinational; the $D5xx region is SLOW ----
    // A read to $D5xx returns $5A only after the (stable) address has been held M clocks;
    // until then busy=1 and the bus shows garbage ($FF). Models a banked/DDR cache-miss.
    integer M;
    reg [7:0] mem [0:65535];
    wire is_slow = (addr[15:8] == 8'hD5);
    reg [15:0] hold;
    always @(posedge clk) begin
        if (is_slow) hold <= (hold > 16'd250) ? hold : hold + 16'd1;
        else         hold <= 16'd0;
    end
    assign mem_busy = is_slow && (hold < M[15:0]);
    always @(*) data_in = is_slow ? (mem_busy ? 8'hFF : 8'h5A) : mem[addr];
    always @(posedge clk) if (cyc_valid && !cyc_rw) mem[cyc_addr] <= cyc_val;

    integer i, nfail = 0;
    initial begin
        if (!$value$plusargs("M=%d", M)) M = 11;
        for (i=0;i<65536;i=i+1) mem[i]=8'hEA;
        mem[16'h0300]=8'hAD; mem[16'h0301]=8'h00; mem[16'h0302]=8'hD5;  // LDA $D500 (slow -> $5A)
        mem[16'h0303]=8'h85; mem[16'h0304]=8'h10;                       // STA $10
        mem[16'h0305]=8'hA9; mem[16'h0306]=8'h99;                       // LDA #$99 (clobber A)
        mem[16'h0307]=8'h4C; mem[16'h0308]=8'h00; mem[16'h0309]=8'h03;  // JMP $0300
        mem[16'hFFFC]=8'h00; mem[16'hFFFD]=8'h03;
        mem[16'h0010]=8'h00;

        mem_ok = 1'b1; hold = 0;
        rst=1; repeat(6) @(negedge clk); rst=0; @(negedge clk);

        // run plenty of machine cycles (slow reads eat several windows)
        repeat (40 * N) @(posedge clk);

        // the STA must have written the SLOW-read value, not garbage
        if (mem[16'h0010] !== 8'h5A) begin
            $display("FAIL (M=%0d): mem[$10]=$%02h, want $5A — stale-data commit on busy read", M, mem[16'h0010]);
            nfail = nfail + 1;
        end else
            $display("  ok  (M=%0d): slow $D500 read returned $5A through the stall (mem[$10]=$5A)", M);

        if (nfail==0) $display("*** XT6502F_BUSY OK (M=%0d) ***", M);
        else          $display("*** XT6502F_BUSY FAIL (M=%0d) ***", M);
        $finish;
    end

    initial begin #6000000; $display("*** XT6502F_BUSY TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
