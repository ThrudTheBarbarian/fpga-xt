// xt6502.sv — Artix-balanced cycle-accurate 6502 + xtc embellishments.
//
// Clean-sheet replacement for SALLY  Drop-in: matches the sally_core
// port list exactly (boundary (a)) so it runs against the full existing test
// suite (tb_sally / tb_sally_isa / tb_sally_stack / Klaus) unchanged.
//
// ── The structural fix: a registered address (MAR) ──────────────────────
// `addr` is normally driven from the MAR *register*, not a combinational
// adder, so the long `read → compute → next-address` path ends at a flop, not
// the BRAM address pins.  Synchronous-memory contract (= sally_core):
//   cycle N : addr = MAR_N → memory ;  cycle N+1 : data_in = mem[MAR_N] (= MDR)
// CYCLE-LOCKED data-dependent address cycles (jump target, indirect pointer)
// bypass MAR with a combinational effective address (use_ea/ea).
// On rdy=0 ALL state freezes — `rdy` is the clock-enable.
//
// ── Fetch model (cycle-accurate, overlapped) ─────────────────────────────
// Each instruction's final READ cycle presents the NEXT opcode address (so its
// DECODE consumes it next cycle); WRITE-ending instructions use a dedicated
// ST_FETCH after the store.  Cycle counts match the NMOS 6502.
//
// ── Status ──────────────────────────────────────────────────────────────
// Full documented ISA: cc=01/cc=10/cc=00 across all modes, RMW (zp/abs/zp,X/
// abs,X), the stack (PHA/PHP/PLA/PLP), the complex control flow (JSR/RTS/RTI/
// BRK, JMP abs + indirect with the NMOS page-wrap bug), branches, flags,
// transfers, INC/DEC, and BCD ADC/SBC.  12-bit hidden stack throughout.
// NEXT: hardware IRQ/NMI injection, then Klaus, then xt embellishments.

`default_nettype none

module xt6502 (
    input  wire        clk,
    input  wire        rst,        // active-high synchronous reset

    output wire [15:0] addr,
    input  wire [7:0]  data_in,
    output wire [7:0]  data_out,
    output wire        rw,         // 1 = read, 0 = write
    input  wire        rdy,        // 1 = run, 0 = stall/clock-enable-low
    // (data_in == 0), computed in sally_mem next to the data rather than here.
    // The Z-flag bit is the clk_sally limiter and the path is route-dominated,
    // so the 8-input reduction must not sit at the far end of the crossing.
    input  wire        di_zero_in,

    input  wire        irq_n,
    input  wire        nmi_n,

    output wire        stack_op,
    output wire [3:0]  s_high,

    // ── Debug taps (pure fan-out of architectural state; read by xt6502_debug) ──
    output wire        dbg_boundary,   // 1 = at ST_FETCH: the once-per-instruction boundary
    output wire [15:0] dbg_pc,
    output wire [7:0]  dbg_a,
    output wire [7:0]  dbg_x,
    output wire [7:0]  dbg_y,
    output wire [7:0]  dbg_s,
    output wire [7:0]  dbg_p,
    output wire [3:0]  dbg_shigh,

    // ── Bus-access taps (for the data watchpoint) ──
    output wire        dbg_bus_stb,    // 1 = a bus access commits this cycle (= rdy)
    output wire [15:0] dbg_bus_addr,   // address of that access (= the live addr bus)
    output wire        dbg_bus_rw      // 1 = read, 0 = write
);

    localparam [15:0] VEC_RESET = 16'hFFFC;

    // ── Architectural registers ──────────────────────────────────────────
    reg  [15:0] PC;
    reg  [7:0]  A, X, Y;
    reg  [7:0]  S;
    reg  [3:0]  S_high;
    reg  [7:0]  P;                  // NV-BDIZC

    localparam C_BIT=0, Z_BIT=1, I_BIT=2, D_BIT=3, V_BIT=6, N_BIT=7;
    // Bits 4 (B) and 5 (U) are not architectural flags — they are forced by
    // literal masks on push/pull (B per BRK/IRQ context, U always 1).

    // ── Pipeline / scratch registers ─────────────────────────────────────
    reg  [15:0] MAR;
    reg  [7:0]  IR;
    reg  [7:0]  pcl_q;              // PCL held during reset/JMP-indirect target
    reg  [7:0]  adl;                // latched effective-address / pointer low byte
    reg  [7:0]  adh;                // latched effective-address high byte

    wire [7:0]  di = data_in;       // = MDR (byte addressed last cycle)
    wire [7:0]  M  = di;            // ALU operand (immediate or memory)

    // ── Opcode decode helpers ────────────────────────────────────────────
    // Regular aaa-bbb-cc encoding: aaa = IR[7:5], bbb = IR[4:2], cc = IR[1:0].
    wire [2:0]  ir_op  = IR[7:5];
    wire [2:0]  ir_bbb = IR[4:2];
    wire [1:0]  ir_cc  = IR[1:0];

    // Stores: STA (cc=01,aaa=100), STX (cc=10,aaa=100), STY (cc=00,aaa=100).
    wire is_sta = (ir_cc == 2'b01) && (ir_op == 3'b100);
    wire is_stx = (ir_cc == 2'b10) && (ir_op == 3'b100);
    wire is_sty = (ir_cc == 2'b00) && (ir_op == 3'b100);
    // STA (d,SP),Y ($13) reaches the abs,X-style store path with A as the source.
    wire is_store = is_sta | is_stx | is_sty | (IR == 8'h13);
    wire [7:0] store_src = is_stx ? X : (is_sty ? Y : A);

    // Non-cc01 read ops dispatched through the shared addressing engine.
    wire is_ldx = (ir_cc == 2'b10) && (ir_op == 3'b101);   // LDX
    wire is_ldy = (ir_cc == 2'b00) && (ir_op == 3'b101);   // LDY
    wire is_cpx = (ir_cc == 2'b00) && (ir_op == 3'b111);   // CPX
    wire is_cpy = (ir_cc == 2'b00) && (ir_op == 3'b110);   // CPY
    wire is_bit = (ir_cc == 2'b00) && (ir_op == 3'b001);   // BIT

    // Index register: Y for cc=01 (zp),Y / abs,Y and cc=10 STX/LDX zp,Y / abs,Y;
    // X otherwise (zp,X / abs,X / (zp,X)).
    wire idx_is_y = ((ir_cc == 2'b01) && (ir_bbb == 3'b100 || ir_bbb == 3'b110))
                  | ((ir_cc == 2'b10) && (ir_op  == 3'b100 || ir_op  == 3'b101))
                  | ((ir_cc == 2'b11) && (IR[5] == 1'b0));   // (d,SP),Y post-index by Y
    wire [7:0]  idx     = idx_is_y ? Y : X;
    wire [8:0]  abx_sum = {1'b0, adl} + {1'b0, idx};  // abs,X/Y low-byte add + carry
    wire [7:0]  zpx_low = di + idx;                   // zp,X/zp,Y low byte (wraps in ZP)

    // cc=10 memory read-modify-write (ASL/ROL/LSR/ROR mem, DEC, INC) — i.e.
    // not STX (100), not LDX (101), not the accumulator form (bbb=010).
    wire op_is_rmw = (ir_cc == 2'b10) && (ir_op != 3'b100)
                   && (ir_op != 3'b101) && (ir_bbb != 3'b010);

    // ── Compare/arith binary sums (CARRY4) ────────────────────────────────
    wire [8:0] adc_bin = {1'b0, A} + {1'b0,  M} + {8'b0, P[C_BIT]};   // A + M + C
    wire [8:0] sbc_bin = {1'b0, A} + {1'b0, ~M} + {8'b0, P[C_BIT]};   // A - M - !C
    wire [8:0] cmp_bin = {1'b0, A} + {1'b0, ~M} + 9'd1;               // A - M
    wire [8:0] cpx_bin = {1'b0, X} + {1'b0, ~M} + 9'd1;               // X - M
    wire [8:0] cpy_bin = {1'b0, Y} + {1'b0, ~M} + 9'd1;               // Y - M

    // ── BCD decimal ADC (NMOS quirks) ─────────────────────────────────────
    // Z is from the BINARY result; N/V from the high-nibble intermediate
    // (before the +$60 correction); C from the decimal carry.
    wire [4:0] adc_lo  = {1'b0, A[3:0]} + {1'b0, M[3:0]} + {4'b0, P[C_BIT]};   // 0..$1F
    wire [4:0] adc_lo2 = (adc_lo >= 5'd10) ? (((adc_lo + 5'd6) & 5'h0F) | 5'h10)
                                           : adc_lo;
    wire [8:0] adc_hi  = {1'b0, A[7:4], 4'h0} + {1'b0, M[7:4], 4'h0}
                       + {4'b0, adc_lo2};                                       // intermediate A1
    wire       adc_dn  = adc_hi[7];
    wire       adc_dv  = (~(A[7] ^ M[7])) & (A[7] ^ adc_hi[7]);
    wire       adc_dc  = (adc_hi >= 9'h0A0);
    wire [7:0] adc_dres= adc_dc ? (adc_hi[7:0] + 8'h60) : adc_hi[7:0];

    // ── BCD decimal SBC (NMOS) — result only; flags follow the binary path ─
    reg  [7:0]         sbc_dres;
    reg  signed [15:0] sbc_al, sbc_a1;
    always @* begin
        sbc_al = $signed({12'b0, A[3:0]}) - $signed({12'b0, M[3:0]})
               - (P[C_BIT] ? 16'sd0 : 16'sd1);
        if (sbc_al < 0)
            sbc_al = ((sbc_al - 16'sd6) & 16'sd15) - 16'sd16;   // ((AL-6)&$0F) - $10
        sbc_a1 = $signed({8'b0, A[7:4], 4'h0}) - $signed({8'b0, M[7:4], 4'h0}) + sbc_al;
        if (sbc_a1 < 0)
            sbc_a1 = sbc_a1 - 16'sd96;                          // - $60
        sbc_dres = sbc_a1[7:0];
    end

    // ── ALU (read/ALU ops): one block, outputs result + all four flags ────
    reg  [7:0]  alu_r;
    reg         alu_n, alu_z, alu_c, alu_v;
    always @* begin
        alu_r = M; alu_n = M[7]; alu_z = (M == 8'h00);
        alu_c = P[C_BIT]; alu_v = P[V_BIT];
        case (ir_op)
            3'b000: begin alu_r = A | M; alu_n = alu_r[7]; alu_z = (alu_r == 8'h00); end // ORA
            3'b001: begin alu_r = A & M; alu_n = alu_r[7]; alu_z = (alu_r == 8'h00); end // AND
            3'b010: begin alu_r = A ^ M; alu_n = alu_r[7]; alu_z = (alu_r == 8'h00); end // EOR
            3'b101: begin alu_r = M;     alu_n = M[7];     alu_z = (M == 8'h00);     end // LDA
            3'b011: begin                                                               // ADC
                if (P[D_BIT]) begin
                    alu_r = adc_dres; alu_n = adc_dn;
                    alu_z = (adc_bin[7:0] == 8'h00); alu_c = adc_dc; alu_v = adc_dv;
                end else begin
                    alu_r = adc_bin[7:0]; alu_n = adc_bin[7];
                    alu_z = (adc_bin[7:0] == 8'h00); alu_c = adc_bin[8];
                    alu_v = (~(A[7] ^ M[7])) & (A[7] ^ adc_bin[7]);
                end
            end
            3'b111: begin                                                               // SBC
                alu_r = P[D_BIT] ? sbc_dres : sbc_bin[7:0];
                alu_n = sbc_bin[7]; alu_z = (sbc_bin[7:0] == 8'h00); alu_c = sbc_bin[8];
                alu_v = (A[7] ^ M[7]) & (A[7] ^ sbc_bin[7]);
            end
            3'b110: begin                                                               // CMP (A-M)
                alu_r = cmp_bin[7:0]; alu_n = cmp_bin[7];
                alu_z = (cmp_bin[7:0] == 8'h00); alu_c = cmp_bin[8];
            end
            default: ;                                                                  // STA: no ALU
        endcase
    end

    // ── Shift / inc / dec primitive (returns {carry, result}) ─────────────
    // op = IR[7:5]: 000 ASL, 001 ROL, 010 LSR, 011 ROR, 110 DEC, 111 INC.
    function [8:0] do_shift(input [2:0] op, input [7:0] v, input cin);
        case (op)
            3'b000: do_shift = { v[7], v[6:0], 1'b0 };   // ASL: C=v7, <<1
            3'b001: do_shift = { v[7], v[6:0], cin  };   // ROL
            3'b010: do_shift = { v[0], 1'b0, v[7:1] };   // LSR: C=v0, >>1
            3'b011: do_shift = { v[0], cin,  v[7:1] };   // ROR
            3'b110: do_shift = { 1'b0, v - 8'd1 };       // DEC
            3'b111: do_shift = { 1'b0, v + 8'd1 };       // INC
            default:do_shift = { 1'b0, v };
        endcase
    endfunction

    reg  [7:0] rmw_q;               // latched RMW result (written in ST_RMW_WR)
    wire [8:0] rmw_sh = do_shift(IR[7:5], di, P[C_BIT]);  // RMW    (ST_RMW_RD: di=value)
    wire [8:0] acc_sh = do_shift(di[7:5], A, P[C_BIT]);   // acc shift (DECODE: di=opcode)

    // ── Implied-op result (transfers / INX/DEX/INY/DEY), keyed on di=opcode ─
    reg  [7:0]  imp_val;
    always @* begin
        case (di)
            8'h8A:       imp_val = X;          // TXA
            8'h98:       imp_val = Y;          // TYA
            8'hAA, 8'hA8: imp_val = A;         // TAX, TAY
            8'hBA:       imp_val = S;          // TSX
            8'hE8:       imp_val = X + 8'd1;   // INX
            8'hCA:       imp_val = X - 8'd1;   // DEX
            8'hC8:       imp_val = Y + 8'd1;   // INY
            8'h88:       imp_val = Y - 8'd1;   // DEY
            default:     imp_val = 8'h00;
        endcase
    end

    // ── Branch condition (ST_BRA; IR = branch opcode) + target (ST_BRA_ADD) ─
    wire [1:0] br_sel   = IR[7:6];             // 00=N 01=V 10=C 11=Z
    wire       br_flagv = (br_sel == 2'b00) ? P[N_BIT] :
                          (br_sel == 2'b01) ? P[V_BIT] :
                          (br_sel == 2'b10) ? P[C_BIT] : P[Z_BIT];
    wire       bra_always = (IR == 8'h80);              // 65C02 BRA — always taken
    wire       br_taken = bra_always | (br_flagv == IR[5]);
    wire [15:0] bra_target = PC + {{8{adl[7]}}, adl};   // PC = instr+2, adl = offset
    wire        bra_cross  = (bra_target[15:8] != PC[15:8]);

    // ── 12-bit hidden stack pointer (xt embellishment) ────────────────────
    // SP = {S_high, S}; the CPU drives addr={4'h0,SP} with stack_op=1 on
    // push/pull cycles (sally_mem routes these to the 4 KB hidden stack).
    wire [11:0] sp12     = { S_high, S };
    wire [11:0] sp12_inc = sp12 + 12'd1;
    wire [11:0] sp12_dec = sp12 - 12'd1;
    // PUSH X ($44) / PUSH Y ($54) push the index register; PHP pushes P|B|U.
    wire [7:0]  push_val = (IR == 8'h08) ? (P | 8'h30) :
                          (IR == 8'h44) ? X : (IR == 8'h54) ? Y : A;

    // ── SP-relative effective address (xt embellishment, §2) ──────────────
    // sp_eff = clamp(SP + sign_extend(di), $000, $FFF).  `di` is the signed
    // 8-bit displacement, available in the cycle after the opcode fetch.  The
    // 14-bit signed sum spans −128..+4222, so clamps (not wraps) at both ends.
    wire signed [13:0] sp_q_s   = { 2'b00, S_high, S };
    wire signed [13:0] sp_d_s   = { {6{di[7]}}, di };
    wire signed [13:0] sp_sum_s = sp_q_s + sp_d_s;
    wire [11:0] sp_eff = (sp_sum_s < 0)         ? 12'h000 :
                         (sp_sum_s > 14'sd4095) ? 12'hFFF : sp_sum_s[11:0];

    // ── PSH/PLL frame arithmetic (§3) — di = N at ST_PSH_CAL/ST_PLL0 ──────
    // frame_size = N + 7 (reg save 6 + 1 guard byte + locals N); PSH subtracts,
    // PLL adds; both clamp at the 12-bit SP boundary.  The guard byte at SP+0
    // (post-PSH) keeps the machine's post-decrement invariant — the next push
    // (PHA/JSR/IRQ) lands on the guard, not the saved-register slots (which sit
    // at SP+1..SP+6).  See docs/Issues/0001-psh-pll-guard-byte.md.
    wire [12:0] psh_sub    = { 1'b0, S_high, S } - { 5'b0, di } - 13'd7;
    wire [11:0] sp_new_psh = psh_sub[12] ? 12'h000 : psh_sub[11:0];          // clamp at $000
    wire [12:0] pll_add    = { 1'b0, S_high, S } + { 5'b0, di } + 13'd7;
    wire [11:0] sp_new_pll = (pll_add > 13'h0FFF) ? 12'hFFF : pll_add[11:0]; // clamp at $FFF
    reg  [11:0] sp_new_q;          // latched post-frame SP (committed at PSH/PLL end)
    reg  [2:0]  frame_idx;         // slot index 0..5 within the frame

    // ── d,SP,X stack address (§2b) — {adh,adl} = latched SP+d, then + X ────
    // Second 2-input add (not 3-input SP+d+X); truncates into the 4 KB stack.
    wire [11:0] spix_addr = { adh[3:0], adl } + { 4'b0, X };

    // ── Hardware interrupt sampling (NMI edge / IRQ level) ────────────────
    // NMI is latched on the high→low edge of nmi_n; IRQ is level-sensitive and
    // masked by I.  A pending interrupt is injected at the DECODE boundary as a
    // BRK-like sequence with B=0 and the vector $FFFA (NMI) / $FFFE (IRQ).
    reg  nmi_n_d;                  // delayed nmi_n for edge detection
    reg  nmi_pending;              // latched NMI edge, cleared on service
    reg  intr_mode;               // 1 = hardware interrupt (push B=0), 0 = BRK (B=1)
    reg  intr_nmi;                // 1 = NMI vector ($FFFA), 0 = IRQ/BRK vector ($FFFE)
    wire nmi_serv = nmi_pending;
    wire irq_serv = ~irq_n & ~P[I_BIT];
    wire do_intr  = nmi_serv | irq_serv;          // recognised only at ST_DECODE

    // ── Microsequencer states ────────────────────────────────────────────
    // ST_JMP_HI MUST stay 7'd7 — tb_xt6502's spin-period guard keys on it.
    localparam [6:0]
        ST_RST_LO = 7'd0,
        ST_RST_HI = 7'd1,
        ST_RST_GO = 7'd2,
        ST_FETCH  = 7'd3,   // present opcode addr; opcode arrives next
        ST_DECODE = 7'd4,   // di = opcode; dispatch
        ST_IMM    = 7'd5,   // di = immediate operand → execute
        ST_JMP_LO = 7'd6,
        ST_JMP_HI = 7'd7,
        ST_ZP     = 7'd8,   // di = zp address byte → EA
        ST_ABS_LO = 7'd9,   // di = abs low byte
        ST_ABS_HI = 7'd10,  // di = abs high byte → EA
        ST_RD     = 7'd11,  // di = memory operand → execute
        ST_ZPX    = 7'd12,  // zp,X/zp,Y: di = base; dummy read {00,base}, +idx
        ST_ZPX2   = 7'd13,  // zp,X/zp,Y: read {00,(base+idx)&FF}
        ST_ZPX_WR = 7'd14,  // zp,X/zp,Y store: write {00,(base+idx)&FF}
        ST_ABX_HI = 7'd15,  // abs,X/Y: di = hi; speculative {hi,lo+idx}
        ST_ABX_FIX= 7'd16,  // abs,X/Y read page-cross / RMW: read {hi+c,lo+idx}
        ST_ABX_WR = 7'd17,  // abs,X/Y store: write {hi(+1),lo+idx}
        ST_INDX   = 7'd20,  // (zp,X): di = base; dummy read, table = base+X
        ST_INDX_LO= 7'd21,  // (zp,X): read ptr lo at {00,base+X}
        ST_INDX_HI= 7'd22,  // (zp,X): read ptr hi; latch ptr lo → ST_ABS_HI
        ST_INDY   = 7'd23,  // (zp),Y: di = IAL; read ptr lo at {00,IAL}
        ST_INDY_LO= 7'd24,  // (zp),Y: read ptr hi; latch ptr lo → ST_ABX_HI
        ST_BRA    = 7'd25,  // branch: di = offset; evaluate condition
        ST_BRA_ADD= 7'd26,  // branch taken: add offset, present target
        ST_BRA_FIX= 7'd27,  // branch page-cross: corrected target
        ST_RMW_RD = 7'd28,  // RMW: di = value; dummy-write old, compute new
        ST_RMW_WR = 7'd29,  // RMW: write modified value
        ST_PUSH   = 7'd30,  // PHA/PHP: write to stack[SP], SP--
        ST_PULL_D = 7'd31,  // PLA/PLP: dummy cycle
        ST_PULL   = 7'd32,  // PLA/PLP: SP++, read stack[SP]
        ST_PULL2  = 7'd33,  // PLA/PLP: di = pulled value → A/P
        // JSR — 6 cycles: fetch ADL; internal; push PCH; push PCL; fetch ADH.
        ST_JSR_INT= 7'd34,  // di = ADL (latch); dummy stack read
        ST_JSR_PCH= 7'd35,  // push PCH (=opcode+2 hi), SP--
        ST_JSR_PCL= 7'd36,  // push PCL, SP--
        ST_JSR_ADH= 7'd37,  // read ADH at opcode+2
        ST_JSR_DONE=7'd38,  // di = ADH; PC = {ADH,ADL}; present opcode fetch
        // RTS — 6 cycles: dummy; dummy stack; pull PCL; pull PCH; +1 fetch.
        ST_RTS_D  = 7'd39,  // dummy stack read at SP
        ST_RTS_PCL= 7'd40,  // present pull PCL (SP+1)
        ST_RTS_PCH= 7'd41,  // di = PCL (latch); present pull PCH (SP+2)
        ST_RTS_INC= 7'd42,  // di = PCH; PC = {PCH,PCL}; dummy read; → ST_FETCH (+1)
        // RTI — 6 cycles: dummy; dummy stack; pull P; pull PCL; pull PCH.
        ST_RTI_D  = 7'd43,  // dummy stack read at SP
        ST_RTI_P  = 7'd44,  // present pull P (SP+1)
        ST_RTI_PCL= 7'd45,  // di = P → P (U=1); present pull PCL (SP+2)
        ST_RTI_PCH= 7'd46,  // di = PCL (latch); present pull PCH (SP+3)
        ST_RTI_FIN= 7'd47,  // di = PCH; PC = {PCH,PCL}; present opcode fetch (no +1)
        // BRK — 7 cycles: padding; push PCH; push PCL; push P|B; vector fetch.
        ST_BRK_PCH= 7'd48,  // push PCH (=opcode+2 hi), SP--
        ST_BRK_PCL= 7'd49,  // push PCL, SP--
        ST_BRK_P  = 7'd50,  // push P|$30, SP--; present $FFFE
        ST_BRK_VL = 7'd51,  // read vector lo at $FFFE; set I; present $FFFF
        ST_BRK_VH = 7'd52,  // di = veclo (latch); read vector hi at $FFFF
        ST_BRK_DONE=7'd53,  // di = vechi; PC = {vechi,veclo}; present opcode fetch
        // JMP indirect ($6C) — 5 cycles, NMOS page-wrap bug.
        ST_JMPI_LO= 7'd54,  // di = IAL (latch); read IAH at opcode+2
        ST_JMPI_HI= 7'd55,  // di = IAH; read target lo at {IAH,IAL}; MAR={IAH,IAL+1}
        ST_JMPI_TL= 7'd56,  // di = target lo (latch); read target hi at {IAH,IAL+1}
        ST_JMPI_DN= 7'd57,  // di = target hi; PC = {hi,lo}; present opcode fetch
        // ── xt embellishments ────────────────────────────────────────────
        ST_SP_RD  = 7'd58,  // d,SP load: di = d → read stack[sp_eff]
        ST_SP_WB  = 7'd59,  // d,SP load: di = stack value → reg/flags; fetch
        ST_SP_WR  = 7'd60,  // d,SP store: di = d → write reg into stack[sp_eff]
        ST_SP_ADJ = 7'd61,  // ADD SP,#imm: di = imm → SP = clamp(SP+imm)
        // PSH/PLL frame ops — single-port stack BRAM.  PSH_CALC registers the
        // frame SP a cycle early (off the BRAM-read→subtract→address chain).
        ST_PSH_CAL= 7'd71,  // di = N → latch sp_new = clamp(SP-(N+6)); no access
        ST_PSH0   = 7'd62,  // write P at sp_new_q+0 (sp_new_q now registered)
        ST_PSH_RUN= 7'd63,  // write SP_lo/SP_hi/Y/X/A at sp_new+idx (idx 1..5)
        ST_PLL0   = 7'd64,  // di = N → latch sp_new; present read of slot 0
        ST_PLL_RUN= 7'd65,  // present read slot idx; consume previous (P/.../X)
        ST_PLL_FIN= 7'd66,  // consume slot 5 (A); commit SP; fetch
        // SP-indirect / indexed ($x3, §2b).
        ST_SP_CALC= 7'd67,  // all SP-mem ops: di = d → register sp_eff into {adh,adl}
        ST_SPIX2  = 7'd68,  // d,SP,X: stack access at (SP+d)+X
        ST_SPIY   = 7'd69,  // (d,SP),Y: read ptr lo at stack[{adh,adl}]
        ST_SPIY2  = 7'd70;  // (d,SP),Y: read ptr hi at stack[{adh,adl}+1] → ST_ABX_HI
    reg  [6:0]  state;

    // ── Combinational next-state / bus control ───────────────────────────
    reg  [15:0] mar_nxt;
    reg  [6:0]  state_nxt;
    reg  [15:0] pc_nxt;
    reg         use_ea;
    reg  [15:0] ea;
    reg         wr_cycle;           // this cycle drives a write
    reg  [7:0]  wr_data;
    reg         stk_cycle;          // this cycle accesses the hidden stack
    reg  [11:0] stk_addr;

    always @* begin
        mar_nxt   = MAR;
        state_nxt = state;
        pc_nxt    = PC;
        use_ea    = 1'b0;
        ea        = 16'h0000;
        wr_cycle  = 1'b0;
        wr_data   = store_src;
        stk_cycle = 1'b0;
        stk_addr  = 12'h000;

        case (state)
            ST_RST_LO: begin mar_nxt = VEC_RESET + 16'd1; state_nxt = ST_RST_HI; end
            ST_RST_HI: begin mar_nxt = VEC_RESET + 16'd1; state_nxt = ST_RST_GO; end
            ST_RST_GO: begin
                pc_nxt    = { di, pcl_q };
                mar_nxt   = { di, pcl_q };
                state_nxt = ST_FETCH;
            end

            ST_FETCH: begin                         // present opcode addr (= PC)
                mar_nxt   = PC + 16'd1;
                pc_nxt    = PC + 16'd1;
                state_nxt = ST_DECODE;
            end

            ST_DECODE: if (do_intr) begin           // hardware IRQ/NMI: inject BRK-like
                // Discard the fetched opcode; push the address of the NOT-executed
                // instruction (PC-1) so RTI resumes there.  B=0, vector chosen in
                // ST_BRK_P/VL by intr_nmi (latched in the seq block).
                mar_nxt = PC; pc_nxt = PC - 16'd1; state_nxt = ST_BRK_PCH;
            end else begin                          // di = opcode; addr = PC
                case (di)
                    8'hEA: begin mar_nxt = PC;        pc_nxt = PC;        state_nxt = ST_FETCH;    end // NOP
                    8'h4C: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_JMP_LO;  end // JMP abs
                    8'h6C: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_JMPI_LO; end // JMP (ind)
                    8'h20: begin mar_nxt = PC;        pc_nxt = PC + 16'd1; state_nxt = ST_JSR_INT;  end // JSR
                    8'h60: begin mar_nxt = PC;        pc_nxt = PC;         state_nxt = ST_RTS_D;    end // RTS
                    8'h40: begin mar_nxt = PC;        pc_nxt = PC;         state_nxt = ST_RTI_D;    end // RTI
                    8'h00: begin mar_nxt = PC;        pc_nxt = PC + 16'd1; state_nxt = ST_BRK_PCH;  end // BRK
                    8'h48, 8'h08: begin mar_nxt = PC; pc_nxt = PC;         state_nxt = ST_PUSH;     end // PHA/PHP
                    8'h68, 8'h28: begin mar_nxt = PC; pc_nxt = PC;         state_nxt = ST_PULL_D;   end // PLA/PLP
                    // ── xt embellishments ────────────────────────────────
                    8'h44, 8'h54: begin mar_nxt = PC; pc_nxt = PC;         state_nxt = ST_PUSH;     end // PUSH X/Y
                    8'h64, 8'h74: begin mar_nxt = PC; pc_nxt = PC;         state_nxt = ST_PULL_D;   end // POP X/Y
                    8'h80: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_BRA;     end // BRA #imm
                    8'h89: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_IMM;     end // BIT #imm
                    // All SP-memory ops register sp_eff into {adh,adl} in
                    // ST_SP_CALC first (off the BRAM-read→sp_eff→stack-addr chain),
                    // then access from the register.  ADD SP ($22) has no memory
                    // access so it stays direct.
                    8'h02, 8'h12, 8'h92,                                                                 // STX/STY/STA d,SP
                    8'h42, 8'h52, 8'h72, 8'hB2, 8'hD2, 8'hF2,                                            // LDX/LDY/ADC/LDA/CMP/SBC d,SP
                    8'h23, 8'h33,                                                                        // LDA/STA d,SP,X
                    8'h03, 8'h13:                                                                        // LDA/STA (d,SP),Y
                           begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_SP_CALC; end
                    8'h22: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_SP_ADJ;  end // ADD SP,#imm
                    8'h32: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_PSH_CAL; end // PSH #N
                    8'h62: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_PLL0;    end // PLL #N
                    default: begin
                        if (di[4:0] == 5'b10000) begin // conditional branch (BPL..BEQ)
                            mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_BRA;
                        end
                        else if (di[1:0] == 2'b01) begin    // cc=01 ALU/LDA/STA group
                            mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1;
                            case (di[4:2])
                                3'b010: state_nxt = ST_IMM;     // #imm
                                3'b001: state_nxt = ST_ZP;      // zp
                                3'b011: state_nxt = ST_ABS_LO;  // abs
                                3'b101: state_nxt = ST_ZPX;     // zp,X
                                3'b110,                         // abs,Y
                                3'b111: state_nxt = ST_ABS_LO;  // abs,X
                                3'b000: state_nxt = ST_INDX;    // (zp,X)
                                3'b100: state_nxt = ST_INDY;    // (zp),Y
                                default:state_nxt = ST_FETCH;
                            endcase
                        end
                        else if (di[1:0] == 2'b10) begin    // cc=10 shifts/RMW + STX/LDX
                            case (di[4:2])
                                3'b000: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_IMM;    end // LDX #imm
                                3'b001: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ZP;     end // zp
                                3'b011: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ABS_LO; end // abs
                                3'b101: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ZPX;    end // zp,X / zp,Y
                                3'b111: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ABS_LO; end // abs,X / abs,Y
                                default:begin mar_nxt = PC;         pc_nxt = PC;         state_nxt = ST_FETCH;  end // accumulator / TXS / TSX / implied
                            endcase
                        end
                        else begin                          // cc=00 LDY/STY/CPX/CPY/BIT (+ implied → FETCH)
                            case (di[4:2])
                                3'b000: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_IMM;    end // LDY#/CPY#/CPX#
                                3'b001: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ZP;     end // zp
                                3'b011: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ABS_LO; end // abs
                                3'b101: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ZPX;    end // zp,X
                                3'b111: begin mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_ABS_LO; end // abs,X (LDY)
                                default:begin mar_nxt = PC;         pc_nxt = PC;         state_nxt = ST_FETCH;  end // implied (flags/transfers)
                            endcase
                        end
                    end
                endcase
            end

            ST_IMM: begin                           // di = immediate → execute (seq)
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            ST_JMP_LO: begin
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JMP_HI;
            end
            ST_JMP_HI: begin
                use_ea    = 1'b1; ea = { di, adl };
                pc_nxt    = { di, adl } + 16'd1;
                mar_nxt   = { di, adl } + 16'd1;
                state_nxt = ST_DECODE;
            end

            ST_ZP: begin                            // di = zp addr → EA = {00,di}
                use_ea = 1'b1; ea = { 8'h00, di };
                mar_nxt = PC; pc_nxt = PC;
                if (is_store) begin                 // ST*: write src, then fetch
                    wr_cycle = 1'b1; state_nxt = ST_FETCH;
                end else if (op_is_rmw) begin       // INC/DEC/shift zp: read → modify → write
                    state_nxt = ST_RMW_RD;          // adl<=di, adh<=0 (seq)
                end else begin                      // read: operand arrives in ST_RD
                    state_nxt = ST_RD;
                end
            end

            ST_ABS_LO: begin                        // di = low byte (latched seq)
                mar_nxt = PC; pc_nxt = PC + 16'd1;
                state_nxt = (ir_bbb == 3'b011) ? ST_ABS_HI : ST_ABX_HI;
            end
            ST_ABS_HI: begin                        // di = high byte → EA = {di,adl}
                use_ea = 1'b1; ea = { di, adl };
                mar_nxt = PC; pc_nxt = PC;
                if (is_store) begin                 // ST* abs: write src, then fetch
                    wr_cycle = 1'b1; state_nxt = ST_FETCH;
                end else if (op_is_rmw) begin       // INC/DEC/shift abs: read → modify → write
                    state_nxt = ST_RMW_RD;          // adh<=di (seq); adl already = lo
                end else begin
                    state_nxt = ST_RD;
                end
            end

            // zp,X / zp,Y — 4 cycles: dummy read at {00,base}, then {00,(base+idx)&FF}.
            ST_ZPX: begin                           // di = base; adl <= base+idx (seq)
                use_ea = 1'b1; ea = { 8'h00, di };  // dummy read at base
                mar_nxt = PC; pc_nxt = PC;
                state_nxt = is_store ? ST_ZPX_WR : ST_ZPX2;
            end
            ST_ZPX2: begin                          // read {00, base+idx}
                use_ea = 1'b1; ea = { 8'h00, adl };
                mar_nxt = PC; pc_nxt = PC;
                state_nxt = op_is_rmw ? ST_RMW_RD : ST_RD;
            end
            ST_ZPX_WR: begin                        // store {00, base+idx}
                use_ea = 1'b1; ea = { 8'h00, adl };
                wr_cycle = 1'b1;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_FETCH;
            end

            // abs,X / abs,Y — speculative {hi, lo+idx}; +1 cycle on page cross;
            // RMW always takes the corrected-address read (no shortcut).
            ST_ABX_HI: begin                        // di = hi; adl<=lo+idx, adh<=hi+carry (seq)
                use_ea = 1'b1; ea = { di, abx_sum[7:0] };
                mar_nxt = PC; pc_nxt = PC;
                if (is_store)        state_nxt = ST_ABX_WR;          // store: dummy read here, write next
                else if (op_is_rmw)  state_nxt = ST_ABX_FIX;         // RMW: corrected read then modify
                else if (abx_sum[8]) state_nxt = ST_ABX_FIX;         // read + page cross
                else                 state_nxt = ST_RD;              // read, no cross
            end
            ST_ABX_FIX: begin                       // corrected high page
                use_ea = 1'b1; ea = { adh, adl };
                mar_nxt = PC; pc_nxt = PC;
                state_nxt = op_is_rmw ? ST_RMW_RD : ST_RD;
            end
            ST_ABX_WR: begin                        // store at corrected {adh,adl}
                use_ea = 1'b1; ea = { adh, adl };
                wr_cycle = 1'b1;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_FETCH;
            end

            ST_RD: begin                            // di = memory operand → execute
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            // (zp,X): dummy read at {00,base}; pointer table at {00,(base+X)&FF}.
            ST_INDX: begin                          // di = base; adl <= base+X (seq)
                use_ea  = 1'b1; ea = { 8'h00, di };           // dummy read at base
                mar_nxt = { 8'h00, zpx_low };                 // ptr-lo addr
                pc_nxt  = PC; state_nxt = ST_INDX_LO;
            end
            ST_INDX_LO: begin                       // addr=MAR={00,base+X}: read ptr lo
                mar_nxt = { 8'h00, adl + 8'd1 };              // ptr-hi addr (zp wrap)
                pc_nxt  = PC; state_nxt = ST_INDX_HI;
            end
            ST_INDX_HI: begin                       // di = ptr lo (latched seq); read ptr hi
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_ABS_HI;  // → {ptr_hi,ptr_lo}
            end

            // (zp),Y: read ptr lo at {00,IAL}, ptr hi at {00,IAL+1}, then +Y
            // (page-cross handled by reusing ST_ABX_HI/FIX/WR with idx=Y).
            ST_INDY: begin                          // di = IAL
                use_ea  = 1'b1; ea = { 8'h00, di };           // ptr-lo read
                mar_nxt = { 8'h00, di + 8'd1 };               // ptr-hi addr
                pc_nxt  = PC; state_nxt = ST_INDY_LO;
            end
            ST_INDY_LO: begin                       // di = ptr lo (latched seq); read ptr hi
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_ABX_HI;  // {ptr_hi, ptr_lo}+Y
            end

            // Conditional branch: di = signed offset.  Not taken = 2 cycles;
            // taken = 3 (+1 on page cross).  PC here = instr+2 (next opcode).
            ST_BRA: begin
                if (br_taken) begin                 // latch adl<=offset (seq); add next cycle
                    mar_nxt = PC; pc_nxt = PC; state_nxt = ST_BRA_ADD;
                end else begin                      // fall through (next opcode already at MAR)
                    mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
                end
            end
            ST_BRA_ADD: begin                       // present {PCH, PCL+offset}; PC <= target
                use_ea = 1'b1; ea = { PC[15:8], bra_target[7:0] };
                if (bra_cross) begin                 // wrong page: fix next cycle
                    mar_nxt = bra_target; pc_nxt = bra_target; state_nxt = ST_BRA_FIX;
                end else begin                       // target reached
                    mar_nxt = bra_target + 16'd1; pc_nxt = bra_target + 16'd1; state_nxt = ST_DECODE;
                end
            end
            ST_BRA_FIX: begin                       // addr = MAR = corrected target
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            // Read-modify-write: read EA → dummy-write old value → write new.
            ST_RMW_RD: begin                        // di = value; dummy write old, compute new (seq)
                use_ea = 1'b1; ea = { adh, adl };
                wr_cycle = 1'b1; wr_data = di;      // dummy write (original value)
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RMW_WR;
            end
            ST_RMW_WR: begin                        // write modified value
                use_ea = 1'b1; ea = { adh, adl };
                wr_cycle = 1'b1; wr_data = rmw_q;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_FETCH;
            end

            // Stack push (PHA/PHP) — write to stack[SP], SP-- (seq).
            ST_PUSH: begin
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle  = 1'b1; wr_data = push_val;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_FETCH;
            end
            // Stack pull (PLA/PLP) — dummy, then SP++ read, then writeback.
            ST_PULL_D: begin                        // dummy read at current SP
                stk_cycle = 1'b1; stk_addr = sp12;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_PULL;
            end
            ST_PULL: begin                          // SP++ (seq); read stack[SP+1]
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_PULL2;
            end
            ST_PULL2: begin                         // di = pulled value → A/P (seq)
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            // ── JSR ($20) — push opcode+2 (return−1), then jump to {ADH,ADL} ─
            ST_JSR_INT: begin                       // di = ADL (latch); dummy stack read
                stk_cycle = 1'b1; stk_addr = sp12;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JSR_PCH;
            end
            ST_JSR_PCH: begin                       // push PCH at SP; SP-- (seq)
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle = 1'b1; wr_data = PC[15:8];
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JSR_PCL;
            end
            ST_JSR_PCL: begin                       // push PCL at SP; SP-- (seq)
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle = 1'b1; wr_data = PC[7:0];
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JSR_ADH;  // MAR=opcode+2 for ADH
            end
            ST_JSR_ADH: begin                       // read ADH at MAR=opcode+2
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JSR_DONE;
            end
            ST_JSR_DONE: begin                      // di = ADH; PC={ADH,adl}; opcode fetch
                use_ea = 1'b1; ea = { di, adl };
                pc_nxt = { di, adl } + 16'd1; mar_nxt = { di, adl } + 16'd1;
                state_nxt = ST_DECODE;
            end

            // ── RTS ($60) — pull PCL/PCH, resume at pulled+1 ─────────────────
            ST_RTS_D: begin                         // dummy stack read at SP
                stk_cycle = 1'b1; stk_addr = sp12;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTS_PCL;
            end
            ST_RTS_PCL: begin                       // present PCL read at SP+1; SP++ (seq)
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTS_PCH;
            end
            ST_RTS_PCH: begin                       // di = PCL (latch adl); PCH read at SP+2; SP++
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTS_INC;
            end
            ST_RTS_INC: begin                       // di = PCH; PC = {PCH,PCL}+1; dummy read
                use_ea = 1'b1; ea = { di, adl };
                pc_nxt = { di, adl } + 16'd1; mar_nxt = { di, adl } + 16'd1;
                state_nxt = ST_FETCH;
            end

            // ── RTI ($40) — pull P, PCL, PCH; resume at pulled PC (no +1) ────
            ST_RTI_D: begin                         // dummy stack read at SP
                stk_cycle = 1'b1; stk_addr = sp12;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTI_P;
            end
            ST_RTI_P: begin                         // present P read at SP+1; SP++ (seq)
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTI_PCL;
            end
            ST_RTI_PCL: begin                       // di = P → P (seq); PCL read at SP+2; SP++
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTI_PCH;
            end
            ST_RTI_PCH: begin                       // di = PCL (latch adl); PCH read at SP+3; SP++
                stk_cycle = 1'b1; stk_addr = sp12_inc;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_RTI_FIN;
            end
            ST_RTI_FIN: begin                       // di = PCH; PC = {PCH,PCL}; opcode fetch
                use_ea = 1'b1; ea = { di, adl };
                pc_nxt = { di, adl } + 16'd1; mar_nxt = { di, adl } + 16'd1;
                state_nxt = ST_DECODE;
            end

            // ── BRK ($00) — push opcode+2, P|B; vector $FFFE/$FFFF; set I ─────
            ST_BRK_PCH: begin                       // push PCH at SP; SP-- (seq)
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle = 1'b1; wr_data = PC[15:8];
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_BRK_PCL;
            end
            ST_BRK_PCL: begin                       // push PCL at SP; SP-- (seq)
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle = 1'b1; wr_data = PC[7:0];
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_BRK_P;
            end
            ST_BRK_P: begin                         // push P at SP; SP--; present vector lo
                stk_cycle = 1'b1; stk_addr = sp12;
                wr_cycle = 1'b1;
                wr_data = intr_mode ? ((P & 8'hEF) | 8'h20)  // hardware IRQ/NMI: B=0, U=1
                                    : (P | 8'h30);            // BRK: B=1, U=1
                mar_nxt = intr_nmi ? 16'hFFFA : 16'hFFFE; pc_nxt = PC; state_nxt = ST_BRK_VL;
            end
            ST_BRK_VL: begin                        // read vec lo; present vec hi; set I (seq)
                mar_nxt = intr_nmi ? 16'hFFFB : 16'hFFFF; pc_nxt = PC; state_nxt = ST_BRK_VH;
            end
            ST_BRK_VH: begin                        // di = veclo (latch adl); read vec hi at $FFFF
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_BRK_DONE;
            end
            ST_BRK_DONE: begin                      // di = vechi; PC = {vechi,veclo}; opcode fetch
                use_ea = 1'b1; ea = { di, adl };
                pc_nxt = { di, adl } + 16'd1; mar_nxt = { di, adl } + 16'd1;
                state_nxt = ST_DECODE;
            end

            // ── JMP indirect ($6C) — NMOS page-wrap bug on the pointer hi ────
            ST_JMPI_LO: begin                       // di = IAL (latch adl); read IAH at opcode+2
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JMPI_HI;
            end
            ST_JMPI_HI: begin                       // di = IAH; read target lo at {IAH,IAL}
                use_ea = 1'b1; ea = { di, adl };
                mar_nxt = { di, adl + 8'd1 };       // NMOS bug: 8-bit increment of the pointer
                pc_nxt = PC; state_nxt = ST_JMPI_TL;
            end
            ST_JMPI_TL: begin                       // di = target lo (latch pcl_q); read target hi
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_JMPI_DN;
            end
            ST_JMPI_DN: begin                       // di = target hi; PC = {hi,lo}; opcode fetch
                use_ea = 1'b1; ea = { di, pcl_q };
                pc_nxt = { di, pcl_q } + 16'd1; mar_nxt = { di, pcl_q } + 16'd1;
                state_nxt = ST_DECODE;
            end

            // ── SP-relative: register sp_eff into {adh,adl} (ST_SP_CALC), then
            //    access from the register — keeps the BRAM-read→sp_eff(14b add+
            //    clamp)→stack-address chain off the critical path. ──
            ST_SP_CALC: begin                       // di = d → {adh,adl} <= sp_eff (seq); dispatch
                mar_nxt = PC; pc_nxt = PC;
                if (ir_cc == 2'b11)                                   // SP-indirect ($x3)
                    state_nxt = IR[5] ? ST_SPIX2 : ST_SPIY;          // ,X / (),Y
                else                                                  // d,SP scalar ($x2)
                    state_nxt = (IR == 8'h02 || IR == 8'h12 || IR == 8'h92)
                              ? ST_SP_WR : ST_SP_RD;
            end
            ST_SP_RD: begin                         // present stack read at {adh,adl} (= SP+d, reg)
                stk_cycle = 1'b1; stk_addr = { adh[3:0], adl };
                mar_nxt = PC; pc_nxt = PC;          // keep MAR = next-opcode addr
                state_nxt = ST_SP_WB;
            end
            ST_SP_WB: begin                         // di = stack value → reg/flags (seq); fetch
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end
            ST_SP_WR: begin                         // write reg to stack[{adh,adl}]
                stk_cycle = 1'b1; stk_addr = { adh[3:0], adl };
                wr_cycle  = 1'b1;
                wr_data   = (IR == 8'h02) ? X : (IR == 8'h12) ? Y : A;  // STX/STY/STA d,SP
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_FETCH;
            end
            // ── ADD SP,#imm — SP = clamp(SP + imm); next opcode at MAR ─────
            ST_SP_ADJ: begin
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            // ── PSH #N — allocate frame, write P/SP_lo/SP_hi/Y/X/A slots ───
            ST_PSH_CAL: begin                       // di = N; register sp_new (no stack access)
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_PSH0;
            end
            ST_PSH0: begin                          // write P at sp_new_q+1 (guard byte at +0)
                stk_cycle = 1'b1; stk_addr = sp_new_q + 12'd1;
                wr_cycle  = 1'b1; wr_data = P;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_PSH_RUN;
            end
            ST_PSH_RUN: begin                       // write slot frame_idx (1..5) at +2..+6
                stk_cycle = 1'b1; stk_addr = sp_new_q + { 9'b0, frame_idx } + 12'd1;
                wr_cycle  = 1'b1;
                case (frame_idx)
                    3'd1:    wr_data = S;                  // saved SP_lo (entry)
                    3'd2:    wr_data = { 4'h0, S_high };   // saved SP_hi (entry)
                    3'd3:    wr_data = Y;
                    3'd4:    wr_data = X;
                    default: wr_data = A;                  // 3'd5
                endcase
                mar_nxt = PC; pc_nxt = PC;
                state_nxt = (frame_idx == 3'd5) ? ST_FETCH : ST_PSH_RUN;
            end

            // ── PLL #N — read slots back, restore P/Y/X/A, deallocate ──────
            ST_PLL0: begin                          // di = N; present read of P at SP+1 (guard at +0)
                stk_cycle = 1'b1; stk_addr = sp12 + 12'd1;
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_PLL_RUN;
            end
            ST_PLL_RUN: begin                       // present read of slot frame_idx (1..5) at +2..+6
                stk_cycle = 1'b1; stk_addr = sp12 + { 9'b0, frame_idx } + 12'd1;
                mar_nxt = PC; pc_nxt = PC;
                state_nxt = (frame_idx == 3'd5) ? ST_PLL_FIN : ST_PLL_RUN;
            end
            ST_PLL_FIN: begin                       // di = slot 5 (A); commit SP; fetch
                mar_nxt = PC + 16'd1; pc_nxt = PC + 16'd1; state_nxt = ST_DECODE;
            end

            // ── d,SP,X ($23/$33) — stack access at (SP+d)+X (SP+d in {adh,adl}) ─
            ST_SPIX2: begin                         // stack access at spix_addr = {adh,adl}+X
                stk_cycle = 1'b1; stk_addr = spix_addr;
                mar_nxt = PC; pc_nxt = PC;
                if (IR[4]) begin                    // store ($33)
                    wr_cycle = 1'b1; wr_data = A; state_nxt = ST_FETCH;
                end else begin                      // load ($23) → A in ST_SP_WB
                    state_nxt = ST_SP_WB;
                end
            end

            // ── (d,SP),Y ($03/$13) — fetch 16-bit ptr from stack, then ptr+Y ─
            ST_SPIY: begin                          // read ptr lo at stack[{adh,adl}] (= SP+d, reg)
                stk_cycle = 1'b1; stk_addr = { adh[3:0], adl };
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_SPIY2;
            end
            ST_SPIY2: begin                         // di = ptr lo; read ptr hi at sp_eff+1
                stk_cycle = 1'b1;
                stk_addr  = { adh[3:0], adl } + 12'd1;        // adl <= ptr lo (seq)
                mar_nxt = PC; pc_nxt = PC; state_nxt = ST_ABX_HI;  // → {ptr_hi,ptr_lo}+Y (main mem)
            end

            default: state_nxt = ST_FETCH;
        endcase
    end

    // ── Sequential update ────────────────────────────────────────────────
    // Execute (register/flag writeback) happens when the operand is in `di`:
    // ST_IMM (immediate) or ST_RD (memory).  Stores write memory in the
    // addressing state above and do NOT execute here.
    wire exec = (state == ST_IMM) || (state == ST_RD);

    always @(posedge clk) begin
        if (rst) begin
            state  <= ST_RST_LO;
            MAR    <= VEC_RESET;
            PC     <= 16'h0000;
            A      <= 8'h00; X <= 8'h00; Y <= 8'h00;
            S      <= 8'hFF; S_high <= 4'hF;
            P      <= 8'h34;
            IR     <= 8'hEA;
            pcl_q  <= 8'h00; adl <= 8'h00; adh <= 8'h00;
            rmw_q  <= 8'h00;
            nmi_n_d <= 1'b1; nmi_pending <= 1'b0;
            intr_mode <= 1'b0; intr_nmi <= 1'b0;
            sp_new_q <= 12'h000; frame_idx <= 3'd0;
        end
        else if (rdy) begin
            state <= state_nxt;
            MAR   <= mar_nxt;
            PC    <= pc_nxt;

            // NMI edge detect (high→low) + service-clear at the injecting DECODE.
            nmi_n_d <= nmi_n;
            if (nmi_n_d & ~nmi_n)
                nmi_pending <= 1'b1;
            else if (state == ST_DECODE && do_intr && nmi_serv)
                nmi_pending <= 1'b0;

            if (state == ST_RST_HI) pcl_q <= di;
            if (state == ST_DECODE) IR    <= di;
            if (state == ST_ABS_LO) adl   <= di;        // abs/abs,X/Y low byte
            if (state == ST_ABS_HI) adh   <= di;        // abs high byte (for RMW EA)
            if (state == ST_ZP) begin adl <= di; adh <= 8'h00; end  // zp EA (for RMW)
            if (state == ST_JMP_LO) adl   <= di;
            if (state == ST_BRA)    adl   <= di;        // branch offset
            if (state == ST_JSR_INT) adl  <= di;        // JSR: ADL
            if (state == ST_RTS_PCH) adl  <= di;        // RTS: PCL
            if (state == ST_RTI_PCH) adl  <= di;        // RTI: PCL
            if (state == ST_BRK_VH)  adl  <= di;        // BRK: vector low
            if (state == ST_JMPI_LO) adl  <= di;        // JMP(ind): IAL
            if (state == ST_JMPI_TL) pcl_q<= di;        // JMP(ind): target low
            if (state == ST_RMW_RD) begin               // RMW modify: latch result + flags
                rmw_q    <= rmw_sh[7:0];
                P[N_BIT] <= rmw_sh[7];
                P[Z_BIT] <= (rmw_sh[7:0] == 8'h00);
                if (IR[7:5] <= 3'b011) P[C_BIT] <= rmw_sh[8];  // shifts set C; INC/DEC don't
            end

            // 12-bit SP: pushes decrement, pulls increment (carry into S_high).
            if (state == ST_PUSH || state == ST_JSR_PCH || state == ST_JSR_PCL
                || state == ST_BRK_PCH || state == ST_BRK_PCL || state == ST_BRK_P)
                begin S <= sp12_dec[7:0]; S_high <= sp12_dec[11:8]; end
            if (state == ST_PULL || state == ST_RTS_PCL || state == ST_RTS_PCH
                || state == ST_RTI_P || state == ST_RTI_PCL || state == ST_RTI_PCH)
                begin S <= sp12_inc[7:0]; S_high <= sp12_inc[11:8]; end

            if (state == ST_PULL2) begin
                case (IR)
                    8'h68: begin A <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // PLA
                    8'h64: begin X <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // POP X
                    8'h74: begin Y <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // POP Y
                    default: P <= di | 8'h20;           // PLP → P (force U=1)
                endcase
            end
            // SP-relative scalar load writeback (di = stack value).
            if (state == ST_SP_WB) begin
                case (IR)
                    8'hB2: begin A <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // LDA d,SP
                    8'h42: begin X <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // LDX d,SP
                    8'h52: begin Y <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // LDY d,SP
                    8'h72, 8'hF2: begin                                                     // ADC/SBC d,SP
                        A <= alu_r; P[N_BIT] <= alu_n; P[Z_BIT] <= alu_z;
                        P[C_BIT] <= alu_c; P[V_BIT] <= alu_v;
                    end
                    8'hD2: begin P[N_BIT] <= alu_n; P[Z_BIT] <= alu_z; P[C_BIT] <= alu_c; end // CMP d,SP
                    8'h23: begin A <= di; P[N_BIT] <= di[7]; P[Z_BIT] <= di_zero_in; end // LDA d,SP,X
                    default: ;
                endcase
            end
            // ADD SP,#imm — commit clamped 12-bit SP (di = signed imm).
            if (state == ST_SP_ADJ) begin S <= sp_eff[7:0]; S_high <= sp_eff[11:8]; end

            // ── PSH/PLL frame sequencing ───────────────────────────────────
            if (state == ST_DECODE)        frame_idx <= 3'd0;
            else if (state == ST_PSH_CAL)  sp_new_q <= sp_new_psh;   // register frame SP a cycle early
            else if (state == ST_PSH0)     frame_idx <= 3'd1;
            else if (state == ST_PLL0)     begin sp_new_q <= sp_new_pll; frame_idx <= 3'd1; end
            else if (state == ST_PSH_RUN || state == ST_PLL_RUN) frame_idx <= frame_idx + 3'd1;
            // Commit the post-frame SP at the end of PSH (slot A write) / PLL.
            if ((state == ST_PSH_RUN && frame_idx == 3'd5) || state == ST_PLL_FIN)
                begin S <= sp_new_q[7:0]; S_high <= sp_new_q[11:8]; end
            // PLL register restores (data arrives one cycle after presentation):
            // slot0=P at idx1, slot3=Y at idx4, slot4=X at idx5, slot5=A at FIN.
            if (state == ST_PLL_RUN && frame_idx == 3'd1) P <= di | 8'h20;
            if (state == ST_PLL_RUN && frame_idx == 3'd4) Y <= di;
            if (state == ST_PLL_RUN && frame_idx == 3'd5) X <= di;
            if (state == ST_PLL_FIN)                      A <= di;
            if (state == ST_RTI_PCL) P <= di | 8'h20;   // RTI restores P (force U=1)
            if (state == ST_BRK_VL)  P[I_BIT] <= 1'b1;  // BRK sets I after pushing P

            if (state == ST_ZPX) begin adl <= zpx_low; adh <= 8'h00; end  // zp,X/zp,Y: (base+idx)&FF
            if (state == ST_INDX)   adl   <= zpx_low;   // (zp,X): ptr table = base+X
            if (state == ST_INDX_HI)adl   <= di;        // (zp,X): latch ptr lo
            if (state == ST_INDY_LO)adl   <= di;        // (zp),Y: latch ptr lo
            if (state == ST_ABX_HI) begin               // abs,X/Y + (zp),Y: low+carry
                adl <= abx_sum[7:0];
                adh <= di + {7'b0, abx_sum[8]};         // hi + page-cross carry
            end
            // All SP-memory ops: register sp_eff (= SP+d) into {adh,adl} a cycle
            // early so the access states present it from a flop, not from di.
            if (state == ST_SP_CALC)
                begin adl <= sp_eff[7:0]; adh <= { 4'h0, sp_eff[11:8] }; end
            if (state == ST_SPIY2) adl <= di;           // (d,SP),Y: latch ptr lo

            // Latch the interrupt mode/vector at the injecting DECODE so the
            // BRK states pick B=0 + the NMI/IRQ vector; a software BRK ($00)
            // takes the ~do_intr path and latches intr_mode=0 (B=1, $FFFE).
            if (state == ST_DECODE) begin
                intr_mode <= do_intr;
                intr_nmi  <= do_intr & nmi_serv;
            end

            // Implied 2-cycle ops execute in DECODE (di = opcode) — but NOT when
            // an interrupt was injected (the fetched opcode is discarded).
            if (state == ST_DECODE && ~do_intr) begin
                case (di)
                    8'h18: P[C_BIT] <= 1'b0;            // CLC
                    8'h38: P[C_BIT] <= 1'b1;            // SEC
                    8'h58: P[I_BIT] <= 1'b0;            // CLI
                    8'h78: P[I_BIT] <= 1'b1;            // SEI
                    8'hB8: P[V_BIT] <= 1'b0;            // CLV
                    8'hD8: P[D_BIT] <= 1'b0;            // CLD
                    8'hF8: P[D_BIT] <= 1'b1;            // SED
                    8'h9A: S <= X;                      // TXS (no flags, preserves S_high)
                    8'hAA, 8'hBA: begin X <= imp_val; P[N_BIT] <= imp_val[7]; P[Z_BIT] <= (imp_val == 8'h00); end // TAX/TSX
                    8'hE8, 8'hCA: begin X <= imp_val; P[N_BIT] <= imp_val[7]; P[Z_BIT] <= (imp_val == 8'h00); end // INX/DEX
                    8'hA8:        begin Y <= imp_val; P[N_BIT] <= imp_val[7]; P[Z_BIT] <= (imp_val == 8'h00); end // TAY
                    8'hC8, 8'h88: begin Y <= imp_val; P[N_BIT] <= imp_val[7]; P[Z_BIT] <= (imp_val == 8'h00); end // INY/DEY
                    8'h8A, 8'h98: begin A <= imp_val; P[N_BIT] <= imp_val[7]; P[Z_BIT] <= (imp_val == 8'h00); end // TXA/TYA
                    8'h0A, 8'h2A, 8'h4A, 8'h6A: begin   // ASL/ROL/LSR/ROR accumulator
                        A <= acc_sh[7:0]; P[N_BIT] <= acc_sh[7];
                        P[Z_BIT] <= (acc_sh[7:0] == 8'h00); P[C_BIT] <= acc_sh[8];
                    end
                    default: ;
                endcase
            end

            if (exec) begin
                if (IR == 8'h89) begin                  // BIT #imm (65C02): Z=A&M, N=M7, V=M6
                    P[Z_BIT] <= ((A & M) == 8'h00); P[N_BIT] <= M[7]; P[V_BIT] <= M[6];
                end
                else if (IR == 8'h03) begin             // LDA (d,SP),Y → A (main-mem deref)
                    A <= M; P[N_BIT] <= M[7]; P[Z_BIT] <= (M == 8'h00);
                end
                else if (ir_cc == 2'b01) begin          // cc=01 ALU/LDA/STA group
                    case (ir_op)
                        3'b000, 3'b001, 3'b010, 3'b101: begin   // ORA/AND/EOR/LDA
                            A <= alu_r; P[N_BIT] <= alu_n; P[Z_BIT] <= alu_z;
                        end
                        3'b011, 3'b111: begin                   // ADC/SBC
                            A <= alu_r; P[N_BIT] <= alu_n; P[Z_BIT] <= alu_z;
                            P[C_BIT] <= alu_c; P[V_BIT] <= alu_v;
                        end
                        3'b110: begin                           // CMP (flags only)
                            P[N_BIT] <= alu_n; P[Z_BIT] <= alu_z; P[C_BIT] <= alu_c;
                        end
                        default: ;                              // STA: nothing
                    endcase
                end
                else if (is_ldx) begin                          // LDX → X
                    X <= M; P[N_BIT] <= M[7]; P[Z_BIT] <= (M == 8'h00);
                end
                else if (is_ldy) begin                          // LDY → Y
                    Y <= M; P[N_BIT] <= M[7]; P[Z_BIT] <= (M == 8'h00);
                end
                else if (is_cpx) begin                          // CPX (X - M)
                    P[N_BIT] <= cpx_bin[7]; P[Z_BIT] <= (cpx_bin[7:0] == 8'h00); P[C_BIT] <= cpx_bin[8];
                end
                else if (is_cpy) begin                          // CPY (Y - M)
                    P[N_BIT] <= cpy_bin[7]; P[Z_BIT] <= (cpy_bin[7:0] == 8'h00); P[C_BIT] <= cpy_bin[8];
                end
                else if (is_bit) begin                          // BIT: Z=A&M, N=M7, V=M6
                    P[Z_BIT] <= ((A & M) == 8'h00); P[N_BIT] <= M[7]; P[V_BIT] <= M[6];
                end
            end
        end
    end

    // ── Bus outputs ──────────────────────────────────────────────────────
    assign addr     = stk_cycle ? { 4'h0, stk_addr } : (use_ea ? ea : MAR);
    assign rw       = ~wr_cycle;       // 1 = read, 0 = write
    assign data_out = wr_data;
    assign stack_op = stk_cycle;
    assign s_high   = S_high;

    // ── Debug taps: combinational fan-out of architectural state (no added path) ──
    // ST_DECODE is the true once-per-instruction boundary: the core PREFETCHES the
    // next opcode during execution, so ST_FETCH is skipped except after control
    // flow.  At ST_DECODE the opcode has been fetched (PC already incremented past
    // it), so the instruction's address is PC-1 — the debug block subtracts it.
    assign dbg_boundary = (state == ST_DECODE);
    assign dbg_pc       = PC;
    assign dbg_bus_stb  = rdy;              // an access commits when the core is not stalled
    assign dbg_bus_addr = addr;             // the live memory address (MAR / EA / stack)
    assign dbg_bus_rw   = rw;
    assign dbg_a        = A;
    assign dbg_x        = X;
    assign dbg_y        = Y;
    assign dbg_s        = S;
    assign dbg_p        = P;
    assign dbg_shigh    = S_high;

endmodule

`default_nettype wire
