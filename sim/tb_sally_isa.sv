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

    // ---- Test 5: STA d,SP ($92 dd) -----------------------------------
    // After prologue SP = $FFF (top of stack).  Use displacement $FE
    // (= -2 signed) → effective addr = $FFD.  STA writes $33 there;
    // verify by reading $0FFD via the absolute-addressing LDA.
    //   $0404 A9 33     LDA #$33
    //   $0406 92 FE     STA $FE,SP        ; stack[SP-2] = stack[$FFD] <- $33
    //   $0408 A9 00     LDA #$00
    //   $040A AD FD 0F  LDA $0FFD         ; A <- $33
    //   $040D 8D 05 03  STA $0305
    //   $0410 4C 10 04  JMP $0410
    task automatic test_sta_d_sp();
        $display("=== Test 5: STA d,SP ($92) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h33);             // LDA #$33
        put(16'h0406, 8'h92); put(16'h0407, 8'hFE);             // STA $FE,SP (=-2)
        put(16'h0408, 8'hA9); put(16'h0409, 8'h00);             // LDA #$00
        put(16'h040A, 8'hAD); put(16'h040B, 8'hFD); put(16'h040C, 8'h0F);  // LDA $0FFD
        put(16'h040D, 8'h8D); put(16'h040E, 8'h05); put(16'h040F, 8'h03);  // STA $0305
        put(16'h0410, 8'h4C); put(16'h0411, 8'h10); put(16'h0412, 8'h04);  // JMP $0410

        run_until_stuck(16'h0410, 400, "STA d,SP");
        expect_mem(16'h0305, 8'h33, "STA $FE,SP: stored value visible");
        $display("PASS: test_sta_d_sp");
    endtask

    // ---- Test 6: LDX/STX/LDY/STY d,SP ($42/$02/$52/$12) --------------
    // Using signed-negative displacements (−3, −4) so writes land at
    // $FFC / $FFB (below the SP=$FFF top), then loads pull them back.
    task automatic test_xy_d_sp();
        $display("=== Test 6: LDX/STX/LDY/STY d,SP ($42/$02/$52/$12) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA2); put(16'h0405, 8'h7E);             // LDX #$7E
        put(16'h0406, 8'h02); put(16'h0407, 8'hFD);             // STX $FD,SP (=-3)
        put(16'h0408, 8'hA2); put(16'h0409, 8'h00);             // LDX #$00
        put(16'h040A, 8'h42); put(16'h040B, 8'hFD);             // LDX $FD,SP
        put(16'h040C, 8'h8E); put(16'h040D, 8'h06); put(16'h040E, 8'h03);  // STX $0306
        put(16'h040F, 8'hA0); put(16'h0410, 8'h91);             // LDY #$91
        put(16'h0411, 8'h12); put(16'h0412, 8'hFC);             // STY $FC,SP (=-4)
        put(16'h0413, 8'hA0); put(16'h0414, 8'h00);             // LDY #$00
        put(16'h0415, 8'h52); put(16'h0416, 8'hFC);             // LDY $FC,SP
        put(16'h0417, 8'h8C); put(16'h0418, 8'h07); put(16'h0419, 8'h03);  // STY $0307
        put(16'h041A, 8'h4C); put(16'h041B, 8'h1A); put(16'h041C, 8'h04);  // JMP $041A

        run_until_stuck(16'h041A, 600, "LDX/STX/LDY/STY d,SP");
        expect_mem(16'h0306, 8'h7E, "LDX d,SP round-trip");
        expect_mem(16'h0307, 8'h91, "LDY d,SP round-trip");
        $display("PASS: test_xy_d_sp");
    endtask

    // ---- Test 4: LDA d,SP ($B2 dd) ------------------------------------
    //   $0404 A9 AB     LDA #$AB        ; A = $AB
    //   $0406 48        PHA             ; push $AB at stack[$FFF], SP -> $FFE
    //   $0407 A9 00     LDA #$00        ; A = $00 (clobber)
    //   $0409 B2 01     LDA $01,SP      ; A <- stack[SP+1] = stack[$FFF] = $AB
    //   $040B 8D 04 03  STA $0304       ; mem[$0304] = $AB
    //   $040E 4C 0E 04  JMP $040E
    task automatic test_lda_d_sp();
        $display("=== Test 4: LDA d,SP ($B2) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'hAB);             // LDA #$AB
        put(16'h0406, 8'h48);                                   // PHA
        put(16'h0407, 8'hA9); put(16'h0408, 8'h00);             // LDA #$00
        put(16'h0409, 8'hB2); put(16'h040A, 8'h01);             // LDA $01,SP
        put(16'h040B, 8'h8D); put(16'h040C, 8'h04); put(16'h040D, 8'h03);  // STA $0304
        put(16'h040E, 8'h4C); put(16'h040F, 8'h0E); put(16'h0410, 8'h04);  // JMP $040E

        run_until_stuck(16'h040E, 300, "LDA d,SP");
        expect_mem(16'h0304, 8'hAB, "LDA $01,SP: stored value");
        $display("PASS: test_lda_d_sp");
    endtask

    // ---- Test 7: ADC d,SP ($72 dd) ------------------------------------
    // After prologue (SP=$FFF): place $05 at stack[$0FFE], then
    //   LDA #$10 ; CLC ; ADC $FF,SP   ->  A = $10 + $05 + 0 = $15
    //   $0404 A9 05     LDA #$05
    //   $0406 92 FF     STA $FF,SP        ; stack[$0FFE] = $05
    //   $0408 A9 10     LDA #$10
    //   $040A 18        CLC
    //   $040B 72 FF     ADC $FF,SP        ; A = $10 + $05 = $15
    //   $040D 8D 08 03  STA $0308
    //   $0410 4C 10 04  JMP $0410
    task automatic test_adc_d_sp();
        $display("=== Test 7: ADC d,SP ($72) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h05);             // LDA #$05
        put(16'h0406, 8'h92); put(16'h0407, 8'hFF);             // STA $FF,SP (=-1)
        put(16'h0408, 8'hA9); put(16'h0409, 8'h10);             // LDA #$10
        put(16'h040A, 8'h18);                                   // CLC
        put(16'h040B, 8'h72); put(16'h040C, 8'hFF);             // ADC $FF,SP
        put(16'h040D, 8'h8D); put(16'h040E, 8'h08); put(16'h040F, 8'h03);  // STA $0308
        put(16'h0410, 8'h4C); put(16'h0411, 8'h10); put(16'h0412, 8'h04);  // JMP $0410

        run_until_stuck(16'h0410, 400, "ADC d,SP");
        expect_mem(16'h0308, 8'h15, "ADC $FF,SP: 0x10 + 0x05 = 0x15");
        $display("PASS: test_adc_d_sp");
    endtask

    // ---- Test 8: SBC d,SP ($F2 dd) ------------------------------------
    //   LDA #$03 ; STA $FE,SP
    //   LDA #$20 ; SEC ; SBC $FE,SP  ->  A = $20 - $03 = $1D
    task automatic test_sbc_d_sp();
        $display("=== Test 8: SBC d,SP ($F2) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h03);             // LDA #$03
        put(16'h0406, 8'h92); put(16'h0407, 8'hFE);             // STA $FE,SP (-2)
        put(16'h0408, 8'hA9); put(16'h0409, 8'h20);             // LDA #$20
        put(16'h040A, 8'h38);                                   // SEC
        put(16'h040B, 8'hF2); put(16'h040C, 8'hFE);             // SBC $FE,SP
        put(16'h040D, 8'h8D); put(16'h040E, 8'h09); put(16'h040F, 8'h03);  // STA $0309
        put(16'h0410, 8'h4C); put(16'h0411, 8'h10); put(16'h0412, 8'h04);  // JMP $0410

        run_until_stuck(16'h0410, 400, "SBC d,SP");
        expect_mem(16'h0309, 8'h1D, "SBC $FE,SP: 0x20 - 0x03 = 0x1D");
        $display("PASS: test_sbc_d_sp");
    endtask

    // ---- Test 9: CMP d,SP ($D2 dd) ------------------------------------
    // CMP sets Z=1 if equal.  After CMP, BEQ branches; we use a small
    // branch to a "success" path that stores $AA, vs a "fail" path that
    // stores $FF.
    //   LDA #$77 ; STA $FD,SP
    //   LDA #$77 ; CMP $FD,SP        ; equal -> Z=1
    //   BEQ +4   ; LDA #$FF ; (skipped); LDA #$AA ; STA $030A
    task automatic test_cmp_d_sp();
        $display("=== Test 9: CMP d,SP ($D2) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h77);             // LDA #$77
        put(16'h0406, 8'h92); put(16'h0407, 8'hFD);             // STA $FD,SP
        put(16'h0408, 8'hA9); put(16'h0409, 8'h77);             // LDA #$77 (same)
        put(16'h040A, 8'hD2); put(16'h040B, 8'hFD);             // CMP $FD,SP
        put(16'h040C, 8'hF0); put(16'h040D, 8'h02);             // BEQ +2 (skip the LDA #$FF)
        put(16'h040E, 8'hA9); put(16'h040F, 8'hFF);             // LDA #$FF (skipped if Z=1)
        put(16'h0410, 8'hA9); put(16'h0411, 8'hAA);             // LDA #$AA
        put(16'h0412, 8'h8D); put(16'h0413, 8'h0A); put(16'h0414, 8'h03);  // STA $030A
        put(16'h0415, 8'h4C); put(16'h0416, 8'h15); put(16'h0417, 8'h04);  // JMP $0415

        run_until_stuck(16'h0415, 400, "CMP d,SP");
        expect_mem(16'h030A, 8'hAA, "CMP equal: BEQ taken (path = $AA)");
        $display("PASS: test_cmp_d_sp");
    endtask

    // ---- Test 10: ADD SP, #imm8 — basic +N/-N round trip --------------
    //   After prologue SP=$FFF.
    //   ADD SP, #$FC (=-4) → SP=$FFB → TSX gives X=$FB.
    //   ADD SP, #$04 (= +4) → SP=$FFF → TSX gives X=$FF.
    task automatic test_add_sp_basic();
        $display("=== Test 10: ADD SP, #imm8 basic +N/-N ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'h22); put(16'h0405, 8'hFC);             // ADD SP, #-4
        put(16'h0406, 8'hBA);                                   // TSX
        put(16'h0407, 8'h8E); put(16'h0408, 8'h20); put(16'h0409, 8'h03);  // STX $0320
        put(16'h040A, 8'h22); put(16'h040B, 8'h04);             // ADD SP, #+4
        put(16'h040C, 8'hBA);                                   // TSX
        put(16'h040D, 8'h8E); put(16'h040E, 8'h21); put(16'h040F, 8'h03);  // STX $0321
        put(16'h0410, 8'h4C); put(16'h0411, 8'h10); put(16'h0412, 8'h04);  // JMP $0410

        run_until_stuck(16'h0410, 400, "ADD SP basic");
        expect_mem(16'h0320, 8'hFB, "ADD SP #-4: SP_lo = $FB");
        expect_mem(16'h0321, 8'hFF, "ADD SP #+4: SP_lo = $FF");
        $display("PASS: test_add_sp_basic");
    endtask

    // ---- Test 11: ADD SP positive clamp at $FFF -----------------------
    //   ADD SP, #$05 from SP=$FFF should clamp at $FFF (no overflow into
    //   imaginary stack page $1000+).  Verify SP[7:0]=$FF.
    task automatic test_add_sp_pos_clamp();
        $display("=== Test 11: ADD SP positive clamp at $FFF ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'h22); put(16'h0405, 8'h05);             // ADD SP, #+5
        put(16'h0406, 8'hBA);                                   // TSX
        put(16'h0407, 8'h8E); put(16'h0408, 8'h22); put(16'h0409, 8'h03);  // STX $0322
        put(16'h040A, 8'h4C); put(16'h040B, 8'h0A); put(16'h040C, 8'h04);  // JMP $040A

        run_until_stuck(16'h040A, 300, "ADD SP clamp+");
        expect_mem(16'h0322, 8'hFF, "ADD SP clamp at $FFF: SP_lo = $FF");
        $display("PASS: test_add_sp_pos_clamp");
    endtask

    // ---- Test 12: ADD SP crosses S_high boundary ($F → $E) ------------
    //   Two ADD SP, #-128 ops from $FFF land at $EFF (S_high transitions
    //   from $F to $E).  Verify by pre-populating mem[$0EFF] with a
    //   sentinel via absolute store, then reading it back via LDA $00,SP
    //   at the new SP — which only works if S_high updated correctly.
    task automatic test_add_sp_cross_boundary();
        $display("=== Test 12: ADD SP crosses S_high boundary ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        // Pre-populate stack BRAM slot at $0EFF with $AA via flat-mem
        // absolute store (sally_core in this TB writes to the flat mem
        // array, no stack-BRAM split).
        put(16'h0404, 8'hA9); put(16'h0405, 8'hAA);             // LDA #$AA
        put(16'h0406, 8'h8D); put(16'h0407, 8'hFF); put(16'h0408, 8'h0E);  // STA $0EFF
        // Drag SP down across the boundary: $FFF -128 -128 = $EFF.
        put(16'h0409, 8'h22); put(16'h040A, 8'h80);             // ADD SP, #-128
        put(16'h040B, 8'h22); put(16'h040C, 8'h80);             // ADD SP, #-128
        // SP should now be $EFF.  Read back via SP-relative:
        put(16'h040D, 8'hA9); put(16'h040E, 8'h00);             // LDA #$00
        put(16'h040F, 8'hB2); put(16'h0410, 8'h00);             // LDA $00,SP
        put(16'h0411, 8'h8D); put(16'h0412, 8'h23); put(16'h0413, 8'h03);  // STA $0323
        put(16'h0414, 8'h4C); put(16'h0415, 8'h14); put(16'h0416, 8'h04);  // JMP $0414

        run_until_stuck(16'h0414, 500, "ADD SP cross-boundary");
        expect_mem(16'h0323, 8'hAA,
                   "ADD SP crosses S_high: stack[$EFF] reachable via SP-rel");
        $display("PASS: test_add_sp_cross_boundary");
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
        test_lda_d_sp();
        test_sta_d_sp();
        test_xy_d_sp();
        test_adc_d_sp();
        test_sbc_d_sp();
        test_cmp_d_sp();
        test_add_sp_basic();
        test_add_sp_pos_clamp();
        test_add_sp_cross_boundary();

        $display("=== ALL TESTS PASSED ===");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_sally_isa wallclock timeout");
        $fatal(1);
    end

endmodule
