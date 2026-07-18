// tb_cpu_handoff.sv — resident dual-core bus-mux + hand-off (docs/Design/dual-cpu-resident-
// mux.md). Two xt6502f cores share one memory; cpu_handoff hands the bus between them at an
// instruction boundary via snapshot->inject. Proves: the idle core is frozen (drives nothing),
// a switch re-anchors the target at the exact snapshot PC, and a running memory counter
// continues contiguously across two switches — i.e. the swap is invisible to software.
//   iverilog -g2012 -o /tmp/ho.vvp -s tb_cpu_handoff sim/tb_cpu_handoff.sv \
//       hdl/xt6502f/xt6502f.sv hdl/xt6502f/cpu_handoff.sv
`timescale 1ns/1ps
`default_nettype none

module tb_cpu_handoff;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 8 * PHI2_HZ;
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;
    reg [3:0] tc = 0;
    always @(posedge clk) tc <= (tc == N-1) ? 4'd0 : tc + 4'd1;
    wire phi2_tick = (tc == N-1);

    // ---- two cores ----
    wire [15:0] a_addr, b_addr; wire [7:0] a_do, b_do; wire a_rw, b_rw, a_sync, b_sync;
    wire [15:0] a_pc, b_pc; wire [7:0] a_a,a_x,a_y,a_s,a_p, b_a,b_x,b_y,b_s,b_p, a_sub,b_sub,a_ir,b_ir;
    wire [15:0] a_ca, b_ca; wire [7:0] a_cv, b_cv; wire a_crw,b_crw,a_cvld,b_cvld;
    reg  [7:0]  data_in;

    // ---- handoff ----
    wire owner, a_run, b_run, a_load, b_load, switching;
    wire [15:0] load_pc; wire [7:0] load_a, load_x, load_y, load_s, load_p;
    reg  switch_req = 0;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) A (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(a_addr), .data_in(data_in), .data_out(a_do), .rw(a_rw),
        .rdy(a_run), .irq_n(1'b1), .nmi_n(1'b1), .sync(a_sync),
        .dbg_pc(a_pc), .dbg_a(a_a), .dbg_x(a_x), .dbg_y(a_y), .dbg_s(a_s), .dbg_p(a_p),
        .dbg_sub(a_sub), .dbg_ir(a_ir),
        .dbg_load(a_load), .dbg_pc_in(load_pc), .dbg_a_in(load_a), .dbg_x_in(load_x),
        .dbg_y_in(load_y), .dbg_s_in(load_s), .dbg_p_in(load_p),
        .dbg_cyc_addr(a_ca), .dbg_cyc_val(a_cv), .dbg_cyc_rw(a_crw), .dbg_cyc_valid(a_cvld)
    );
    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) B (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(b_addr), .data_in(data_in), .data_out(b_do), .rw(b_rw),
        .rdy(b_run), .irq_n(1'b1), .nmi_n(1'b1), .sync(b_sync),
        .dbg_pc(b_pc), .dbg_a(b_a), .dbg_x(b_x), .dbg_y(b_y), .dbg_s(b_s), .dbg_p(b_p),
        .dbg_sub(b_sub), .dbg_ir(b_ir),
        .dbg_load(b_load), .dbg_pc_in(load_pc), .dbg_a_in(load_a), .dbg_x_in(load_x),
        .dbg_y_in(load_y), .dbg_s_in(load_s), .dbg_p_in(load_p),
        .dbg_cyc_addr(b_ca), .dbg_cyc_val(b_cv), .dbg_cyc_rw(b_crw), .dbg_cyc_valid(b_cvld)
    );

    cpu_handoff ho (
        .clk(clk), .rst(rst), .switch_req(switch_req),
        .a_boundary(a_sync), .a_pc(a_pc), .a_a(a_a), .a_x(a_x), .a_y(a_y), .a_s(a_s), .a_p(a_p),
        .b_boundary(b_sync), .b_pc(b_pc), .b_a(b_a), .b_x(b_x), .b_y(b_y), .b_s(b_s), .b_p(b_p),
        .owner(owner), .a_run(a_run), .b_run(b_run), .a_load(a_load), .b_load(b_load),
        .load_pc(load_pc), .load_a(load_a), .load_x(load_x), .load_y(load_y), .load_s(load_s),
        .load_p(load_p), .switching(switching)
    );

    // ---- shared memory: bus muxed by owner; active core's committed writes land ----
    reg [7:0] mem [0:65535];
    wire [15:0] mem_addr = owner ? b_addr : a_addr;
    always @(*) data_in = mem[mem_addr];
    wire        act_cvld = owner ? b_cvld : a_cvld;
    wire        act_crw  = owner ? b_crw  : a_crw;
    wire [15:0] act_ca   = owner ? b_ca   : a_ca;
    wire [7:0]  act_cv   = owner ? b_cv   : a_cv;
    always @(posedge clk) if (act_cvld && !act_crw) mem[act_ca] <= act_cv;

    integer nfail = 0;
    task mc(input integer n); integer j; begin for (j=0;j<n*N;j=j+1) @(posedge clk); end endtask
    task do_switch(output ok); integer g; begin
        @(negedge clk) switch_req = 1; @(negedge clk) switch_req = 0;
        ok = 0; for (g=0; g<8; g=g+1) begin mc(1); if (!switching) begin ok=1; g=8; end end
    end endtask

    integer i; reg okr; integer v0, v1, v2; reg [15:0] apc_frozen, bpc_frozen; reg [15:0] snap_pc;
    initial begin
        for (i=0;i<65536;i=i+1) mem[i]=8'hEA;
        // $0300: INC $10 / JMP $0300  — a shared counter at $10
        mem[16'h0300]=8'hE6; mem[16'h0301]=8'h10;
        mem[16'h0302]=8'h4C; mem[16'h0303]=8'h00; mem[16'h0304]=8'h03;
        mem[16'h0010]=8'h00;
        mem[16'hFFFC]=8'h00; mem[16'hFFFD]=8'h03;

        rst=1; repeat(4) @(negedge clk); rst=0; @(negedge clk);

        // ===== T1: A owns + runs; B is frozen (never advances, drives no writes) =====
        mc(20);
        v0 = mem[16'h0010];
        bpc_frozen = b_pc;
        mc(10);
        if (owner !== 1'b0) begin $display("FAIL T1: owner=%0d want 0", owner); nfail=nfail+1; end
        if (mem[16'h0010] <= v0) begin $display("FAIL T1: A not counting ($10=%0d, was %0d)", mem[16'h0010], v0); nfail=nfail+1; end
        if (b_pc !== bpc_frozen) begin $display("FAIL T1: idle core B advanced ($%04h->$%04h)", bpc_frozen, b_pc); nfail=nfail+1; end
        if (nfail==0) $display("  ok  T1: A owns + counts ($10=%0d); B frozen at $%04h", mem[16'h0010], b_pc);

        // ===== T2: switch A->B; B re-anchors at the snapshot PC, A freezes =====
        v1 = mem[16'h0010];
        do_switch(okr);
        snap_pc = load_pc;                        // the injected PC
        if (!okr) begin $display("FAIL T2: switch did not complete"); nfail=nfail+1; end
        else if (owner !== 1'b1) begin $display("FAIL T2: owner=%0d want 1", owner); nfail=nfail+1; end
        else if (b_pc !== snap_pc) begin $display("FAIL T2: B resumed at $%04h, snapshot was $%04h", b_pc, snap_pc); nfail=nfail+1; end
        else if (snap_pc !== 16'h0300 && snap_pc !== 16'h0302) begin $display("FAIL T2: snapshot PC $%04h off the loop", snap_pc); nfail=nfail+1; end
        else $display("  ok  T2: A->B at instruction boundary; B resumes at $%04h (snapshot)", snap_pc);
        apc_frozen = a_pc;

        // ===== T3: B counts on; A now frozen; counter contiguous (no reset/skip) =====
        mc(30);
        v2 = mem[16'h0010];
        if (a_pc !== apc_frozen) begin $display("FAIL T3: frozen core A advanced ($%04h->$%04h)", apc_frozen, a_pc); nfail=nfail+1; end
        if (v2 <= v1)          begin $display("FAIL T3: counter did not advance under B ($10=%0d, was %0d)", v2, v1); nfail=nfail+1; end
        if (v2 < v1 || (v2 - v1) > 40) begin $display("FAIL T3: counter jumped ($10 %0d->%0d) — not seamless", v1, v2); nfail=nfail+1; end
        else $display("  ok  T3: B counts on, A frozen, counter contiguous ($10 %0d->%0d)", v1, v2);

        // ===== T4: switch back B->A; A resumes, counter still contiguous =====
        do_switch(okr);
        if (!okr || owner !== 1'b0) begin $display("FAIL T4: switch back failed (owner=%0d)", owner); nfail=nfail+1; end
        else begin
            mc(20);
            if (mem[16'h0010] <= v2) begin $display("FAIL T4: A did not resume counting"); nfail=nfail+1; end
            else $display("  ok  T4: B->A resumes; counter now %0d (was %0d)", mem[16'h0010], v2);
        end

        if (nfail==0) $display("*** CPU_HANDOFF OK ***");
        else          $display("*** CPU_HANDOFF FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #12000000; $display("*** CPU_HANDOFF TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
