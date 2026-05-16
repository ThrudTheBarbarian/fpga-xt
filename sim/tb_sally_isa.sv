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

    // ---- Test 13: PSH #0 — bulk save 6 registers (N=0, no locals) ----
    //   After prologue SP=$FFF.  Load A=$AA, X=$BB, Y=$CC.  PSH #0
    //   should subtract 6 from SP, then write:
    //     stack[SP+0] = P, stack[SP+1] = SP_lo_old ($FF),
    //     stack[SP+2] = SP_hi_old ($0F), stack[SP+3] = Y ($CC),
    //     stack[SP+4] = X ($BB), stack[SP+5] = A ($AA).
    //   New SP = $FF9, so the slots land at mem[$0FF9..$0FFE].
    //   Verify SP_lo via TSX -> STX, plus each saved byte.
    task automatic test_psh_save_slots();
        $display("=== Test 13: PSH #0 — slot layout ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'hAA);             // LDA #$AA
        put(16'h0406, 8'hA2); put(16'h0407, 8'hBB);             // LDX #$BB
        put(16'h0408, 8'hA0); put(16'h0409, 8'hCC);             // LDY #$CC
        put(16'h040A, 8'h32); put(16'h040B, 8'h00);             // PSH #0
        put(16'h040C, 8'hBA);                                   // TSX (X <- SP_lo)
        put(16'h040D, 8'h8E); put(16'h040E, 8'h30); put(16'h040F, 8'h03);  // STX $0330
        put(16'h0410, 8'h4C); put(16'h0411, 8'h10); put(16'h0412, 8'h04);  // JMP $0410

        run_until_stuck(16'h0410, 600, "PSH #0 save");

        // SP_lo after PSH = $FFF - 6 = $FF9 -> low byte $F9.
        expect_mem(16'h0330, 8'hF9, "PSH #0: TSX returns $F9");
        // Slot writes in stack BRAM (flat-mem alias is $0F00-$0FFF; the
        // post-PSH slots $0FF9..$0FFE are above the alias window so
        // they appear directly at those addresses in the flat memory).
        expect_mem(16'h0FFA, 8'hFF, "PSH #0: slot1 = SP_lo_entry");
        expect_mem(16'h0FFB, 8'h0F, "PSH #0: slot2 = SP_hi_entry");
        expect_mem(16'h0FFC, 8'hCC, "PSH #0: slot3 = Y");
        expect_mem(16'h0FFD, 8'hBB, "PSH #0: slot4 = X");
        expect_mem(16'h0FFE, 8'hAA, "PSH #0: slot5 = A");
        // P slot ($0FF9) — D was just cleared by prologue's CLD, N was
        // set by LDY #$CC (which has bit 7 set), so we expect bit 7=1.
        // The full byte is {N,V,1,1,D,I,Z,C}; assert specifically that
        // bit 7 is set rather than checking the whole byte.
        if (mem[16'h0FF9][7] !== 1'b1) begin
            $display("FAIL: PSH #0: slot0 P[N] expected 1, got mem[$0FF9]=%02h",
                     mem[16'h0FF9]);
            $fatal(1);
        end
        $display("PASS: test_psh_save_slots");
    endtask

    // ---- Test 14: PSH #0 / PLL #0 round trip --------------------------
    //   Save A/X/Y/P with PSH, clobber, restore with PLL, verify all
    //   registers came back.
    task automatic test_psh_pll_roundtrip();
        $display("=== Test 14: PSH #0 / PLL #0 round trip ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h55);             // LDA #$55
        put(16'h0406, 8'hA2); put(16'h0407, 8'h66);             // LDX #$66
        put(16'h0408, 8'hA0); put(16'h0409, 8'h77);             // LDY #$77
        put(16'h040A, 8'h32); put(16'h040B, 8'h00);             // PSH #0
        // Clobber all three.
        put(16'h040C, 8'hA9); put(16'h040D, 8'h00);             // LDA #$00
        put(16'h040E, 8'hA2); put(16'h040F, 8'h00);             // LDX #$00
        put(16'h0410, 8'hA0); put(16'h0411, 8'h00);             // LDY #$00
        // Restore.
        put(16'h0412, 8'h62); put(16'h0413, 8'h00);             // PLL #0
        // Stash to test addresses.
        put(16'h0414, 8'h8D); put(16'h0415, 8'h31); put(16'h0416, 8'h03);  // STA $0331
        put(16'h0417, 8'h8E); put(16'h0418, 8'h32); put(16'h0419, 8'h03);  // STX $0332
        put(16'h041A, 8'h8C); put(16'h041B, 8'h33); put(16'h041C, 8'h03);  // STY $0333
        put(16'h041D, 8'hBA);                                   // TSX
        put(16'h041E, 8'h8E); put(16'h041F, 8'h34); put(16'h0420, 8'h03);  // STX $0334
        put(16'h0421, 8'h4C); put(16'h0422, 8'h21); put(16'h0423, 8'h04);  // JMP $0421

        run_until_stuck(16'h0421, 1200, "PSH/PLL round trip");

        expect_mem(16'h0331, 8'h55, "PSH/PLL: A restored");
        expect_mem(16'h0332, 8'h66, "PSH/PLL: X restored");
        expect_mem(16'h0333, 8'h77, "PSH/PLL: Y restored");
        expect_mem(16'h0334, 8'hFF, "PSH/PLL: SP_lo restored to $FF");
        $display("PASS: test_psh_pll_roundtrip");
    endtask

    // ---- Test 15: PSH/PLL #4 with locals ------------------------------
    //   Allocate 4 bytes of locals.  After PSH #4 SP = $FFF - 10 = $FF5.
    //   Touch a local via SP-relative ops to confirm the frame layout.
    //   Then PLL #4 restores everything.
    task automatic test_psh_pll_locals();
        $display("=== Test 15: PSH #4 with locals ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h99);             // LDA #$99
        put(16'h0406, 8'h32); put(16'h0407, 8'h04);             // PSH #4
        // Inside frame: SP=$FF5.  Local[0] lives at SP+6 = $FFB
        // ($0FF5 + 6 = $0FFB).  Store $5A there via SP-relative.
        put(16'h0408, 8'hA9); put(16'h0409, 8'h5A);             // LDA #$5A
        put(16'h040A, 8'h92); put(16'h040B, 8'h06);             // STA $06,SP
        // Confirm round trip from same SP:
        put(16'h040C, 8'hA9); put(16'h040D, 8'h00);             // LDA #$00
        put(16'h040E, 8'hB2); put(16'h040F, 8'h06);             // LDA $06,SP
        put(16'h0410, 8'h8D); put(16'h0411, 8'h35); put(16'h0412, 8'h03);  // STA $0335
        // Restore.
        put(16'h0413, 8'h62); put(16'h0414, 8'h04);             // PLL #4
        // SP should be back at $FFF, A should be $99 (the value we
        // loaded before PSH; PSH saved it and PLL restored it).
        put(16'h0415, 8'h8D); put(16'h0416, 8'h36); put(16'h0417, 8'h03);  // STA $0336
        put(16'h0418, 8'hBA);                                   // TSX
        put(16'h0419, 8'h8E); put(16'h041A, 8'h37); put(16'h041B, 8'h03);  // STX $0337
        put(16'h041C, 8'h4C); put(16'h041D, 8'h1C); put(16'h041E, 8'h04);  // JMP $041C

        run_until_stuck(16'h041C, 1400, "PSH/PLL with locals");

        expect_mem(16'h0335, 8'h5A, "PSH #4: local slot SP-relative round trip");
        expect_mem(16'h0336, 8'h99, "PSH/PLL #4: A restored to $99");
        expect_mem(16'h0337, 8'hFF, "PSH/PLL #4: SP back to $FF");
        $display("PASS: test_psh_pll_locals");
    endtask

    // ---- Test 16: PSH/PLL preserves P flags ----------------------------
    //   Set C=1 (SEC) and N=1 (LDA #$FF set N), PSH, clear C and N,
    //   PLL, branch on the restored flag to confirm.
    task automatic test_psh_pll_flags();
        $display("=== Test 16: PSH/PLL preserves P flags ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'h38);                                   // SEC      (C=1)
        put(16'h0405, 8'hA9); put(16'h0406, 8'hFF);             // LDA #$FF (N=1)
        put(16'h0407, 8'h32); put(16'h0408, 8'h00);             // PSH #0
        put(16'h0409, 8'h18);                                   // CLC      (C=0)
        put(16'h040A, 8'hA9); put(16'h040B, 8'h01);             // LDA #$01 (N=0)
        put(16'h040C, 8'h62); put(16'h040D, 8'h00);             // PLL #0   restore flags
        // Branch on C=1 (should be taken; restored).  Offset +5 skips
        // the not-taken LDA + JMP (5 bytes total) landing on $0415.
        put(16'h040E, 8'hB0); put(16'h040F, 8'h05);             // BCS +5
        // not-taken path: store $00 and halt
        put(16'h0410, 8'hA9); put(16'h0411, 8'h00);             // LDA #$00
        put(16'h0412, 8'h4C); put(16'h0413, 8'h1A); put(16'h0414, 8'h04);  // JMP $041A
        // taken path: branch lands here
        put(16'h0415, 8'hA9); put(16'h0416, 8'hAA);             // LDA #$AA
        put(16'h0417, 8'h4C); put(16'h0418, 8'h1A); put(16'h0419, 8'h04);  // JMP $041A
        // merge — store result
        put(16'h041A, 8'h8D); put(16'h041B, 8'h38); put(16'h041C, 8'h03);  // STA $0338
        put(16'h041D, 8'h4C); put(16'h041E, 8'h1D); put(16'h041F, 8'h04);  // JMP $041D

        run_until_stuck(16'h041D, 1200, "PSH/PLL flags");
        expect_mem(16'h0338, 8'hAA, "PSH/PLL: C flag restored, BCS taken");
        $display("PASS: test_psh_pll_flags");
    endtask

    // ---- Test 17: 65C02 BRA ($80) — unconditional forward branch -----
    //   Both paths converge at $040E STA $0340 / $0411 JMP-stuck, but
    //   carry different A values.  Take-branch leaves A=$AA via the
    //   LDA at $040B; fall-through (broken) leaves A=$11 from the
    //   pre-BRA load.
    task automatic test_bra_forward();
        $display("=== Test 17: BRA forward ($80) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h11);             // LDA #$11 (fail sentinel)
        put(16'h0406, 8'h80); put(16'h0407, 8'h03);             // BRA +3 → $040B
        put(16'h0408, 8'h4C); put(16'h0409, 8'h0E); put(16'h040A, 8'h04);  // JMP $040E (fall-through)
        put(16'h040B, 8'hA9); put(16'h040C, 8'hAA);             // LDA #$AA (BRA target)
        put(16'h040D, 8'hEA);                                   // NOP padding
        put(16'h040E, 8'h8D); put(16'h040F, 8'h40); put(16'h0410, 8'h03);  // STA $0340
        put(16'h0411, 8'h4C); put(16'h0412, 8'h11); put(16'h0413, 8'h04);  // JMP $0411 (stuck)

        run_until_stuck(16'h0411, 400, "BRA forward");
        expect_mem(16'h0340, 8'hAA, "BRA forward: branch taken, mem[$0340]=$AA");
        $display("PASS: test_bra_forward");
    endtask

    // ---- Test 18: 65C02 BRA ($80) — backward branch with counter -----
    //   Loop body INX / CPX / BEQ / BRA -7 four times until X==4, then
    //   BEQ-escapes to a success store.  Exercises backward offset path.
    task automatic test_bra_backward();
        $display("=== Test 18: BRA backward ($80) ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA2); put(16'h0405, 8'h00);             // LDX #$00
        put(16'h0406, 8'h4C); put(16'h0407, 8'h0A); put(16'h0408, 8'h04);  // JMP $040A
        put(16'h040A, 8'hE8);                                   // INX
        put(16'h040B, 8'hE0); put(16'h040C, 8'h04);             // CPX #$04
        put(16'h040D, 8'hF0); put(16'h040E, 8'h09);             // BEQ +9 → $0418
        put(16'h040F, 8'h80); put(16'h0410, 8'hF9);             // BRA -7 → $040A
        // Fall-through path (BRA broken): land at $0411
        put(16'h0411, 8'hA2); put(16'h0412, 8'hFF);             // LDX #$FF (fail sentinel)
        put(16'h0413, 8'h8E); put(16'h0414, 8'h41); put(16'h0415, 8'h03);  // STX $0341
        put(16'h0416, 8'h4C); put(16'h0417, 8'h16); put(16'h0418, 8'h04);  // JMP $0416 (fail-stuck)
        // BEQ-escape target — success path
        put(16'h0418, 8'h8E); put(16'h0419, 8'h41); put(16'h041A, 8'h03);  // STX $0341 = $04
        put(16'h041B, 8'h4C); put(16'h041C, 8'h1B); put(16'h041D, 8'h04);  // JMP $041B (success)

        run_until_stuck(16'h041B, 800, "BRA backward");
        expect_mem(16'h0341, 8'h04, "BRA backward: looped 4 times, X=$04");
        $display("PASS: test_bra_backward");
    endtask

    // ---- Test 19: 65C02 BIT #imm ($89) — Z flag from A AND imm -------
    //   LDA #$0F; BIT #$F0 → A & imm = $00 → Z=1.  BEQ taken proves Z=1.
    //   Also verify A is NOT modified ($0F stays $0F).
    task automatic test_bit_imm_z();
        $display("=== Test 19: BIT #imm Z flag ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA9); put(16'h0405, 8'h0F);             // LDA #$0F
        put(16'h0406, 8'h89); put(16'h0407, 8'hF0);             // BIT #$F0 → A&F0=0, Z=1
        put(16'h0408, 8'hF0); put(16'h0409, 8'h05);             // BEQ +5 → $040F
        put(16'h040A, 8'h4C); put(16'h040B, 8'h12); put(16'h040C, 8'h04);  // JMP $0412 (fail)
        put(16'h040D, 8'hEA);                                   // NOP padding
        put(16'h040E, 8'hEA);                                   // NOP padding
        put(16'h040F, 8'h8D); put(16'h0410, 8'h42); put(16'h0411, 8'h03);  // STA $0342 (A=$0F)
        put(16'h0412, 8'h4C); put(16'h0413, 8'h12); put(16'h0414, 8'h04);  // JMP $0412 (stuck for both paths)

        run_until_stuck(16'h0412, 500, "BIT #imm Z=1");
        // Both paths reach $0412 — success: A=$0F preserved at $0342.
        // Fail (Z=0 → BEQ not taken, falls to JMP $0412): mem[$0342]
        //   never written, stays $00.
        expect_mem(16'h0342, 8'h0F,
                   "BIT #imm: Z=1 → BEQ taken, A=$0F preserved");
        $display("PASS: test_bit_imm_z");
    endtask

    // ---- Test 20: 65C02 BIT #imm ($89) — N and V flags from imm ------
    //   BIT #imm copies imm[7]→N, imm[6]→V (per the BIT semantics).
    //   X starts at 0 (fail default); each branch-skip-fail chains the
    //   next test.  Reaching the LDX #$03 means both N and V landed.
    //   Fail-path JMPs go to a distinct stuck at $041F so test_stuck
    //   target $0419 only fires on the success path.
    task automatic test_bit_imm_nv();
        $display("=== Test 20: BIT #imm N/V flags ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        put(16'h0404, 8'hA2); put(16'h0405, 8'h00);             // LDX #$00 (fail default)
        put(16'h0406, 8'hA9); put(16'h0407, 8'h01);             // LDA #$01
        put(16'h0408, 8'h89); put(16'h0409, 8'hC1);             // BIT #$C1 (N=1,V=1,Z=0)
        put(16'h040A, 8'h30); put(16'h040B, 8'h03);             // BMI +3 → $040F
        put(16'h040C, 8'h4C); put(16'h040D, 8'h1F); put(16'h040E, 8'h04);  // JMP $041F (fail N)
        put(16'h040F, 8'h70); put(16'h0410, 8'h03);             // BVS +3 → $0414
        put(16'h0411, 8'h4C); put(16'h0412, 8'h1F); put(16'h0413, 8'h04);  // JMP $041F (fail V)
        put(16'h0414, 8'hA2); put(16'h0415, 8'h03);             // LDX #$03 (success)
        put(16'h0416, 8'h8E); put(16'h0417, 8'h43); put(16'h0418, 8'h03);  // STX $0343
        put(16'h0419, 8'h4C); put(16'h041A, 8'h19); put(16'h041B, 8'h04);  // JMP $0419 (success stuck)
        put(16'h041F, 8'h4C); put(16'h0420, 8'h1F); put(16'h0421, 8'h04);  // JMP $041F (fail stuck)

        run_until_stuck(16'h0419, 600, "BIT #imm N+V");
        expect_mem(16'h0343, 8'h03, "BIT #imm: N=1 and V=1, both branches taken");
        $display("PASS: test_bit_imm_nv");
    endtask

    // ---- Test 21: end-to-end calling convention ----------------------
    //   cdecl-style call: caller pushes two args right-to-left, JSRs;
    //   callee uses PSH #0 + SP-relative addressing to read params,
    //   computes the result, overwrites the saved-A slot with the
    //   return value (so PLL restores A as the return), then RTS.
    //   Caller stores the return, then ADD SP, #+2 cleans up params.
    //
    //   Verifies: JSR / RTS through 12-bit SP, PSH allocates frame,
    //   SP-rel LDA/ADC read params at +9/+10, STA $05,SP overwrites
    //   saved-A, PLL restores from updated slot, ADD SP cleans the
    //   caller-pushed params.  All of Stage A/B/C in one program.
    task automatic test_calling_convention();
        $display("=== Test 21: calling convention end-to-end ===");
        reset_cpu();

        mem[16'hFFFC] = 8'h00;
        mem[16'hFFFD] = 8'h04;
        prologue();

        // Caller: push b=$14 then a=$22, JSR add_two, STA result, ADD SP #+2
        put(16'h0404, 8'hA9); put(16'h0405, 8'h14);             // LDA #$14 (b)
        put(16'h0406, 8'h48);                                   // PHA
        put(16'h0407, 8'hA9); put(16'h0408, 8'h22);             // LDA #$22 (a)
        put(16'h0409, 8'h48);                                   // PHA
        put(16'h040A, 8'h20); put(16'h040B, 8'h20); put(16'h040C, 8'h04);  // JSR $0420
        put(16'h040D, 8'h8D); put(16'h040E, 8'h50); put(16'h040F, 8'h03);  // STA $0350 (result)
        put(16'h0410, 8'h22); put(16'h0411, 8'h02);             // ADD SP, #+2 (cleanup)
        put(16'h0412, 8'hBA);                                   // TSX
        put(16'h0413, 8'h8E); put(16'h0414, 8'h51); put(16'h0415, 8'h03);  // STX $0351 (SP_lo)
        put(16'h0416, 8'h4C); put(16'h0417, 8'h16); put(16'h0418, 8'h04);  // JMP $0416 (stuck)

        // Callee at $0420: add_two(a, b) = a + b
        //   PSH #0 frame layout (offsets from new SP):
        //     +0 P  +1 SP_lo  +2 SP_hi  +3 Y  +4 X  +5 A
        //     +6 gap (JSR's 2-byte push leaves one byte unwritten)
        //     +7 ret_lo  +8 ret_hi  +9 arg0 (a)  +10 arg1 (b)
        put(16'h0420, 8'h32); put(16'h0421, 8'h00);             // PSH #0
        put(16'h0422, 8'hB2); put(16'h0423, 8'h09);             // LDA $09,SP (= a = $22)
        put(16'h0424, 8'h18);                                   // CLC
        put(16'h0425, 8'h72); put(16'h0426, 8'h0A);             // ADC $0A,SP (+= b = $14)
        put(16'h0427, 8'h92); put(16'h0428, 8'h05);             // STA $05,SP (overwrite saved-A
                                                                //              with return value)
        put(16'h0429, 8'h62); put(16'h042A, 8'h00);             // PLL #0 (A <- saved-A = $36)
        put(16'h042B, 8'h60);                                   // RTS

        run_until_stuck(16'h0416, 2000, "calling convention");
        expect_mem(16'h0350, 8'h36, "callee returns a + b = $22 + $14 = $36");
        expect_mem(16'h0351, 8'hFF, "caller cleanup leaves SP back at $FF");
        $display("PASS: test_calling_convention");
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
        test_psh_save_slots();
        test_psh_pll_roundtrip();
        test_psh_pll_locals();
        test_psh_pll_flags();
        test_bra_forward();
        test_bra_backward();
        test_bit_imm_z();
        test_bit_imm_nv();
        test_calling_convention();

        $display("=== ALL TESTS PASSED ===");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_sally_isa wallclock timeout");
        $fatal(1);
    end

endmodule
