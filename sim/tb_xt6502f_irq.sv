// tb_xt6502f_irq.sv — directed interrupt tests for the fidelity 6502 (docs/Design/
// fidelity-6502.md Phase 3). Tom Harte's tests tie IRQ/NMI inactive, so the HW-interrupt
// path (IRQ level, NMI edge, 7-cycle push+vector, B-clear, BRK/NMI hijack) needs a directed
// bench. Uses dbg_load to seed each scenario, then drives irq_n/nmi_n and checks the
// architectural outcome + the stacked frame.
//   iverilog -g2012 -o /tmp/irq.vvp -s tb_xt6502f_irq sim/tb_xt6502f_irq.sv hdl/xt6502f/xt6502f.sv
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_irq;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    localparam int unsigned PHI2_HZ = 1_789_773;
    localparam int unsigned CLK_HZ  = 8 * PHI2_HZ;   // N = 8 (fast sim)
    localparam int unsigned N       = CLK_HZ / PHI2_HZ;

    reg [3:0] tc = 0;
    always @(posedge clk) tc <= (tc == N-1) ? 4'd0 : tc + 4'd1;
    wire phi2_tick = (tc == N-1);

    wire [15:0] addr; wire [7:0] data_out; wire rw; wire sync;
    reg  [7:0]  data_in;
    reg         irq_n = 1'b1, nmi_n = 1'b1;
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, dbg_sub;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;

    reg        dbg_load = 0; reg [15:0] dbg_pc_in;
    reg  [7:0] dbg_a_in, dbg_x_in, dbg_y_in, dbg_s_in, dbg_p_in;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(1'b1), .irq_n(irq_n), .nmi_n(nmi_n),
        .sync(sync), .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub),
        .dbg_load(dbg_load), .dbg_pc_in(dbg_pc_in), .dbg_a_in(dbg_a_in), .dbg_x_in(dbg_x_in),
        .dbg_y_in(dbg_y_in), .dbg_s_in(dbg_s_in), .dbg_p_in(dbg_p_in),
        .dbg_cyc_addr(cyc_addr), .dbg_cyc_val(cyc_val), .dbg_cyc_rw(cyc_rw), .dbg_cyc_valid(cyc_valid)
    );

    reg [7:0] mem [0:65535];
    always @(*) data_in = mem[addr];
    always @(posedge clk) if (cyc_valid && !cyc_rw) mem[cyc_addr] <= cyc_val;

    integer nfail = 0;

    task run_mc(input integer n); integer j; begin
        for (j = 0; j < n*N; j = j + 1) @(posedge clk);
    end endtask

    task seed(input [15:0] pc, input [7:0] s, input [7:0] p); begin
        @(negedge clk); dbg_pc_in = pc; dbg_s_in = s; dbg_p_in = p;
        dbg_a_in = 8'h11; dbg_x_in = 8'h22; dbg_y_in = 8'h33; dbg_load = 1'b1;
        @(negedge clk); dbg_load = 1'b0;
    end endtask

    // wait (bounded) for PC to reach `target`; returns 1 on success
    task wait_pc(input [15:0] target, output ok); integer g; begin
        ok = 0;
        for (g = 0; g < 40; g = g + 1) begin run_mc(1); if (dbg_pc === target) begin ok = 1; g = 40; end end
    end endtask

    integer i; reg okr; reg [15:0] retpc; reg [7:0] pushp;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;      // fill with NOP
        // program loop at $0400: NOPs then JMP $0400
        mem[16'h0410] = 8'h4C; mem[16'h0411] = 8'h00; mem[16'h0412] = 8'h04;
        mem[16'h0500] = 8'h40;                                 // IRQ ISR: RTI
        mem[16'h0600] = 8'h40;                                 // NMI ISR: RTI
        mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h04;          // RESET -> $0400
        mem[16'hFFFE] = 8'h00; mem[16'hFFFF] = 8'h05;          // IRQ/BRK -> $0500
        mem[16'hFFFA] = 8'h00; mem[16'hFFFB] = 8'h06;          // NMI     -> $0600

        rst = 1; repeat (4) @(negedge clk); rst = 0; @(negedge clk);

        // ============ T1: IRQ (I clear) diverts, pushes B=0 frame, sets I, RTI returns ======
        seed(16'h0400, 8'hFF, 8'h20);            // I clear
        run_mc(3);                               // a few NOPs
        irq_n = 1'b0;                            // assert IRQ
        wait_pc(16'h0500, okr);
        if (!okr) begin $display("FAIL T1: IRQ did not vector to $0500 (pc=$%04h)", dbg_pc); nfail=nfail+1; end
        else begin
            retpc = {mem[16'h01FF], mem[16'h01FE]};    // stacked PCH:PCL
            pushp = mem[16'h01FD];                     // stacked P
            if (dbg_s !== 8'hFC) begin $display("FAIL T1: S=$%02h want $FC", dbg_s); nfail=nfail+1; end
            if (!dbg_p[2])       begin $display("FAIL T1: I not set after IRQ (P=$%02h)", dbg_p); nfail=nfail+1; end
            if (pushp[4])        begin $display("FAIL T1: pushed P has B set ($%02h) — IRQ must clear B", pushp); nfail=nfail+1; end
            if (!pushp[5])       begin $display("FAIL T1: pushed P bit5 not set ($%02h)", pushp); nfail=nfail+1; end
            if (retpc[15:8] !== 8'h04) begin $display("FAIL T1: return PC $%04h not in $04xx", retpc); nfail=nfail+1; end
            irq_n = 1'b1;                              // release before RTI so it doesn't re-fire
            wait_pc(retpc, okr);                       // RTI should return here
            if (!okr) begin $display("FAIL T1: RTI did not return to $%04h (pc=$%04h)", retpc, dbg_pc); nfail=nfail+1; end
            else if (dbg_p[2]) begin $display("FAIL T1: I still set after RTI (P=$%02h) — should restore clear", dbg_p); nfail=nfail+1; end
            else $display("  ok  T1: IRQ vectors $0500, B-clear frame, I set, RTI -> $%04h", retpc);
        end

        // ============ T2: IRQ masked when I=1 ==============================================
        seed(16'h0400, 8'hFF, 8'h24);            // I set
        irq_n = 1'b0;
        wait_pc(16'h0500, okr);
        if (okr) begin $display("FAIL T2: IRQ fired while I=1"); nfail=nfail+1; end
        else $display("  ok  T2: IRQ correctly masked while I=1");
        irq_n = 1'b1;

        // ============ T3: NMI (edge) fires even with I=1, vector $0600, B=0 ================
        seed(16'h0400, 8'hFF, 8'h24);            // I set (must not mask NMI)
        run_mc(2);
        nmi_n = 1'b0;                            // falling edge
        wait_pc(16'h0600, okr);
        if (!okr) begin $display("FAIL T3: NMI did not vector to $0600 (pc=$%04h)", dbg_pc); nfail=nfail+1; end
        else begin
            pushp = mem[16'h01FD];
            if (pushp[4]) begin $display("FAIL T3: pushed P has B set ($%02h)", pushp); nfail=nfail+1; end
            $display("  ok  T3: NMI vectors $0600 despite I=1, B-clear frame");
        end
        nmi_n = 1'b1;                            // release (edge consumed)

        // ============ T4: NMI edge is one-shot (level stays low, must not re-fire) =========
        seed(16'h0400, 8'hFF, 8'h20);
        // nmi_n already high; assert once, service, then confirm no second fire while held low
        run_mc(2); nmi_n = 1'b0; wait_pc(16'h0600, okr);
        if (!okr) begin $display("FAIL T4: NMI didn't fire"); nfail=nfail+1; end
        else begin
            // still holding nmi_n low: RTI back, run a while — must NOT re-enter $0600
            run_mc(10);
            seed(16'h0400, 8'hFF, 8'h20);        // reseed to a clean loop; nmi still low (no new edge)
            run_mc(8);
            if (dbg_pc[15:8] === 8'h06) begin $display("FAIL T4: NMI re-fired with no new edge (level-triggered bug)"); nfail=nfail+1; end
            else $display("  ok  T4: NMI is edge-triggered (no re-fire while held low)");
        end
        nmi_n = 1'b1;

        if (nfail == 0) $display("*** XT6502F_IRQ OK ***");
        else            $display("*** XT6502F_IRQ FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #5000000; $display("*** XT6502F_IRQ TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
