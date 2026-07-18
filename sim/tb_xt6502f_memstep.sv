// tb_xt6502f_memstep.sv — validate the SoC mem-step contract for the fidelity core.
// sally_mem gates its read LATCH (bram_dout_q) AND every write/strobe on `rdy` (a per-CPU-step
// pulse). The fid core holds a stable address for the whole window and samples at SUB_DATA, so
// fpga_xt_top steps sally_mem with a single EARLY-window pulse when the fid core owns the bus.
// This models exactly that (rdy-gated read latch + rdy-gated write + a per-address write
// counter) and checks: reads latch in time, and each store commits EXACTLY once (not N times).
//   iverilog -g2012 -o /tmp/ms.vvp -s tb_xt6502f_memstep sim/tb_xt6502f_memstep.sv hdl/xt6502f/xt6502f.sv
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_memstep;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 16 * PHI2_HZ;   // N = 16
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;

    reg [4:0] tc = 0;
    always @(posedge clk) tc <= (tc == N-1) ? 5'd0 : tc + 5'd1;
    wire phi2_tick = (tc == N-1);

    wire [15:0] addr; wire [7:0] data_out; wire rw; wire sync;
    reg  [7:0]  data_in;
    wire [7:0]  dbg_sub;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;

    // the fid core advances every window (BRAM = no stall), rdy=1
    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(1'b1), .irq_n(1'b1), .nmi_n(1'b1), .sync(sync),
        .dbg_pc(), .dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p(),
        .dbg_sub(dbg_sub), .dbg_ir(),
        .dbg_load(1'b0), .dbg_pc_in(16'd0), .dbg_a_in(8'd0), .dbg_x_in(8'd0),
        .dbg_y_in(8'd0), .dbg_s_in(8'd0), .dbg_p_in(8'd0),
        .dbg_cyc_addr(cyc_addr), .dbg_cyc_val(cyc_val), .dbg_cyc_rw(cyc_rw), .dbg_cyc_valid(cyc_valid)
    );

    // ---- sally_mem-style model: read LATCH + write both gated by mem_rdy (the early pulse) ----
    wire mem_rdy = (dbg_sub == 8'd2);           // fpga_xt_top: fid_mem_step = (fid_sub == 2)
    reg [7:0] mem [0:65535];
    reg [7:0] bram_dout_q;                       // the rdy-gated read register (mirrors sally_mem)
    always @(*) data_in = bram_dout_q;
    reg [15:0] wcount [0:65535];                 // writes committed per address (must be 1 per store)
    always @(posedge clk) begin
        if (mem_rdy) begin
            bram_dout_q <= mem[addr];            // read latch on the step
            if (!rw) begin mem[addr] <= data_out; wcount[addr] <= wcount[addr] + 16'd1; end
        end
    end

    integer i, nfail = 0;
    initial begin
        for (i=0;i<65536;i=i+1) begin mem[i]=8'hEA; wcount[i]=0; end
        // $0300: LDA #$5A / STA $1234 / LDA $1234 / STA $5678 / JMP $0300
        mem[16'h0300]=8'hA9; mem[16'h0301]=8'h5A;
        mem[16'h0302]=8'h8D; mem[16'h0303]=8'h34; mem[16'h0304]=8'h12;
        mem[16'h0305]=8'hAD; mem[16'h0306]=8'h34; mem[16'h0307]=8'h12;
        mem[16'h0308]=8'h8D; mem[16'h0309]=8'h78; mem[16'h030A]=8'h56;
        mem[16'h030B]=8'h4C; mem[16'h030C]=8'h00; mem[16'h030D]=8'h03;
        mem[16'hFFFC]=8'h00; mem[16'hFFFD]=8'h03;
        bram_dout_q = 8'hEA;

        rst=1; repeat(6) @(negedge clk); rst=0; @(negedge clk);
        repeat (2 * 20 * N) @(posedge clk);       // ~2 loop iterations

        // T1: the store landed (rdy-gated write works with the early pulse)
        if (mem[16'h1234] !== 8'h5A) begin $display("FAIL T1: mem[$1234]=$%02h want $5A", mem[16'h1234]); nfail++; end
        else $display("  ok  T1: STA $1234 wrote $5A through the early-pulse step");
        // T2: the read-back worked (rdy-gated read latched before SUB_DATA)
        if (mem[16'h5678] !== 8'h5A) begin $display("FAIL T2: mem[$5678]=$%02h want $5A (read-back failed)", mem[16'h5678]); nfail++; end
        else $display("  ok  T2: LDA $1234 read $5A back (read latched before the data slot)");
        // T3: each store committed EXACTLY once per iteration (~2 iters), NOT N times
        if (wcount[16'h1234] < 1 || wcount[16'h1234] > 3) begin
            $display("FAIL T3: $1234 written %0d times (want ~1/iter, not N) — multi-commit", wcount[16'h1234]); nfail++;
        end else $display("  ok  T3: $1234 committed %0d times (once per store, no N-fold write)", wcount[16'h1234]);

        if (nfail==0) $display("*** XT6502F_MEMSTEP OK ***");
        else          $display("*** XT6502F_MEMSTEP FAIL *** %0d failure(s)", nfail);
        $finish;
    end
    initial begin #6000000; $display("*** XT6502F_MEMSTEP TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
