// xt6502f.sv — the fidelity ("single-speed Sally") 6502 core.
//
// Design authority: docs/Design/fidelity-6502.md. A fresh, time-native core (NOT xt6502
// reused): each 6502 MACHINE CYCLE is one window of ~N clk_sally clocks (N = CLK_SALLY_HZ
// / PHI2_HZ ≈ 56 @100MHz), paced by `phi2_tick` from sally_clock. Work is slotted within
// the window (`sub` = clocks since the tick): address early (phi1), data latched at
// SUB_DATA (phi2), architectural commit at SUB_COMMIT (retire) — every path multicycle,
// so the whole core + debug facility close timing with vast slack.
//
// Sequencer = structured addressing-mode FSMs + a small op-ALU (decision 3). Validated
// per-opcode, cycle-exact, against Tom Harte's 65x02 ProcessorTests (sim/tb_xt6502f_harte).
//
// IMPLEMENTED SO FAR (Phase 2, growing): reset; opcode fetch (SYNC); NOP; JMP-abs;
// the full LOAD group LDA/LDX/LDY across imm / zp / zp,X / zp,Y / abs / abs,X / abs,Y /
// (zp,X) / (zp),Y with page-cross dummy reads. Unimplemented opcodes act as NOP (and so
// FAIL the Harte oracle — that's how the backlog is tracked).

`default_nettype none

module xt6502f #(
    parameter int unsigned CLK_SALLY_HZ = 100_000_000,  // clk_sally (max operating point)
    parameter int unsigned PHI2_HZ      = 1_789_773     // emulated phi2: NTSC (PAL 1_773_447)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        phi2_tick,

    output wire [15:0] addr,
    input  wire  [7:0] data_in,
    output wire  [7:0] data_out,
    output wire        rw,           // 1 = read, 0 = write
    input  wire        rdy,          // 1 = run, 0 = halt this cycle (read cycles)
    input  wire        irq_n,        // (Phase 3)
    input  wire        nmi_n,        // (Phase 3)

    output wire        sync,
    output wire [15:0] dbg_pc,
    output wire  [7:0] dbg_a, dbg_x, dbg_y, dbg_s, dbg_p,
    output wire  [7:0] dbg_sub,

    input  wire        dbg_load,     // 1-cycle: seed regs, restart at fetch (harness / debug)
    input  wire [15:0] dbg_pc_in,
    input  wire  [7:0] dbg_a_in, dbg_x_in, dbg_y_in, dbg_s_in, dbg_p_in,

    output reg  [15:0] dbg_cyc_addr, // per-machine-cycle bus capture (cycle-exact validation)
    output reg   [7:0] dbg_cyc_val,
    output reg         dbg_cyc_rw,
    output reg         dbg_cyc_valid
);
    // ---- machine-cycle window ------------------------------------------------------
    localparam int unsigned N          = CLK_SALLY_HZ / PHI2_HZ;
    localparam int unsigned SUB_DATA   = N - 7;   // phi2 read-latch
    localparam int unsigned SUB_COMMIT = N - 3;   // retire / commit

    reg [7:0] sub;
    always @(posedge clk) begin
        if (rst)                        sub <= 8'd0;
        else if (phi2_tick || dbg_load) sub <= 8'd0;
        else                            sub <= sub + 8'd1;
    end
    wire slot_data   = (sub == SUB_DATA[7:0]);
    wire slot_commit = (sub == SUB_COMMIT[7:0]);

    // ---- architectural state -------------------------------------------------------
    reg [15:0] PC;
    reg  [7:0] A, X, Y, S, P;

    // ---- micro-state ---------------------------------------------------------------
    localparam [5:0]
        ST_RST=0, ST_VECL=1, ST_VECH=2, ST_FETCH=3,
        ST_IMPL=4, ST_JMP1=5, ST_JMP2=6,
        ST_IMM=7,                          // immediate: operand = value
        ST_ZPF=8, ST_ZPI=9,                // zero page: fetch addr / (indexed dummy)
        ST_LOAD=10,                        // read [eah,eal] -> value
        ST_ABL=11, ST_ABH=12,              // absolute: fetch adl / adh
        ST_ABX=13, ST_ABXC=14,             // abs,idx read / page-cross fix
        ST_IXF=15, ST_IXP=16, ST_IXA=17, ST_IXB=18,   // (zp,X)
        ST_IYF=19, ST_IYA=20, ST_IYB=21, ST_IYRD=22, ST_IYC=23, // (zp),Y
        ST_STORE=24,                       // write [eah,eal] <- reg (store terminal)
        ST_ACC=25,                         // accumulator RMW (ASL/LSR/ROL/ROR A)
        ST_RMW_RD=26, ST_RMW_W0=27, ST_RMW_W1=28, // memory RMW: read, write-orig, write-mod
        ST_BRA=29, ST_BRA_TK=30, ST_BRA_PG=31;    // relative branch: fetch offset / taken / page-cross
    reg [5:0] state;
    reg [2:0] rst_cnt;
    reg [7:0] ir;
    reg [7:0] eal, eah, ptr, idx, din_r;
    reg [7:0] rmw_val, rmw_mod;  // RMW: value read / modified value
    reg [1:0] dst;       // register selector: 0=A 1=X 2=Y (load target / store src / compare reg)
    reg       has_idx;   // indexed addressing (abs/zp with X/Y)
    reg       pgx;       // page cross pending (indexed abs / (zp),Y)
    reg       is_store;  // writes the register to memory
    reg       is_rmw;    // read-modify-write to memory (double-write)

    // operation applied at the value terminal (read-group ALU + RMW ALU)
    localparam [3:0] OP_LD=0, OP_AND=1, OP_ORA=2, OP_EOR=3, OP_CMP=4, OP_BIT=5, OP_ADC=6, OP_SBC=7,
                     OP_ASL=8, OP_LSR=9, OP_ROL=10, OP_ROR=11, OP_INC=12, OP_DEC=13;
    reg [3:0] op;
    wire [5:0] mem_term = is_rmw ? ST_RMW_RD : is_store ? ST_STORE : ST_LOAD;  // terminal after EA

    // ---- address source for the current cycle --------------------------------------
    reg [15:0] addr_c;
    always @(*) begin
        case (state)
            ST_RST:  addr_c = 16'hFFFF;
            ST_VECL: addr_c = 16'hFFFC;
            ST_VECH: addr_c = 16'hFFFD;
            ST_LOAD, ST_STORE, ST_ZPI, ST_ABX, ST_ABXC, ST_IYRD, ST_IYC,
            ST_RMW_RD, ST_RMW_W0, ST_RMW_W1: addr_c = {eah, eal};
            ST_IXP, ST_IXA, ST_IYA: addr_c = {8'h00, ptr};
            ST_IXB, ST_IYB:         addr_c = {8'h00, ptr + 8'd1};   // zp wrap
            default: addr_c = PC;   // FETCH / IMM / ZPF / ABL / ABH / IXF / IYF / NOP1 / JMPn
        endcase
    end

    assign addr = addr_c;
    assign rw   = (state==ST_STORE || state==ST_RMW_W0 || state==ST_RMW_W1) ? 1'b0 : 1'b1;  // write cycles
    assign data_out = (state==ST_RMW_W0) ? rmw_val :                 // RMW ghost write (original)
                      (state==ST_RMW_W1) ? rmw_mod :                 // RMW final write (modified)
                      (dst==2'd0) ? A : (dst==2'd1) ? X : Y;         // store register
    assign sync = (state == ST_FETCH);
    wire   advance  = slot_commit && rdy;

    // ---- read-group execute: apply `op` to the read value `v`, return to fetch -----
    task automatic exec_op(input [7:0] v);
        reg [7:0] r, res;
        reg [8:0] sum9;      // binary add/sub with carry-out
        reg [7:0] bres; reg bc, bv;
        reg [5:0] al;   reg [9:0] inter; reg dn, dv, dc;   // NMOS decimal ADC
        integer   al_i, a_i;                               // NMOS decimal SBC (signed)
        begin
            case (op)
                OP_LD:  begin case (dst) 2'd0:A<=v; 2'd1:X<=v; 2'd2:Y<=v; default:; endcase
                              P <= {v[7], P[6:2], (v==8'h00), P[0]}; end
                OP_AND: begin res = A & v; A <= res; P <= {res[7], P[6:2], (res==8'h00), P[0]}; end
                OP_ORA: begin res = A | v; A <= res; P <= {res[7], P[6:2], (res==8'h00), P[0]}; end
                OP_EOR: begin res = A ^ v; A <= res; P <= {res[7], P[6:2], (res==8'h00), P[0]}; end
                OP_CMP: begin r = (dst==2'd0) ? A : (dst==2'd1) ? X : Y;    // CMP/CPX/CPY
                              res = r - v;
                              P <= {res[7], P[6:2], (r==v), (r>=v)}; end     // N, Z, C (V untouched)
                OP_BIT: P <= {v[7], v[6], P[5:2], ((A & v)==8'h00), P[0]};   // N=v7, V=v6, Z=(A&M)

                OP_ADC: begin
                    sum9 = {1'b0,A} + {1'b0,v} + {8'd0,P[0]};
                    bres = sum9[7:0];
                    if (P[3]) begin                                          // NMOS decimal (Bruce Clark)
                        al = {2'd0,A[3:0]} + {2'd0,v[3:0]} + {5'd0,P[0]};
                        if (al > 6'h09) al = ((al + 6'h06) & 6'h0F) + 6'h10;
                        inter = {2'd0,A[7:4],4'd0} + {2'd0,v[7:4],4'd0} + {4'd0,al};
                        dn = inter[7];                                       // N, V from the intermediate
                        dv = ((~(A ^ v)) & (A ^ inter[7:0]) & 8'h80) != 8'h00;
                        if (inter > 10'h09F) inter = inter + 10'h060;
                        dc = (inter > 10'h0FF);
                        A <= inter[7:0];
                        P <= {dn, dv, P[5:2], (bres==8'h00), dc};            // Z from the BINARY sum (quirk)
                    end else begin
                        bv = ((~(A ^ v)) & (A ^ bres) & 8'h80) != 8'h00;
                        A <= bres;
                        P <= {bres[7], bv, P[5:2], (bres==8'h00), sum9[8]};
                    end
                end
                OP_SBC: begin
                    sum9 = {1'b0,A} + {1'b0,~v} + {8'd0,P[0]};               // A + ~M + C
                    bres = sum9[7:0]; bc = sum9[8];
                    bv   = ((A ^ v) & (A ^ bres) & 8'h80) != 8'h00;
                    if (P[3]) begin                                          // NMOS decimal: A adjusted, flags = BINARY
                        al_i = (A & 'h0F) - (v & 'h0F) + P[0] - 1;
                        if (al_i < 0) al_i = ((al_i - 6) & 'h0F) - 'h10;
                        a_i  = (A & 'hF0) - (v & 'hF0) + al_i;
                        if (a_i < 0) a_i = a_i - 'h60;
                        A <= a_i[7:0];
                        P <= {bres[7], bv, P[5:2], (bres==8'h00), bc};
                    end else begin
                        A <= bres;
                        P <= {bres[7], bv, P[5:2], (bres==8'h00), bc};
                    end
                end
                default: ;
            endcase
            state <= ST_FETCH;
        end
    endtask

    // ---- RMW ALU: modify `v`, set N/Z(/C); to A (accumulator form) or rmw_mod (memory) ----
    task automatic exec_rmw(input [7:0] v, input to_a);
        reg [7:0] m; reg c;
        begin
            case (op)
                OP_ASL: begin m = {v[6:0], 1'b0};  c = v[7];  end
                OP_LSR: begin m = {1'b0, v[7:1]};  c = v[0];  end
                OP_ROL: begin m = {v[6:0], P[0]};  c = v[7];  end
                OP_ROR: begin m = {P[0], v[7:1]};  c = v[0];  end
                OP_INC: begin m = v + 8'd1;        c = P[0];  end   // C unchanged
                OP_DEC: begin m = v - 8'd1;        c = P[0];  end   // C unchanged
                default:begin m = v;               c = P[0];  end
            endcase
            if (to_a) A <= m; else rmw_mod <= m;
            P <= {m[7], P[6:2], (m==8'h00), c};                     // N, Z, C
        end
    endtask

    // ---- implied 2-cycle ops (register transfer / inc-dec / flag), keyed by opcode ----
    task automatic exec_impl;
        reg [7:0] t;
        begin
            case (ir)
                8'hAA: begin X<=A; P<={A[7], P[6:2], (A==8'h00), P[0]}; end   // TAX
                8'hA8: begin Y<=A; P<={A[7], P[6:2], (A==8'h00), P[0]}; end   // TAY
                8'h8A: begin A<=X; P<={X[7], P[6:2], (X==8'h00), P[0]}; end   // TXA
                8'h98: begin A<=Y; P<={Y[7], P[6:2], (Y==8'h00), P[0]}; end   // TYA
                8'hBA: begin X<=S; P<={S[7], P[6:2], (S==8'h00), P[0]}; end   // TSX
                8'h9A: S<=X;                                                  // TXS (no flags)
                8'hE8: begin t=X+8'd1; X<=t; P<={t[7], P[6:2], (t==8'h00), P[0]}; end  // INX
                8'hC8: begin t=Y+8'd1; Y<=t; P<={t[7], P[6:2], (t==8'h00), P[0]}; end  // INY
                8'hCA: begin t=X-8'd1; X<=t; P<={t[7], P[6:2], (t==8'h00), P[0]}; end  // DEX
                8'h88: begin t=Y-8'd1; Y<=t; P<={t[7], P[6:2], (t==8'h00), P[0]}; end  // DEY
                8'h18: P[0]<=1'b0;   8'h38: P[0]<=1'b1;    // CLC / SEC
                8'h58: P[2]<=1'b0;   8'h78: P[2]<=1'b1;    // CLI / SEI
                8'hD8: P[3]<=1'b0;   8'hF8: P[3]<=1'b1;    // CLD / SED
                8'hB8: P[6]<=1'b0;                         // CLV
                default: ;                                 // NOP / unimplemented
            endcase
        end
    endtask

    // page-cross add of an index to eal: {carry, low}
    wire [8:0] eal_plus_idx = {1'b0, eal} + {1'b0, idx};
    wire [8:0] eal_plus_y   = {1'b0, eal} + {1'b0, Y};
    // branch target = PC(opcode+2) + sign-extended offset (latched in eal)
    wire [15:0] bra_sum = PC + {{8{eal[7]}}, eal};

    // ---- data latch (phi2 read slot) -----------------------------------------------
    always @(posedge clk) if (slot_data) din_r <= data_in;

    // ---- FSM + commit (retire slot) ------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_RST; rst_cnt <= 3'd5; PC <= 16'hFFFC;
            A <= 0; X <= 0; Y <= 0; S <= 8'hFD; P <= 8'h34;
            ir <= 8'hEA; eal <= 0; eah <= 0; ptr <= 0; idx <= 0; din_r <= 0;
            dst <= 0; has_idx <= 0; pgx <= 0; is_store <= 0; is_rmw <= 0; op <= OP_LD;
            rmw_val <= 0; rmw_mod <= 0;
        end else if (dbg_load) begin
            PC <= dbg_pc_in; A <= dbg_a_in; X <= dbg_x_in; Y <= dbg_y_in;
            S <= dbg_s_in; P <= dbg_p_in; state <= ST_FETCH; ir <= 8'hEA;
        end else if (advance) begin
            case (state)
                ST_RST:   if (rst_cnt == 0) state <= ST_VECL; else rst_cnt <= rst_cnt - 3'd1;
                ST_VECL:  begin PC[7:0]  <= din_r; state <= ST_VECH; end
                ST_VECH:  begin PC[15:8] <= din_r; state <= ST_FETCH; end

                ST_FETCH: begin
                    ir <= din_r; PC <= PC + 16'd1;
                    has_idx <= 1'b0; pgx <= 1'b0; is_store <= 1'b0; is_rmw <= 1'b0; op <= OP_LD;
                    case (din_r)
                        // ---- immediate loads ----
                        8'hA9: begin dst <= 2'd0; state <= ST_IMM; end          // LDA #
                        8'hA2: begin dst <= 2'd1; state <= ST_IMM; end          // LDX #
                        8'hA0: begin dst <= 2'd2; state <= ST_IMM; end          // LDY #
                        // ---- zero page ----
                        8'hA5: begin dst<=2'd0; eah<=0; state<=ST_ZPF; end      // LDA zp
                        8'hA6: begin dst<=2'd1; eah<=0; state<=ST_ZPF; end      // LDX zp
                        8'hA4: begin dst<=2'd2; eah<=0; state<=ST_ZPF; end      // LDY zp
                        // ---- zero page,X / zero page,Y ----
                        8'hB5: begin dst<=2'd0; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end // LDA zp,X
                        8'hB4: begin dst<=2'd2; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end // LDY zp,X
                        8'hB6: begin dst<=2'd1; eah<=0; idx<=Y; has_idx<=1; state<=ST_ZPF; end // LDX zp,Y
                        // ---- absolute ----
                        8'hAD: begin dst<=2'd0; state<=ST_ABL; end              // LDA abs
                        8'hAE: begin dst<=2'd1; state<=ST_ABL; end              // LDX abs
                        8'hAC: begin dst<=2'd2; state<=ST_ABL; end              // LDY abs
                        // ---- absolute,X / absolute,Y ----
                        8'hBD: begin dst<=2'd0; idx<=X; has_idx<=1; state<=ST_ABL; end // LDA abs,X
                        8'hBC: begin dst<=2'd2; idx<=X; has_idx<=1; state<=ST_ABL; end // LDY abs,X
                        8'hB9: begin dst<=2'd0; idx<=Y; has_idx<=1; state<=ST_ABL; end // LDA abs,Y
                        8'hBE: begin dst<=2'd1; idx<=Y; has_idx<=1; state<=ST_ABL; end // LDX abs,Y
                        // ---- (indirect,X) / (indirect),Y ----
                        8'hA1: begin dst<=2'd0; state<=ST_IXF; end              // LDA (zp,X)
                        8'hB1: begin dst<=2'd0; state<=ST_IYF; end              // LDA (zp),Y
                        // ---- stores (indexed always takes the dummy-read cycle: no page-cross early-out) ----
                        8'h85: begin dst<=2'd0; is_store<=1; eah<=0; state<=ST_ZPF; end            // STA zp
                        8'h86: begin dst<=2'd1; is_store<=1; eah<=0; state<=ST_ZPF; end            // STX zp
                        8'h84: begin dst<=2'd2; is_store<=1; eah<=0; state<=ST_ZPF; end            // STY zp
                        8'h95: begin dst<=2'd0; is_store<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end // STA zp,X
                        8'h94: begin dst<=2'd2; is_store<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end // STY zp,X
                        8'h96: begin dst<=2'd1; is_store<=1; eah<=0; idx<=Y; has_idx<=1; state<=ST_ZPF; end // STX zp,Y
                        8'h8D: begin dst<=2'd0; is_store<=1; state<=ST_ABL; end                    // STA abs
                        8'h8E: begin dst<=2'd1; is_store<=1; state<=ST_ABL; end                    // STX abs
                        8'h8C: begin dst<=2'd2; is_store<=1; state<=ST_ABL; end                    // STY abs
                        8'h9D: begin dst<=2'd0; is_store<=1; idx<=X; has_idx<=1; state<=ST_ABL; end // STA abs,X
                        8'h99: begin dst<=2'd0; is_store<=1; idx<=Y; has_idx<=1; state<=ST_ABL; end // STA abs,Y
                        8'h81: begin dst<=2'd0; is_store<=1; state<=ST_IXF; end                    // STA (zp,X)
                        8'h91: begin dst<=2'd0; is_store<=1; state<=ST_IYF; end                    // STA (zp),Y
                        // ---- AND ----
                        8'h29: begin op<=OP_AND; state<=ST_IMM; end
                        8'h25: begin op<=OP_AND; eah<=0; state<=ST_ZPF; end
                        8'h35: begin op<=OP_AND; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h2D: begin op<=OP_AND; state<=ST_ABL; end
                        8'h3D: begin op<=OP_AND; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h39: begin op<=OP_AND; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'h21: begin op<=OP_AND; state<=ST_IXF; end
                        8'h31: begin op<=OP_AND; state<=ST_IYF; end
                        // ---- ORA ----
                        8'h09: begin op<=OP_ORA; state<=ST_IMM; end
                        8'h05: begin op<=OP_ORA; eah<=0; state<=ST_ZPF; end
                        8'h15: begin op<=OP_ORA; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h0D: begin op<=OP_ORA; state<=ST_ABL; end
                        8'h1D: begin op<=OP_ORA; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h19: begin op<=OP_ORA; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'h01: begin op<=OP_ORA; state<=ST_IXF; end
                        8'h11: begin op<=OP_ORA; state<=ST_IYF; end
                        // ---- EOR ----
                        8'h49: begin op<=OP_EOR; state<=ST_IMM; end
                        8'h45: begin op<=OP_EOR; eah<=0; state<=ST_ZPF; end
                        8'h55: begin op<=OP_EOR; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h4D: begin op<=OP_EOR; state<=ST_ABL; end
                        8'h5D: begin op<=OP_EOR; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h59: begin op<=OP_EOR; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'h41: begin op<=OP_EOR; state<=ST_IXF; end
                        8'h51: begin op<=OP_EOR; state<=ST_IYF; end
                        // ---- CMP (A) ----
                        8'hC9: begin op<=OP_CMP; dst<=2'd0; state<=ST_IMM; end
                        8'hC5: begin op<=OP_CMP; dst<=2'd0; eah<=0; state<=ST_ZPF; end
                        8'hD5: begin op<=OP_CMP; dst<=2'd0; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'hCD: begin op<=OP_CMP; dst<=2'd0; state<=ST_ABL; end
                        8'hDD: begin op<=OP_CMP; dst<=2'd0; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'hD9: begin op<=OP_CMP; dst<=2'd0; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'hC1: begin op<=OP_CMP; dst<=2'd0; state<=ST_IXF; end
                        8'hD1: begin op<=OP_CMP; dst<=2'd0; state<=ST_IYF; end
                        // ---- CPX / CPY (imm/zp/abs) ----
                        8'hE0: begin op<=OP_CMP; dst<=2'd1; state<=ST_IMM; end
                        8'hE4: begin op<=OP_CMP; dst<=2'd1; eah<=0; state<=ST_ZPF; end
                        8'hEC: begin op<=OP_CMP; dst<=2'd1; state<=ST_ABL; end
                        8'hC0: begin op<=OP_CMP; dst<=2'd2; state<=ST_IMM; end
                        8'hC4: begin op<=OP_CMP; dst<=2'd2; eah<=0; state<=ST_ZPF; end
                        8'hCC: begin op<=OP_CMP; dst<=2'd2; state<=ST_ABL; end
                        // ---- BIT (zp/abs) ----
                        8'h24: begin op<=OP_BIT; eah<=0; state<=ST_ZPF; end
                        8'h2C: begin op<=OP_BIT; state<=ST_ABL; end
                        // ---- ADC ----
                        8'h69: begin op<=OP_ADC; state<=ST_IMM; end
                        8'h65: begin op<=OP_ADC; eah<=0; state<=ST_ZPF; end
                        8'h75: begin op<=OP_ADC; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h6D: begin op<=OP_ADC; state<=ST_ABL; end
                        8'h7D: begin op<=OP_ADC; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h79: begin op<=OP_ADC; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'h61: begin op<=OP_ADC; state<=ST_IXF; end
                        8'h71: begin op<=OP_ADC; state<=ST_IYF; end
                        // ---- SBC ----
                        8'hE9: begin op<=OP_SBC; state<=ST_IMM; end
                        8'hE5: begin op<=OP_SBC; eah<=0; state<=ST_ZPF; end
                        8'hF5: begin op<=OP_SBC; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'hED: begin op<=OP_SBC; state<=ST_ABL; end
                        8'hFD: begin op<=OP_SBC; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'hF9: begin op<=OP_SBC; idx<=Y; has_idx<=1; state<=ST_ABL; end
                        8'hE1: begin op<=OP_SBC; state<=ST_IXF; end
                        8'hF1: begin op<=OP_SBC; state<=ST_IYF; end
                        // ---- ASL / LSR / ROL / ROR : accumulator + memory RMW ----
                        8'h0A: begin op<=OP_ASL; state<=ST_ACC; end
                        8'h4A: begin op<=OP_LSR; state<=ST_ACC; end
                        8'h2A: begin op<=OP_ROL; state<=ST_ACC; end
                        8'h6A: begin op<=OP_ROR; state<=ST_ACC; end
                        8'h06: begin op<=OP_ASL; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'h16: begin op<=OP_ASL; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h0E: begin op<=OP_ASL; is_rmw<=1; state<=ST_ABL; end
                        8'h1E: begin op<=OP_ASL; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h46: begin op<=OP_LSR; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'h56: begin op<=OP_LSR; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h4E: begin op<=OP_LSR; is_rmw<=1; state<=ST_ABL; end
                        8'h5E: begin op<=OP_LSR; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h26: begin op<=OP_ROL; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'h36: begin op<=OP_ROL; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h2E: begin op<=OP_ROL; is_rmw<=1; state<=ST_ABL; end
                        8'h3E: begin op<=OP_ROL; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'h66: begin op<=OP_ROR; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'h76: begin op<=OP_ROR; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'h6E: begin op<=OP_ROR; is_rmw<=1; state<=ST_ABL; end
                        8'h7E: begin op<=OP_ROR; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        // ---- INC / DEC (memory RMW) ----
                        8'hE6: begin op<=OP_INC; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'hF6: begin op<=OP_INC; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'hEE: begin op<=OP_INC; is_rmw<=1; state<=ST_ABL; end
                        8'hFE: begin op<=OP_INC; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        8'hC6: begin op<=OP_DEC; is_rmw<=1; eah<=0; state<=ST_ZPF; end
                        8'hD6: begin op<=OP_DEC; is_rmw<=1; eah<=0; idx<=X; has_idx<=1; state<=ST_ZPF; end
                        8'hCE: begin op<=OP_DEC; is_rmw<=1; state<=ST_ABL; end
                        8'hDE: begin op<=OP_DEC; is_rmw<=1; idx<=X; has_idx<=1; state<=ST_ABL; end
                        // ---- implied 2-cycle: transfers / inc-dec reg / flags (exec_impl keys on ir) ----
                        8'hAA, 8'hA8, 8'h8A, 8'h98, 8'hBA, 8'h9A,     // TAX TAY TXA TYA TSX TXS
                        8'hE8, 8'hC8, 8'hCA, 8'h88,                   // INX INY DEX DEY
                        8'h18, 8'h38, 8'h58, 8'h78, 8'hD8, 8'hF8, 8'hB8:  // CLC SEC CLI SEI CLD SED CLV
                                 state <= ST_IMPL;
                        // ---- branches (relative) ----
                        8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0: state <= ST_BRA;
                        // ---- control / nop ----
                        8'h4C: state <= ST_JMP1;                                // JMP abs
                        8'hEA: state <= ST_IMPL;                                // NOP
                        default: state <= ST_IMPL;                              // unimpl -> NOP (fails Harte)
                    endcase
                end

                // immediate
                ST_IMM:  begin PC <= PC + 16'd1; exec_op(din_r); end

                // zero page
                ST_ZPF:  begin eal <= din_r; PC <= PC + 16'd1;
                               state <= has_idx ? ST_ZPI : mem_term; end
                ST_ZPI:  begin eal <= eal + idx; state <= mem_term; end  // dummy read [00,eal]; +idx (zp wrap)

                // absolute
                ST_ABL:  begin eal <= din_r; PC <= PC + 16'd1; state <= ST_ABH; end
                ST_ABH:  begin eah <= din_r; PC <= PC + 16'd1;
                               if (has_idx) begin eal <= eal_plus_idx[7:0]; pgx <= eal_plus_idx[8]; state <= ST_ABX; end
                               else state <= mem_term; end
                ST_ABX:  begin if (is_store || is_rmw) begin eah <= eah + {7'd0, pgx}; state <= is_rmw ? ST_RMW_RD : ST_STORE; end  // dummy; fix; write-terminal
                               else if (pgx) begin eah <= eah + 8'd1; state <= ST_ABXC; end
                               else exec_op(din_r); end                       // load, no cross: value here
                ST_ABXC: exec_op(din_r);                                      // load, page-cross fixed read

                // (indirect,X)
                ST_IXF:  begin ptr <= din_r; PC <= PC + 16'd1; state <= ST_IXP; end
                ST_IXP:  begin ptr <= ptr + X; state <= ST_IXA; end             // dummy read [00,ptr]; ptr+=X
                ST_IXA:  begin eal <= din_r; state <= ST_IXB; end               // [00,ptr]   -> adl
                ST_IXB:  begin eah <= din_r; state <= mem_term; end   // [00,ptr+1] -> adh

                // (indirect),Y
                ST_IYF:  begin ptr <= din_r; PC <= PC + 16'd1; state <= ST_IYA; end
                ST_IYA:  begin eal <= din_r; state <= ST_IYB; end               // [00,ptr]   -> adl
                ST_IYB:  begin eah <= din_r; eal <= eal_plus_y[7:0]; pgx <= eal_plus_y[8]; state <= ST_IYRD; end
                ST_IYRD: begin if (is_store) begin eah <= eah + {7'd0, pgx}; state <= ST_STORE; end  // dummy read; fix; write
                               else if (pgx) begin eah <= eah + 8'd1; state <= ST_IYC; end
                               else exec_op(din_r); end
                ST_IYC:  exec_op(din_r);

                // terminals
                ST_LOAD:  exec_op(din_r);                                     // read [eah,eal] -> reg
                ST_STORE: state <= ST_FETCH;                                   // write [eah,eal] <- reg (bus does it)
                ST_ACC:    begin exec_rmw(A, 1'b1); state <= ST_FETCH; end     // accumulator RMW
                ST_RMW_RD: begin rmw_val <= din_r; exec_rmw(din_r, 1'b0); state <= ST_RMW_W0; end
                ST_RMW_W0: state <= ST_RMW_W1;                                 // ghost write (original, data_out)
                ST_RMW_W1: state <= ST_FETCH;                                  // final write (modified, data_out)

                // NOP / JMP
                ST_IMPL: begin exec_impl; state <= ST_FETCH; end
                ST_JMP1: begin eal <= din_r; PC <= PC + 16'd1; state <= ST_JMP2; end
                ST_JMP2: begin PC <= {din_r, eal}; state <= ST_FETCH; end

                // branches: fetch offset + test condition; if taken, add (with page-cross cycle)
                ST_BRA: begin
                    eal <= din_r; PC <= PC + 16'd1;               // latch offset, PC -> opcode+2
                    case (ir)                                     // taken?
                        8'h10: state <= (~P[7]) ? ST_BRA_TK : ST_FETCH;   // BPL
                        8'h30: state <= ( P[7]) ? ST_BRA_TK : ST_FETCH;   // BMI
                        8'h50: state <= (~P[6]) ? ST_BRA_TK : ST_FETCH;   // BVC
                        8'h70: state <= ( P[6]) ? ST_BRA_TK : ST_FETCH;   // BVS
                        8'h90: state <= (~P[0]) ? ST_BRA_TK : ST_FETCH;   // BCC
                        8'hB0: state <= ( P[0]) ? ST_BRA_TK : ST_FETCH;   // BCS
                        8'hD0: state <= (~P[1]) ? ST_BRA_TK : ST_FETCH;   // BNE
                        8'hF0: state <= ( P[1]) ? ST_BRA_TK : ST_FETCH;   // BEQ
                        default: state <= ST_FETCH;
                    endcase
                end
                ST_BRA_TK: begin                                 // dummy read at opcode+2; add offset
                    if (bra_sum[15:8] == PC[15:8]) begin PC <= bra_sum; state <= ST_FETCH; end   // no page cross
                    else begin PC[7:0] <= bra_sum[7:0]; eah <= bra_sum[15:8]; state <= ST_BRA_PG; end
                end
                ST_BRA_PG: begin PC[15:8] <= eah; state <= ST_FETCH; end   // fix PCH (page cross)

                default: state <= ST_FETCH;
            endcase
        end
    end

    // ---- per-machine-cycle bus capture ---------------------------------------------
    always @(posedge clk) begin
        if (rst) begin dbg_cyc_valid <= 0; dbg_cyc_addr <= 0; dbg_cyc_val <= 0; dbg_cyc_rw <= 1; end
        else begin
            dbg_cyc_valid <= 1'b0;
            if (advance) begin
                dbg_cyc_addr <= addr; dbg_cyc_rw <= rw;
                dbg_cyc_val  <= rw ? din_r : data_out; dbg_cyc_valid <= 1'b1;
            end
        end
    end

    assign dbg_pc = PC;  assign dbg_a = A; assign dbg_x = X; assign dbg_y = Y;
    assign dbg_s  = S;   assign dbg_p = P; assign dbg_sub = sub;
endmodule

`default_nettype wire
