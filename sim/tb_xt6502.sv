// tb_xt6502.sv — Phase 1 micro-test for the clean-sheet xt6502 core.
//
// Models the synchronous-memory contract (addr cycle N → data_in cycle N+1),
// runs at full speed (rdy=1), checks architectural results, and prints a
// per-cycle trace.  Exercises NOP, JMP, and the cc=01 group (ORA/AND/EOR/ADC/
// STA/LDA/CMP/SBC) across #imm / zp / abs.

`timescale 1ns/1ps
`default_nettype none

module tb_xt6502;

    reg         clk = 0;
    reg         rst = 1;
    wire [15:0] addr;
    wire [7:0]  data_out;
    wire        rw;
    reg  [7:0]  data_in;
    reg         rdy = 1;
    wire        stack_op;
    wire [3:0]  s_high;

    always #5 clk = ~clk;

    // irq_n/nmi_n are pulsed low during the prog7 spin (after CLI) to exercise
    // the hardware-interrupt injection; the shared handler increments $9E.
    integer    cyc = 0;
    integer    spin_start = -1;
    wire       irq_n = (spin_start >= 0 && cyc >= spin_start + 6  && cyc < spin_start + 9 ) ? 1'b0 : 1'b1;
    wire       nmi_n = (spin_start >= 0 && cyc >= spin_start + 40 && cyc < spin_start + 43) ? 1'b0 : 1'b1;

    xt6502 dut (
        .clk(clk), .rst(rst),
        .addr(addr), .data_in(data_in), .data_out(data_out), .rw(rw),
        .rdy(rdy), .irq_n(irq_n), .nmi_n(nmi_n),
        .stack_op(stack_op), .s_high(s_high)
    );

    // Synchronous memory (addr cycle N → data_in cycle N+1).  stack_op routes
    // to the 4 KB hidden stack (as sally_mem does); else flat main memory.
    reg [7:0] mem [0:65535];
    reg [7:0] stack_mem [0:4095];
    always @(posedge clk) begin
        if (rdy) begin
            if (stack_op) begin
                if (!rw) stack_mem[addr[11:0]] <= data_out;
                data_in <= stack_mem[addr[11:0]];
            end else begin
                if (!rw) mem[addr] <= data_out;
                data_in <= mem[addr];
            end
        end
    end

    `define A      dut.A
    `define X      dut.X
    `define Y      dut.Y
    `define PC     dut.PC
    `define P      dut.P
    `define STATE  dut.state

    integer errors = 0;

    task check8(input [8*20-1:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got $%02h exp $%02h", name, got, exp);
                errors = errors + 1;
            end else
                $display("  ok   %0s = $%02h", name, got);
        end
    endtask

    task check1(input [8*20-1:0] name, input got, input exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got %b exp %b", name, got, exp);
                errors = errors + 1;
            end else
                $display("  ok   %0s = %b", name, got);
        end
    endtask

    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        mem[16'hFFFC] = 8'h00;  mem[16'hFFFD] = 8'h02;   // reset → $0200

        // $0200: A9 42     LDA #$42
        mem[16'h0200]=8'hA9; mem[16'h0201]=8'h42;
        // $0202: 85 80     STA $80
        mem[16'h0202]=8'h85; mem[16'h0203]=8'h80;
        // $0204: A9 0F     LDA #$0F
        mem[16'h0204]=8'hA9; mem[16'h0205]=8'h0F;
        // $0206: 25 80     AND $80        ; $0F & $42 = $02
        mem[16'h0206]=8'h25; mem[16'h0207]=8'h80;
        // $0208: 09 30     ORA #$30       ; $02 | $30 = $32
        mem[16'h0208]=8'h09; mem[16'h0209]=8'h30;
        // $020A: 49 0F     EOR #$0F       ; $32 ^ $0F = $3D
        mem[16'h020A]=8'h49; mem[16'h020B]=8'h0F;
        // $020C: A9 10     LDA #$10
        mem[16'h020C]=8'hA9; mem[16'h020D]=8'h10;
        // $020E: 69 05     ADC #$05       ; C=0 → $15
        mem[16'h020E]=8'h69; mem[16'h020F]=8'h05;
        // $0210: 8D 00 03  STA $0300
        mem[16'h0210]=8'h8D; mem[16'h0211]=8'h00; mem[16'h0212]=8'h03;
        // $0213: A9 00     LDA #$00
        mem[16'h0213]=8'hA9; mem[16'h0214]=8'h00;
        // $0215: AD 00 03  LDA $0300      ; A=$15
        mem[16'h0215]=8'hAD; mem[16'h0216]=8'h00; mem[16'h0217]=8'h03;
        // $0218: C9 15     CMP #$15       ; Z=1,C=1,N=0
        mem[16'h0218]=8'hC9; mem[16'h0219]=8'h15;
        // $021A: 4C 1A 02  JMP $021A (spin)
        mem[16'h021A]=8'h4C; mem[16'h021B]=8'h1A; mem[16'h021C]=8'h02;
    end

    // Second program (indexed modes) loaded by initial #2 into the SAME mem,
    // overwriting the spin so execution flows on past CMP.  (Both run in one
    // pass: prog1 lands at $0200-$0219, prog2 at $021A onward.)
    initial begin
        #1;
        // $021A: A2 04       LDX #$04
        mem[16'h021A]=8'hA2; mem[16'h021B]=8'h04;
        // $021C: A9 11       LDA #$11
        mem[16'h021C]=8'hA9; mem[16'h021D]=8'h11;
        // $021E: 9D 00 04    STA $0400,X      ; mem[$0404]=$11  (abs,X store)
        mem[16'h021E]=8'h9D; mem[16'h021F]=8'h00; mem[16'h0220]=8'h04;
        // $0221: A9 00       LDA #$00
        mem[16'h0221]=8'hA9; mem[16'h0222]=8'h00;
        // $0223: BD 00 04    LDA $0400,X      ; A=$11           (abs,X read)
        mem[16'h0223]=8'hBD; mem[16'h0224]=8'h00; mem[16'h0225]=8'h04;
        // $0226: 85 30       STA $30          ; mem[$30]=$11    (proves abs,X read)
        mem[16'h0226]=8'h85; mem[16'h0227]=8'h30;
        // $0228: A0 02       LDY #$02
        mem[16'h0228]=8'hA0; mem[16'h0229]=8'h02;
        // $022A: B9 02 04    LDA $0402,Y      ; A=mem[$0404]=$11(abs,Y read)
        mem[16'h022A]=8'hB9; mem[16'h022B]=8'h02; mem[16'h022C]=8'h04;
        // $022D: 85 31       STA $31          ; mem[$31]=$11    (proves abs,Y read)
        mem[16'h022D]=8'h85; mem[16'h022E]=8'h31;
        // $022F: A9 77       LDA #$77
        mem[16'h022F]=8'hA9; mem[16'h0230]=8'h77;
        // $0231: 85 40       STA $40          ; mem[$40]=$77
        mem[16'h0231]=8'h85; mem[16'h0232]=8'h40;
        // $0233: A2 03       LDX #$03
        mem[16'h0233]=8'hA2; mem[16'h0234]=8'h03;
        // $0235: B5 3D       LDA $3D,X        ; $3D+3=$40 → A=$77 (zp,X read)
        mem[16'h0235]=8'hB5; mem[16'h0236]=8'h3D;
        // $0237: 85 32       STA $32          ; mem[$32]=$77    (proves zp,X read)
        mem[16'h0237]=8'h85; mem[16'h0238]=8'h32;
        // $0239: A2 FF       LDX #$FF
        mem[16'h0239]=8'hA2; mem[16'h023A]=8'hFF;
        // $023B: A9 99       LDA #$99
        mem[16'h023B]=8'hA9; mem[16'h023C]=8'h99;
        // $023D: 9D 10 04    STA $0410,X      ; $050F=$99 (abs,X store, page cross)
        mem[16'h023D]=8'h9D; mem[16'h023E]=8'h10; mem[16'h023F]=8'h04;
        // $0240: A9 00       LDA #$00
        mem[16'h0240]=8'hA9; mem[16'h0241]=8'h00;
        // $0242: BD 10 04    LDA $0410,X      ; A=$99 (abs,X read, page cross)
        mem[16'h0242]=8'hBD; mem[16'h0243]=8'h10; mem[16'h0244]=8'h04;
        // $0245: 4C 45 02    JMP $0245 (spin)  -- overwritten by prog3
        mem[16'h0245]=8'h4C; mem[16'h0246]=8'h45; mem[16'h0247]=8'h02;
    end

    // Third program (indirect modes), flows on from prog2.
    initial begin
        #2;
        // build pointer mem[$40..41] = $0600
        // $0245: A9 00  LDA #$00
        mem[16'h0245]=8'hA9; mem[16'h0246]=8'h00;
        // $0247: 85 40  STA $40
        mem[16'h0247]=8'h85; mem[16'h0248]=8'h40;
        // $0249: A9 06  LDA #$06
        mem[16'h0249]=8'hA9; mem[16'h024A]=8'h06;
        // $024B: 85 41  STA $41        ; ptr[$40]=$0600
        mem[16'h024B]=8'h85; mem[16'h024C]=8'h41;
        // $024D: A0 03  LDY #$03
        mem[16'h024D]=8'hA0; mem[16'h024E]=8'h03;
        // $024F: A9 5A  LDA #$5A
        mem[16'h024F]=8'hA9; mem[16'h0250]=8'h5A;
        // $0251: 91 40  STA ($40),Y    ; mem[$0603]=$5A   (zp),Y store
        mem[16'h0251]=8'h91; mem[16'h0252]=8'h40;
        // $0253: A9 00  LDA #$00
        mem[16'h0253]=8'hA9; mem[16'h0254]=8'h00;
        // $0255: B1 40  LDA ($40),Y    ; A=$5A            (zp),Y read
        mem[16'h0255]=8'hB1; mem[16'h0256]=8'h40;
        // $0257: 85 50  STA $50        ; mem[$50]=$5A     (proves (zp),Y read)
        mem[16'h0257]=8'h85; mem[16'h0258]=8'h50;
        // build pointer mem[$44..45] = $0610
        // $0259: A9 10  LDA #$10
        mem[16'h0259]=8'hA9; mem[16'h025A]=8'h10;
        // $025B: 85 44  STA $44
        mem[16'h025B]=8'h85; mem[16'h025C]=8'h44;
        // $025D: A9 06  LDA #$06
        mem[16'h025D]=8'hA9; mem[16'h025E]=8'h06;
        // $025F: 85 45  STA $45        ; ptr[$44]=$0610
        mem[16'h025F]=8'h85; mem[16'h0260]=8'h45;
        // $0261: A2 04  LDX #$04
        mem[16'h0261]=8'hA2; mem[16'h0262]=8'h04;
        // $0263: A9 3C  LDA #$3C
        mem[16'h0263]=8'hA9; mem[16'h0264]=8'h3C;
        // $0265: 81 40  STA ($40,X)    ; ptr[$40+4=$44]=$0610 → mem[$0610]=$3C (zp,X) store
        mem[16'h0265]=8'h81; mem[16'h0266]=8'h40;
        // $0267: A9 00  LDA #$00
        mem[16'h0267]=8'hA9; mem[16'h0268]=8'h00;
        // $0269: A1 40  LDA ($40,X)    ; A=$3C            (zp,X) read
        mem[16'h0269]=8'hA1; mem[16'h026A]=8'h40;
        // $026B: 4C 6B 02  JMP $026B (spin)  -- overwritten by prog4
        mem[16'h026B]=8'h4C; mem[16'h026C]=8'h6B; mem[16'h026D]=8'h02;
    end

    // Fourth program (control flow: flags, transfers, inc/dec, branch loop).
    initial begin
        #3;
        // $026B: 18        CLC
        mem[16'h026B]=8'h18;
        // $026C: A9 00     LDA #$00
        mem[16'h026C]=8'hA9; mem[16'h026D]=8'h00;
        // $026E: A2 03     LDX #$03
        mem[16'h026E]=8'hA2; mem[16'h026F]=8'h03;
        // $0270: 69 05     ADC #$05      ; loop body: A += 5
        mem[16'h0270]=8'h69; mem[16'h0271]=8'h05;
        // $0272: CA        DEX
        mem[16'h0272]=8'hCA;
        // $0273: D0 FB     BNE $0270     ; offset -5 → loop while X!=0
        mem[16'h0273]=8'hD0; mem[16'h0274]=8'hFB;
        // $0275: 85 60     STA $60       ; mem[$60]=A=$0F (3×5)
        mem[16'h0275]=8'h85; mem[16'h0276]=8'h60;
        // $0277: E8        INX           ; X: 0→1
        mem[16'h0277]=8'hE8;
        // $0278: 8A        TXA           ; A=X=1
        mem[16'h0278]=8'h8A;
        // $0279: 85 61     STA $61       ; mem[$61]=$01
        mem[16'h0279]=8'h85; mem[16'h027A]=8'h61;
        // $027B: 4C 7B 02  JMP $027B (spin)  -- overwritten by prog5
        mem[16'h027B]=8'h4C; mem[16'h027C]=8'h7B; mem[16'h027D]=8'h02;
    end

    // Fifth program (RMW: INC/DEC/ASL memory + accumulator shifts).
    initial begin
        #4;
        // $027B: A9 0F  LDA #$0F
        mem[16'h027B]=8'hA9; mem[16'h027C]=8'h0F;
        // $027D: 85 70  STA $70
        mem[16'h027D]=8'h85; mem[16'h027E]=8'h70;
        // $027F: E6 70  INC $70        ; $10
        mem[16'h027F]=8'hE6; mem[16'h0280]=8'h70;
        // $0281: E6 70  INC $70        ; $11
        mem[16'h0281]=8'hE6; mem[16'h0282]=8'h70;
        // $0283: A9 81  LDA #$81
        mem[16'h0283]=8'hA9; mem[16'h0284]=8'h81;
        // $0285: 85 71  STA $71
        mem[16'h0285]=8'h85; mem[16'h0286]=8'h71;
        // $0287: 06 71  ASL $71        ; $81<<1 = $02 (C=1)
        mem[16'h0287]=8'h06; mem[16'h0288]=8'h71;
        // $0289: A9 03  LDA #$03
        mem[16'h0289]=8'hA9; mem[16'h028A]=8'h03;
        // $028B: 0A     ASL A          ; $06
        mem[16'h028B]=8'h0A;
        // $028C: 0A     ASL A          ; $0C
        mem[16'h028C]=8'h0A;
        // $028D: 85 73  STA $73        ; mem[$73]=$0C
        mem[16'h028D]=8'h85; mem[16'h028E]=8'h73;
        // $028F: A9 05  LDA #$05
        mem[16'h028F]=8'hA9; mem[16'h0290]=8'h05;
        // $0291: 8D 00 07  STA $0700
        mem[16'h0291]=8'h8D; mem[16'h0292]=8'h00; mem[16'h0293]=8'h07;
        // $0294: CE 00 07  DEC $0700   ; $04
        mem[16'h0294]=8'hCE; mem[16'h0295]=8'h00; mem[16'h0296]=8'h07;
        // $0297: 4C 97 02  JMP $0297 (spin)  -- overwritten by prog6
        mem[16'h0297]=8'h4C; mem[16'h0298]=8'h97; mem[16'h0299]=8'h02;
    end

    // Sixth program (stack: PHA/PLA LIFO + PHP/PLP flag round-trip).
    initial begin
        #5;
        // $0297: A9 AB  LDA #$AB
        mem[16'h0297]=8'hA9; mem[16'h0298]=8'hAB;
        // $0299: 48     PHA            ; stack[$FFF]=$AB, SP→$FFE
        mem[16'h0299]=8'h48;
        // $029A: A9 CD  LDA #$CD
        mem[16'h029A]=8'hA9; mem[16'h029B]=8'hCD;
        // $029C: 48     PHA            ; stack[$FFE]=$CD, SP→$FFD
        mem[16'h029C]=8'h48;
        // $029D: A9 00  LDA #$00
        mem[16'h029D]=8'hA9; mem[16'h029E]=8'h00;
        // $029F: 68     PLA            ; A=$CD, SP→$FFE
        mem[16'h029F]=8'h68;
        // $02A0: 85 74  STA $74        ; mem[$74]=$CD
        mem[16'h02A0]=8'h85; mem[16'h02A1]=8'h74;
        // $02A2: 68     PLA            ; A=$AB, SP→$FFF
        mem[16'h02A2]=8'h68;
        // $02A3: 85 75  STA $75        ; mem[$75]=$AB
        mem[16'h02A3]=8'h85; mem[16'h02A4]=8'h75;
        // $02A5: 38     SEC            ; C=1
        mem[16'h02A5]=8'h38;
        // $02A6: 08     PHP            ; push P (C=1)
        mem[16'h02A6]=8'h08;
        // $02A7: 18     CLC            ; C=0
        mem[16'h02A7]=8'h18;
        // $02A8: 28     PLP            ; pull P → C=1 restored
        mem[16'h02A8]=8'h28;
        // $02A9: A9 00  LDA #$00
        mem[16'h02A9]=8'hA9; mem[16'h02AA]=8'h00;
        // $02AB: 69 00  ADC #$00       ; A = 0+0+C(1) = 1
        mem[16'h02AB]=8'h69; mem[16'h02AC]=8'h00;
        // $02AD: 85 76  STA $76        ; mem[$76]=$01 (proves PLP restored C)
        mem[16'h02AD]=8'h85; mem[16'h02AE]=8'h76;
        // $02AF: 4C AF 02  JMP $02AF (spin)  -- overwritten by prog7
        mem[16'h02AF]=8'h4C; mem[16'h02B0]=8'hAF; mem[16'h02B1]=8'h02;
    end

    // Seventh program (the rest of the documented ISA): JSR/RTS, JMP indirect,
    // LDX/STX/LDY/STY (zp/abs/zp,Y/abs,Y), CPX/CPY, BIT, indexed RMW, BCD
    // ADC/SBC, and BRK/RTI.  Chains on from prog6 via `JMP $0800` (the
    // assembled bytes come from /tmp/asm6502.py).  Subroutine at $0950,
    // BRK/IRQ handler at $0970, vector at $FFFE/$FFFF.
    initial begin
        #6;
        mem[16'h02AF]=8'h4C; mem[16'h02B0]=8'h00; mem[16'h02B1]=8'h08;   // JMP $0800
        mem[16'hFFFE]=8'h70; mem[16'hFFFF]=8'h09;                        // IRQ/BRK vector → $0970
        mem[16'hFFFA]=8'h70; mem[16'hFFFB]=8'h09;                        // NMI vector     → $0970
        mem[16'h0800]=8'hA9; mem[16'h0801]=8'h00; mem[16'h0802]=8'h20;
        mem[16'h0803]=8'h50; mem[16'h0804]=8'h09; mem[16'h0805]=8'h85;
        mem[16'h0806]=8'h90; mem[16'h0807]=8'hA9; mem[16'h0808]=8'h20;
        mem[16'h0809]=8'h85; mem[16'h080A]=8'h20; mem[16'h080B]=8'hA9;
        mem[16'h080C]=8'h08; mem[16'h080D]=8'h85; mem[16'h080E]=8'h21;
        mem[16'h080F]=8'h6C; mem[16'h0810]=8'h20; mem[16'h0811]=8'h00;
        mem[16'h0812]=8'hA9; mem[16'h0813]=8'hFF; mem[16'h0814]=8'h85;
        mem[16'h0815]=8'h91;
        mem[16'h0820]=8'hA9; mem[16'h0821]=8'h55; mem[16'h0822]=8'h85;
        mem[16'h0823]=8'h91; mem[16'h0824]=8'hA2; mem[16'h0825]=8'h7E;
        mem[16'h0826]=8'h86; mem[16'h0827]=8'h92; mem[16'h0828]=8'hA0;
        mem[16'h0829]=8'h3C; mem[16'h082A]=8'h84; mem[16'h082B]=8'h93;
        mem[16'h082C]=8'hA2; mem[16'h082D]=8'h00; mem[16'h082E]=8'hA6;
        mem[16'h082F]=8'h92; mem[16'h0830]=8'h8E; mem[16'h0831]=8'h00;
        mem[16'h0832]=8'h0B; mem[16'h0833]=8'hA0; mem[16'h0834]=8'h00;
        mem[16'h0835]=8'hAC; mem[16'h0836]=8'h00; mem[16'h0837]=8'h0B;
        mem[16'h0838]=8'h8C; mem[16'h0839]=8'h01; mem[16'h083A]=8'h0B;
        mem[16'h083B]=8'hA0; mem[16'h083C]=8'h03; mem[16'h083D]=8'hA2;
        mem[16'h083E]=8'h00; mem[16'h083F]=8'hB6; mem[16'h0840]=8'h90;
        mem[16'h0841]=8'h86; mem[16'h0842]=8'hA0; mem[16'h0843]=8'hA0;
        mem[16'h0844]=8'h01; mem[16'h0845]=8'hBE; mem[16'h0846]=8'hFF;
        mem[16'h0847]=8'h0A; mem[16'h0848]=8'h86; mem[16'h0849]=8'hA1;
        mem[16'h084A]=8'hA2; mem[16'h084B]=8'h10; mem[16'h084C]=8'hE0;
        mem[16'h084D]=8'h10; mem[16'h084E]=8'hA9; mem[16'h084F]=8'h00;
        mem[16'h0850]=8'hF0; mem[16'h0851]=8'h02; mem[16'h0852]=8'hA9;
        mem[16'h0853]=8'hFF; mem[16'h0854]=8'h85; mem[16'h0855]=8'h94;
        mem[16'h0856]=8'hA0; mem[16'h0857]=8'h20; mem[16'h0858]=8'hC0;
        mem[16'h0859]=8'h10; mem[16'h085A]=8'hA9; mem[16'h085B]=8'h00;
        mem[16'h085C]=8'hB0; mem[16'h085D]=8'h02; mem[16'h085E]=8'hA9;
        mem[16'h085F]=8'hFF; mem[16'h0860]=8'h85; mem[16'h0861]=8'h95;
        mem[16'h0862]=8'hA9; mem[16'h0863]=8'hC0; mem[16'h0864]=8'h85;
        mem[16'h0865]=8'h23; mem[16'h0866]=8'hA9; mem[16'h0867]=8'h00;
        mem[16'h0868]=8'h24; mem[16'h0869]=8'h23; mem[16'h086A]=8'hA9;
        mem[16'h086B]=8'h00; mem[16'h086C]=8'h70; mem[16'h086D]=8'h02;
        mem[16'h086E]=8'hA9; mem[16'h086F]=8'hFF; mem[16'h0870]=8'h85;
        mem[16'h0871]=8'h96; mem[16'h0872]=8'hA9; mem[16'h0873]=8'h20;
        mem[16'h0874]=8'h85; mem[16'h0875]=8'h97; mem[16'h0876]=8'hA2;
        mem[16'h0877]=8'h05; mem[16'h0878]=8'hF6; mem[16'h0879]=8'h92;
        mem[16'h087A]=8'hA9; mem[16'h087B]=8'h30; mem[16'h087C]=8'h8D;
        mem[16'h087D]=8'h02; mem[16'h087E]=8'h0B; mem[16'h087F]=8'hA2;
        mem[16'h0880]=8'h02; mem[16'h0881]=8'hFE; mem[16'h0882]=8'h00;
        mem[16'h0883]=8'h0B; mem[16'h0884]=8'hA9; mem[16'h0885]=8'h81;
        mem[16'h0886]=8'h8D; mem[16'h0887]=8'h03; mem[16'h0888]=8'h0B;
        mem[16'h0889]=8'h1E; mem[16'h088A]=8'h01; mem[16'h088B]=8'h0B;
        mem[16'h088C]=8'hF8; mem[16'h088D]=8'h18; mem[16'h088E]=8'hA9;
        mem[16'h088F]=8'h25; mem[16'h0890]=8'h69; mem[16'h0891]=8'h48;
        mem[16'h0892]=8'h85; mem[16'h0893]=8'h98; mem[16'h0894]=8'h38;
        mem[16'h0895]=8'hA9; mem[16'h0896]=8'h50; mem[16'h0897]=8'hE9;
        mem[16'h0898]=8'h25; mem[16'h0899]=8'h85; mem[16'h089A]=8'h99;
        mem[16'h089B]=8'h18; mem[16'h089C]=8'hA9; mem[16'h089D]=8'h99;
        mem[16'h089E]=8'h69; mem[16'h089F]=8'h01; mem[16'h08A0]=8'h85;
        mem[16'h08A1]=8'h9A; mem[16'h08A2]=8'hA9; mem[16'h08A3]=8'h00;
        mem[16'h08A4]=8'h69; mem[16'h08A5]=8'h00; mem[16'h08A6]=8'h85;
        mem[16'h08A7]=8'h9B; mem[16'h08A8]=8'hD8; mem[16'h08A9]=8'hA9;
        mem[16'h08AA]=8'h00; mem[16'h08AB]=8'h85; mem[16'h08AC]=8'h9C;
        mem[16'h08AD]=8'h00; mem[16'h08AE]=8'hEA; mem[16'h08AF]=8'hA5;
        mem[16'h08B0]=8'h9C; mem[16'h08B1]=8'h85; mem[16'h08B2]=8'h9D;
        mem[16'h08B3]=8'h58; mem[16'h08B4]=8'h4C; mem[16'h08B5]=8'hB4;   // CLI ; JMP $08B4 (spin)
        mem[16'h08B6]=8'h08;
        mem[16'h0950]=8'hA9; mem[16'h0951]=8'h33; mem[16'h0952]=8'h60;
        // Shared handler (BRK + IRQ + NMI): INC $9E ; LDA #$AA ; STA $9C ; RTI
        mem[16'h0970]=8'hE6; mem[16'h0971]=8'h9E; mem[16'h0972]=8'hA9;
        mem[16'h0973]=8'hAA; mem[16'h0974]=8'h85; mem[16'h0975]=8'h9C;
        mem[16'h0976]=8'h40;
    end

    integer jmp_prev = -1;
    reg [15:0] jmp_prev_addr = 16'hFFFF;
    integer jmp_iters = 0;
    reg     intr_since = 1'b0;                     // an IRQ/NMI/BRK fired since last JMP_HI
    always @(posedge clk) if (!rst) begin
        if (cyc < 50)
            $display("[%0d] st=%0d addr=%04h di=%02h rw=%b | A=%02h PC=%04h P=%02h",
                     cyc, `STATE, addr, data_in, rw, `A, `PC, `P);
        if (`STATE == 6'd48) intr_since = 1'b1;    // ST_BRK_PCH = interrupt/BRK sequence
        if (`STATE == 6'd7) begin                 // ST_JMP_HI (self-spin guard)
            // Only a JMP whose target == the previous JMP target is a self-spin;
            // one-shot JMPs (e.g. the prog6→prog7 chain) just reset the window.
            if (jmp_prev >= 0 && addr == jmp_prev_addr) begin
                jmp_iters = jmp_iters + 1;
                // The steady-state spin is 3 cycles; tolerate the longer gap an
                // interrupt introduces (the handler runs between two JMP_HIs).
                if (!intr_since && (cyc - jmp_prev) != 3) begin
                    $display("  FAIL JMP spin period = %0d (expected 3)", cyc - jmp_prev);
                    errors = errors + 1;
                end
                // Latch the cycle the final spin is firmly established, so the
                // IRQ/NMI pulse windows (cyc-relative) land inside it.
                if (jmp_iters == 2 && spin_start < 0) spin_start = cyc;
            end
            jmp_prev = cyc;
            jmp_prev_addr = addr;
            intr_since = 1'b0;
        end
        cyc = cyc + 1;
    end

    initial begin
        data_in = 8'h00;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (1600) @(posedge clk);

        $display("=== checks ===");
        // prog1 (imm/zp/abs ALU + stores)
        check8("mem[$80]  (STA zp)",   mem[16'h0080], 8'h42);
        check8("mem[$0300] (STA abs)", mem[16'h0300], 8'h15);
        // prog2 (indexed modes)
        check8("mem[$0404] (STA abs,X)",     mem[16'h0404], 8'h11);
        check8("mem[$30] (LDA abs,X read)",  mem[16'h0030], 8'h11);
        check8("mem[$31] (LDA abs,Y read)",  mem[16'h0031], 8'h11);
        check8("mem[$32] (LDA zp,X read)",   mem[16'h0032], 8'h77);
        check8("mem[$050F](STA abs,X xpage)",mem[16'h050F], 8'h99);
        // prog3 (indirect modes)
        check8("mem[$0603]((zp),Y store)",   mem[16'h0603], 8'h5A);
        check8("mem[$50] ((zp),Y read)",     mem[16'h0050], 8'h5A);
        check8("mem[$0610]((zp,X) store)",   mem[16'h0610], 8'h3C);
        // prog4 (control flow): loop CLC/ADC/DEX/BNE ×3 → A=$0F; INX/TXA → $01
        check8("mem[$60] (ADC/DEX/BNE loop)",mem[16'h0060], 8'h0F);
        check8("mem[$61] (INX/TXA)",         mem[16'h0061], 8'h01);
        // prog5 (RMW + accumulator shifts)
        check8("mem[$70] (INC zp x2)",       mem[16'h0070], 8'h11);
        check8("mem[$71] (ASL zp $81)",      mem[16'h0071], 8'h02);
        check8("mem[$73] (ASL A x2)",        mem[16'h0073], 8'h0C);
        check8("mem[$0700] (DEC abs)",       mem[16'h0700], 8'h04);
        // prog6 (stack: PHA/PLA LIFO + PHP/PLP)
        check8("mem[$74] (PLA #2 = CD)",     mem[16'h0074], 8'hCD);
        check8("mem[$75] (PLA #1 = AB)",     mem[16'h0075], 8'hAB);
        check8("mem[$76] (PLP restored C)",  mem[16'h0076], 8'h01);
        // prog7 (JSR/RTS, JMP ind, LDX/STX/LDY/STY, CPX/CPY, BIT, RMW, BCD, BRK/RTI)
        check8("mem[$90] (JSR/RTS)",         mem[16'h0090], 8'h33);
        check8("mem[$91] (JMP indirect)",    mem[16'h0091], 8'h55);
        check8("mem[$92] (STX zp)",          mem[16'h0092], 8'h7E);
        check8("mem[$93] (STY zp)",          mem[16'h0093], 8'h3C);
        check8("mem[$0B00] (STX abs)",       mem[16'h0B00], 8'h7E);
        check8("mem[$0B01] (STY abs)",       mem[16'h0B01], 8'h7E);
        check8("mem[$A0] (LDX zp,Y)",        mem[16'h00A0], 8'h3C);
        check8("mem[$A1] (LDX abs,Y xpage)", mem[16'h00A1], 8'h7E);
        check8("mem[$94] (CPX= → BEQ)",      mem[16'h0094], 8'h00);
        check8("mem[$95] (CPY → BCS)",       mem[16'h0095], 8'h00);
        check8("mem[$96] (BIT → BVS)",       mem[16'h0096], 8'h00);
        check8("mem[$97] (INC zp,X)",        mem[16'h0097], 8'h21);
        check8("mem[$0B02] (INC abs,X)",     mem[16'h0B02], 8'h31);
        check8("mem[$0B03] (ASL abs,X)",     mem[16'h0B03], 8'h02);
        check8("mem[$98] (BCD 25+48=73)",    mem[16'h0098], 8'h73);
        check8("mem[$99] (BCD 50-25=25)",    mem[16'h0099], 8'h25);
        check8("mem[$9A] (BCD 99+1=00)",     mem[16'h009A], 8'h00);
        check8("mem[$9B] (BCD carry → 01)",  mem[16'h009B], 8'h01);
        check8("mem[$9C] (BRK handler ran)", mem[16'h009C], 8'hAA);
        check8("mem[$9D] (RTI returned)",    mem[16'h009D], 8'hAA);
        // BRK + IRQ + NMI each ran the shared handler (INC $9E) exactly once.
        check8("mem[$9E] (BRK+IRQ+NMI=3)",   mem[16'h009E], 8'h03);
        if (spin_start < 0) begin $display("  FAIL spin never reached (IRQ/NMI untested)"); errors=errors+1; end
        if (jmp_iters < 2) begin $display("  FAIL JMP spin not exercised"); errors=errors+1; end
        else $display("  ok   JMP spin = 3 cyc (%0d iters)", jmp_iters);

        if (errors == 0) $display("*** xt6502 PHASE1 OK ***");
        else             $display("*** xt6502 PHASE1 FAIL (%0d errors) ***", errors);
        $finish;
    end

endmodule

`default_nettype wire
