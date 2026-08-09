// tb_xt6502f_dbg.sv — the fidelity 6502 debug facility (docs/Design/fidelity-6502.md §6).
// Wires xt6502f + xt6502f_debug and proves the debug slot contract: coherent settled
// snapshots, break-before-execute PC breakpoint, single-instruction step, data watchpoint,
// and the per-cycle trace ring. cpu_halt gates the core's rdy (same rdy-gate as turbo).
//   iverilog -g2012 -o /tmp/dbg.vvp -s tb_xt6502f_dbg sim/tb_xt6502f_dbg.sv \
//       hdl/xt6502f/xt6502f.sv hdl/xt6502f/xt6502f_debug.sv
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_dbg;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 8 * PHI2_HZ;
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;

    reg [3:0] tc = 0;
    always @(posedge clk) tc <= (tc == N-1) ? 4'd0 : tc + 4'd1;
    wire phi2_tick = (tc == N-1);

    wire [15:0] addr; wire [7:0] data_out; wire rw; wire sync;
    reg  [7:0]  data_in;
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, dbg_sub, dbg_ir;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;
    wire cpu_halt;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) cpu (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(~cpu_halt), .irq_n(1'b1), .nmi_n(1'b1),
        .sync(sync), .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub), .dbg_ir(dbg_ir),
        .dbg_load(1'b0), .dbg_pc_in(16'd0), .dbg_a_in(8'd0), .dbg_x_in(8'd0),
        .dbg_y_in(8'd0), .dbg_s_in(8'd0), .dbg_p_in(8'd0),
        .dbg_cyc_addr(cyc_addr), .dbg_cyc_val(cyc_val), .dbg_cyc_rw(cyc_rw), .dbg_cyc_valid(cyc_valid)
    );

    reg        halt_req=0, resume=0, step=0, bkpt_en=0, wp_en=0;
    reg [15:0] bkpt_addr=0, wp_addr=0;
    reg  [1:0] wp_mode=0;
    wire [15:0] entry_pc, settled_pc, trace_pc, trace_addr;
    wire  [7:0] entry_a, entry_x, entry_y, entry_s, entry_p;
    wire  [7:0] settled_a, settled_x, settled_y, settled_s, settled_p, trace_ir, trace_val;
    wire        halted, hit_bkpt, hit_wp, trace_rw;
    reg  [3:0]  trace_idx=0; wire [4:0] trace_count;

    xt6502f_debug #(.N(N), .TRACE_DEPTH(16)) dbg (
        .clk(clk), .rst(rst),
        .sub(dbg_sub), .sync(sync), .pc(dbg_pc), .a(dbg_a), .x(dbg_x), .y(dbg_y), .s(dbg_s), .p(dbg_p),
        .ir_in(dbg_ir), .cyc_addr(cyc_addr), .cyc_val(cyc_val), .cyc_rw(cyc_rw), .cyc_valid(cyc_valid),
        .halt_req(halt_req), .resume(resume), .step(step),
        .bkpt_en(bkpt_en), .bkpt_addr(bkpt_addr), .wp_en(wp_en), .wp_addr(wp_addr), .wp_mode(wp_mode),
        .entry_pc(entry_pc), .entry_a(entry_a), .entry_x(entry_x), .entry_y(entry_y), .entry_s(entry_s), .entry_p(entry_p),
        .settled_pc(settled_pc), .settled_a(settled_a), .settled_x(settled_x), .settled_y(settled_y), .settled_s(settled_s), .settled_p(settled_p),
        .cpu_halt(cpu_halt), .halted(halted), .hit_bkpt(hit_bkpt), .hit_wp(hit_wp),
        .trace_idx(trace_idx), .trace_pc(trace_pc), .trace_ir(trace_ir), .trace_addr(trace_addr),
        .trace_val(trace_val), .trace_rw(trace_rw), .trace_count(trace_count)
    );

    reg [7:0] mem [0:65535];
    always @(*) data_in = mem[addr];
    always @(posedge clk) if (cyc_valid && !cyc_rw) mem[cyc_addr] <= cyc_val;

    integer nfail = 0;
    task mc(input integer n); integer j; begin for (j=0;j<n*N;j=j+1) @(posedge clk); end endtask
    task pulse_resume; begin @(negedge clk) resume=1; @(negedge clk) resume=0; end endtask
    task pulse_step;   begin @(negedge clk) step=1;   @(negedge clk) step=0;   end endtask
    // run (bounded) until halted; ok=1 on success
    task wait_halt(output ok); integer g; begin ok=0;
        for (g=0; g<60; g=g+1) begin mc(1); if (halted) begin ok=1; g=60; end end
    end endtask

    integer i; reg okr;
    initial begin
        for (i=0;i<65536;i=i+1) mem[i]=8'hEA;
        // $0400: LDA #$42 / INX / STA $2000 / NOP / JMP $0400
        mem[16'h0400]=8'hA9; mem[16'h0401]=8'h42;
        mem[16'h0402]=8'hE8;
        mem[16'h0403]=8'h8D; mem[16'h0404]=8'h00; mem[16'h0405]=8'h20;
        mem[16'h0406]=8'hEA;
        mem[16'h0407]=8'h4C; mem[16'h0408]=8'h00; mem[16'h0409]=8'h04;
        mem[16'hFFFC]=8'h00; mem[16'hFFFD]=8'h04;

        rst=1; repeat(4) @(negedge clk); rst=0; @(negedge clk);

        // ===== T1: breakpoint break-BEFORE-execute + coherent settled snapshot =====
        bkpt_en=1; bkpt_addr=16'h0403;           // break at the STA
        wait_halt(okr);
        if (!okr) begin $display("FAIL T1: never hit breakpoint"); nfail=nfail+1; end
        else begin
            if (settled_pc !== 16'h0403) begin $display("FAIL T1: settled_pc=$%04h want $0403", settled_pc); nfail=nfail+1; end
            if (settled_a  !== 8'h42)   begin $display("FAIL T1: A=$%02h want $42 (LDA must have run)", settled_a); nfail=nfail+1; end
            // INX ran once (X started 0 at reset): X must be 1, and STA has NOT run yet
            if (settled_x  !== 8'h01)   begin $display("FAIL T1: X=$%02h want $01 (INX ran, once)", settled_x); nfail=nfail+1; end
            if (mem[16'h2000] === 8'h42) begin $display("FAIL T1: STA already wrote $2000 — broke too late"); nfail=nfail+1; end
            if (!hit_bkpt) begin $display("FAIL T1: hit_bkpt not set"); nfail=nfail+1; end
            if (nfail==0) $display("  ok  T1: break-before-execute @ $0403; settled A=$42 X=$01, STA not yet run");
        end

        // ===== T2: single step executes exactly the STA, halts at next fetch ($0406) =====
        bkpt_en=0;                                // disable bkpt so step controls it
        pulse_step;
        wait_halt(okr);
        if (!okr) begin $display("FAIL T2: step did not re-halt"); nfail=nfail+1; end
        else begin
            if (settled_pc !== 16'h0406) begin $display("FAIL T2: after step settled_pc=$%04h want $0406", settled_pc); nfail=nfail+1; end
            if (mem[16'h2000] !== 8'h42) begin $display("FAIL T2: STA did not write $2000 during step (got $%02h)", mem[16'h2000]); nfail=nfail+1; end
            else $display("  ok  T2: step ran exactly STA (mem[$2000]=$42), halted at $0406");
        end

        // ===== T3: data watchpoint on a write to $2000 =====
        mem[16'h2000]=8'h00;                      // clear so we can see the next write
        wp_en=1; wp_addr=16'h2000; wp_mode=2'b10; // break on write
        pulse_resume;
        wait_halt(okr);
        if (!okr) begin $display("FAIL T3: watchpoint never fired"); nfail=nfail+1; end
        else if (!hit_wp) begin $display("FAIL T3: halted but hit_wp not set"); nfail=nfail+1; end
        else if (mem[16'h2000] !== 8'h42) begin $display("FAIL T3: wp fired but $2000=$%02h", mem[16'h2000]); nfail=nfail+1; end
        else $display("  ok  T3: watchpoint halted on write to $2000 (hit_wp, mem=$42)");
        wp_en=0;

        // ===== T4: trace ring captured the STA write =====
        begin : chktrace
            integer k; reg found;
            found=0;
            for (k=0;k<16;k=k+1) begin
                @(negedge clk) trace_idx=k[3:0]; @(posedge clk); #1;
                if (trace_addr===16'h2000 && trace_val===8'h42 && trace_rw===1'b0) found=1;
            end
            if (trace_count < 5)     begin $display("FAIL T4: trace_count=%0d too small", trace_count); nfail=nfail+1; end
            if (!found)              begin $display("FAIL T4: STA write ($2000<=$42) not in trace ring"); nfail=nfail+1; end
            else $display("  ok  T4: trace ring holds the STA write (count=%0d)", trace_count);
        end

        // ===== T5: coherent EARLY vs SETTLED across a commit (resume, free-run a bit) =====
        // (snapshots are just consistent latches; sanity-check they track a live PC)
        pulse_resume; mc(20);
        if (settled_pc[15:8] !== 8'h04 && settled_pc[15:8] !== 8'h20) begin
            $display("FAIL T5: settled_pc=$%04h not tracking the program", settled_pc); nfail=nfail+1;
        end else $display("  ok  T5: snapshots track live execution (settled_pc=$%04h)", settled_pc);

        if (nfail==0) $display("*** XT6502F_DBG OK ***");
        else          $display("*** XT6502F_DBG FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #8000000; $display("*** XT6502F_DBG TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
