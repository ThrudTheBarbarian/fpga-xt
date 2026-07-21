// tb_xt6502f_clisei.sv — directed check of the delayed CLI/SEI/PLP interrupt-enable
// behaviour for the fidelity 6502 (the NMOS quirk Altirra's Acid800 cpu_clisei tests):
//   * CLI clears I but a pending IRQ is only recognised AFTER the following instruction.
//   * CLI immediately followed by SEI still lets the IRQ through (after the SEI) — the
//     frame pushed then has I SET.
//   * RTI's I-change is NOT delayed: an IRQ pending across an RTI-that-clears-I is taken
//     BEFORE the next instruction, and the pushed frame has I CLEAR.
// Mirrors sim/tb_xt6502f_irq.sv's harness. IRQ is a level held low; the ISR ($0500) is a
// self-loop so we can sample X (and the stacked P) at the exact interrupt boundary.
//   iverilog -g2012 -o /tmp/clisei.vvp -s tb_xt6502f_clisei sim/tb_xt6502f_clisei.sv hdl/xt6502f/xt6502f.sv
`timescale 1ns/1ps
`default_nettype none

module tb_xt6502f_clisei;
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
    wire [15:0] dbg_pc; wire [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, dbg_sub, dbg_ir;
    wire [15:0] cyc_addr; wire [7:0] cyc_val; wire cyc_rw, cyc_valid;

    reg        dbg_load = 0; reg [15:0] dbg_pc_in;
    reg  [7:0] dbg_a_in, dbg_x_in, dbg_y_in, dbg_s_in, dbg_p_in;

    xt6502f #(.CLK_SALLY_HZ(CLK_HZ), .PHI2_HZ(PHI2_HZ)) dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(1'b1), .irq_n(irq_n), .nmi_n(nmi_n),
        .sync(sync), .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_sub(dbg_sub), .dbg_ir(dbg_ir),
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

    task seed(input [15:0] pc, input [7:0] s, input [7:0] p, input [7:0] x); begin
        @(negedge clk); dbg_pc_in = pc; dbg_s_in = s; dbg_p_in = p;
        dbg_a_in = 8'h5A; dbg_x_in = x; dbg_y_in = 8'h00; dbg_load = 1'b1;
        @(negedge clk); dbg_load = 1'b0;
    end endtask

    // run until PC reaches the ISR ($0500); returns X captured at that boundary
    task wait_isr(output ok, output [7:0] xat); integer g; begin
        ok = 0; xat = 8'hxx;
        for (g = 0; g < 60; g = g + 1) begin
            run_mc(1);
            if (dbg_pc === 16'h0500) begin ok = 1; xat = dbg_x; g = 60; end
        end
    end endtask

    integer i; reg okr; reg [7:0] xat; reg [7:0] pushp;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'hEA;
        // ISR at $0500 = self-loop (JMP $0500); we sample at entry
        mem[16'h0500] = 8'h4C; mem[16'h0501] = 8'h00; mem[16'h0502] = 8'h05;
        mem[16'hFFFE] = 8'h00; mem[16'hFFFF] = 8'h05;   // IRQ/BRK vector -> $0500
        mem[16'hFFFA] = 8'h00; mem[16'hFFFB] = 8'h06;   // NMI (unused)

        // ---- scenario 1: CLI, then a pending IRQ must let ONE instruction run ----
        mem[16'h0300]=8'hA2; mem[16'h0301]=8'h00;   // LDX #$00
        mem[16'h0302]=8'h58;                        // CLI
        mem[16'h0303]=8'hE8;                        // INX  (must execute -> X=1)
        mem[16'h0304]=8'hE8;                        // INX
        mem[16'h0305]=8'hE8;                        // INX
        mem[16'h0306]=8'h78;                        // SEI
        mem[16'h0307]=8'h4C; mem[16'h0308]=8'h07; mem[16'h0309]=8'h03; // JMP self

        // ---- scenario 2: CLI immediately followed by SEI ----
        mem[16'h0320]=8'hA2; mem[16'h0321]=8'h00;   // LDX #$00
        mem[16'h0322]=8'h58;                        // CLI
        mem[16'h0323]=8'h78;                        // SEI
        mem[16'h0324]=8'hE8;                        // INX (must NOT execute before IRQ)
        mem[16'h0325]=8'hE8;                        // INX
        mem[16'h0326]=8'h4C; mem[16'h0327]=8'h26; mem[16'h0328]=8'h03; // JMP self

        // ---- scenario 3: RTI (clears I) then SEI; IRQ fires BETWEEN them ----
        mem[16'h0400]=8'h40;                        // RTI (pulls P=$20 -> I=0, ret $0401)
        mem[16'h0401]=8'h78;                        // SEI  (next:)  must NOT execute before IRQ
        mem[16'h0402]=8'hE8;                        // INX
        mem[16'h0403]=8'hE8;                        // INX
        mem[16'h0404]=8'h4C; mem[16'h0405]=8'h04; mem[16'h0406]=8'h04; // JMP self

        rst = 1; repeat (4) @(negedge clk); rst = 0; @(negedge clk);

        // ======================= T1: CLI delayed by one instruction ==================
        irq_n = 1'b0;                               // IRQ armed (level low)
        seed(16'h0300, 8'hFF, 8'h24, 8'h00);        // I set, X=0
        wait_isr(okr, xat);
        if (!okr) begin $display("FAIL T1: IRQ never taken after CLI (pc=$%04h)", dbg_pc); nfail=nfail+1; end
        else if (xat !== 8'h01)
            begin $display("FAIL T1: executed %0d insn after CLI (X=$%02h), want exactly 1 ($01)", xat, xat); nfail=nfail+1; end
        else $display("  ok  T1: CLI delayed one instruction (X=$01 at IRQ)");

        // ======================= T2: CLI/SEI pair — IRQ after SEI, I set on stack ======
        seed(16'h0320, 8'hFF, 8'h24, 8'h00);
        wait_isr(okr, xat);
        if (!okr) begin $display("FAIL T2: IRQ never taken across CLI/SEI (pc=$%04h)", dbg_pc); nfail=nfail+1; end
        else begin
            pushp = mem[16'h01FD];                  // frame: P at $01FD (S seeded $FF)
            if (xat !== 8'h00)
                begin $display("FAIL T2: X=$%02h at IRQ, want $00 (INX must not run before IRQ)", xat); nfail=nfail+1; end
            else if (!pushp[2])
                begin $display("FAIL T2: pushed P=$%02h has I clear — CLI/SEI/IRQ must push I set", pushp); nfail=nfail+1; end
            else $display("  ok  T2: CLI/SEI pair interrupts with I SET on stack (P=$%02h, X=$00)", pushp);
        end

        // ======================= T3: RTI is NOT delayed — IRQ between RTI/SEI ==========
        mem[16'h01FD]=8'h20; mem[16'h01FE]=8'h01; mem[16'h01FF]=8'h04;  // stacked P=$20, ret=$0401
        seed(16'h0400, 8'hFC, 8'h24, 8'h00);        // I set, S=$FC (RTI pops 3 -> S=$FF)
        wait_isr(okr, xat);
        if (!okr) begin $display("FAIL T3: IRQ never taken across RTI/SEI (pc=$%04h)", dbg_pc); nfail=nfail+1; end
        else begin
            pushp = mem[16'h01FD];                  // after RTI S=$FF, IRQ pushes P at $01FD
            if (xat !== 8'h00)
                begin $display("FAIL T3: X=$%02h at IRQ, want $00 (RTI immediate: fire before SEI)", xat); nfail=nfail+1; end
            else if (pushp[2])
                begin $display("FAIL T3: pushed P=$%02h has I set — RTI/SEI must push I CLEAR", pushp); nfail=nfail+1; end
            else $display("  ok  T3: RTI immediate — IRQ between RTI/SEI, I CLEAR on stack (P=$%02h)", pushp);
        end
        irq_n = 1'b1;

        if (nfail == 0) $display("*** XT6502F_CLISEI OK ***");
        else            $display("*** XT6502F_CLISEI FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #5000000; $display("*** XT6502F_CLISEI TIMEOUT ***"); $finish; end
endmodule

`default_nettype wire
