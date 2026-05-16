// tb_sally_isa.sv — focused ISA tests for SALLY 6502 embellishments.
//
// Boots sally_core + a flat 64 KB memory model (no sally_mem, no
// banked windows).  Each test pre-loads a small hand-coded 6502
// program at $0400, runs the CPU for a bounded number of cycles, and
// checks expected values at known memory addresses.
//
// Memory model includes the Stage A $0100-$01FF → $0F00-$0FFF alias
// (matching what sally_mem provides in production), so stack ops
// from cpu.v's widened SP land at the same logical location as
// legacy $01xx accesses.

`timescale 1ns / 1ps

module tb_sally_isa;

    logic clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz
    logic rst = 1'b1;

    // ---- Flat 64 KB memory ---------------------------------------------
    logic [7:0] mem [0:65535];

    // ---- sally_core wires ----------------------------------------------
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_dout;
    wire        cpu_rw;
    logic [7:0] cpu_din_q;
    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    sally_core u_cpu (
        .clk      (clk),
        .rst      (rst),
        .addr     (cpu_addr),
        .data_in  (cpu_din_q),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (1'b1),
        .irq_n    (1'b1),
        .nmi_n    (1'b1),
        .stack_op (cpu_stack_op),
        .s_high   (cpu_s_high)
    );

    // Memory port: Stage A alias for $0100-$01FF → $0F00-$0FFF
    wire [15:0] cpu_addr_eff = (cpu_addr[15:8] == 8'h01)
                                ? {8'h0F, cpu_addr[7:0]}
                                : cpu_addr;

    always_ff @(posedge clk) begin
        if (!cpu_rw)
            mem[cpu_addr_eff] <= cpu_dout;
        cpu_din_q <= mem[cpu_addr_eff];
    end

    // ---- Test infrastructure -------------------------------------------

    // Place a single byte at an address.  Tests assemble programs via
    // a sequence of these calls rather than passing arrays around (iverilog
    // doesn't handle queue-passing reliably).
    task automatic put(input [15:0] a, input [7:0] d);
        mem[a] = d;
    endtask

    // Run the CPU until cpu_addr enters a tight JMP * loop at target_pc.
    // The CPU's address bus visits target_pc / target_pc+1 / target_pc+2
    // each iteration (opcode + operand-lo + operand-hi).  We count hits
    // of target_pc itself; 3 hits within max_cycles is conclusive proof
    // we're in the loop and the test program has run to completion.
    task automatic run_until_stuck(input [15:0] target_pc,
                                   input int max_cycles,
                                   input string label);
        int cycles;
        int hits;
        cycles = 0;
        hits   = 0;

        @(negedge clk);
        rst = 1'b0;

        while (cycles < max_cycles) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cpu_addr == target_pc) begin
                hits = hits + 1;
                if (hits >= 3) return;
            end
        end

        $display("FAIL: %s — CPU did not reach JMP $%04h loop in %0d cycles (last_addr=$%04h)",
                 label, target_pc, max_cycles, cpu_addr);
        $fatal(1);
    endtask

    // Reset the CPU between tests.
    task automatic reset_cpu();
        rst = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    task automatic expect_mem(input [15:0] addr_arg, input [7:0] expected,
                              input string label);
        if (mem[addr_arg] !== expected) begin
            $display("FAIL: %s — mem[%04h] = %02h, expected %02h",
                     label, addr_arg, mem[addr_arg], expected);
            $fatal(1);
        end
    endtask

    // Lay down a standard prologue at $0400: CLD + LDX #$FF + TXS so
    // SP is initialized to $FF (and S_high stays $F from reset, giving
    // SP = $FFF).  After this returns, test code starts at $0404.
    task automatic prologue();
        put(16'h0400, 8'hD8);                                 // CLD
        put(16'h0401, 8'hA2); put(16'h0402, 8'hFF);           // LDX #$FF
        put(16'h0403, 8'h9A);                                 // TXS
    endtask

    // ---- Test 1: PUSH X / POP X ($44 / $64) ----------------------------
    task automatic test_push_pop_x();
        $display("=== Test 1: PUSH X / POP X ($44 / $64) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA2); put(16'h0405, 8'h5A);           // LDX #$5A
        put(16'h0406, 8'h44);                                 // PUSH X
        put(16'h0407, 8'hA2); put(16'h0408, 8'h00);           // LDX #$00
        put(16'h0409, 8'h64);                                 // POP X
        put(16'h040A, 8'h8E); put(16'h040B, 8'h00); put(16'h040C, 8'h03); // STX $0300
        put(16'h040D, 8'h4C); put(16'h040E, 8'h0D); put(16'h040F, 8'h04); // JMP $040D

        run_until_stuck(16'h040D, 200, "PUSH/POP X");
        expect_mem(16'h0300, 8'h5A, "PUSH/POP X: stored value");
        $display("PASS: test_push_pop_x");
    endtask

    // ---- Test 2: PUSH Y / POP Y ($54 / $74) ----------------------------
    task automatic test_push_pop_y();
        $display("=== Test 2: PUSH Y / POP Y ($54 / $74) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA0); put(16'h0405, 8'hA5);           // LDY #$A5
        put(16'h0406, 8'h54);                                 // PUSH Y
        put(16'h0407, 8'hA0); put(16'h0408, 8'h00);           // LDY #$00
        put(16'h0409, 8'h74);                                 // POP Y
        put(16'h040A, 8'h8C); put(16'h040B, 8'h01); put(16'h040C, 8'h03); // STY $0301
        put(16'h040D, 8'h4C); put(16'h040E, 8'h0D); put(16'h040F, 8'h04); // JMP $040D

        run_until_stuck(16'h040D, 200, "PUSH/POP Y");
        expect_mem(16'h0301, 8'hA5, "PUSH/POP Y: stored value");
        $display("PASS: test_push_pop_y");
    endtask

    // ---- Test 3: mixed PUSH X then PUSH Y, POP Y then POP X ------------
    task automatic test_push_pop_mixed();
        $display("=== Test 3: mixed PUSH/POP X+Y ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA2); put(16'h0405, 8'h11);           // LDX #$11
        put(16'h0406, 8'hA0); put(16'h0407, 8'h22);           // LDY #$22
        put(16'h0408, 8'h44);                                 // PUSH X
        put(16'h0409, 8'h54);                                 // PUSH Y
        put(16'h040A, 8'hA2); put(16'h040B, 8'h00);           // LDX #$00
        put(16'h040C, 8'hA0); put(16'h040D, 8'h00);           // LDY #$00
        put(16'h040E, 8'h74);                                 // POP Y
        put(16'h040F, 8'h64);                                 // POP X
        put(16'h0410, 8'h8E); put(16'h0411, 8'h02); put(16'h0412, 8'h03); // STX $0302
        put(16'h0413, 8'h8C); put(16'h0414, 8'h03); put(16'h0415, 8'h03); // STY $0303
        put(16'h0416, 8'h4C); put(16'h0417, 8'h16); put(16'h0418, 8'h04); // JMP $0416

        run_until_stuck(16'h0416, 400, "PUSH/POP mixed");
        expect_mem(16'h0302, 8'h11, "mixed: X round-trip");
        expect_mem(16'h0303, 8'h22, "mixed: Y round-trip");
        $display("PASS: test_push_pop_mixed");
    endtask

    // ---- Main scheduler -------------------------------------------------
    initial begin
        $display("=== tb_sally_isa starting ===");

        // Clear memory.
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

        // Stack RAM at $0F00-$0FFF starts as $00 (fine for these tests).

        test_push_pop_x();
        test_push_pop_y();
        test_push_pop_mixed();

        $display("=== ALL TESTS PASSED ===");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_sally_isa wallclock timeout");
        $fatal(1);
    end

endmodule
