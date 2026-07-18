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
        ST_NOP1=4, ST_JMP1=5, ST_JMP2=6,
        ST_IMM=7,                          // immediate: operand = value
        ST_ZPF=8, ST_ZPI=9,                // zero page: fetch addr / (indexed dummy)
        ST_LOAD=10,                        // read [eah,eal] -> value
        ST_ABL=11, ST_ABH=12,              // absolute: fetch adl / adh
        ST_ABX=13, ST_ABXC=14,             // abs,idx read / page-cross fix
        ST_IXF=15, ST_IXP=16, ST_IXA=17, ST_IXB=18,   // (zp,X)
        ST_IYF=19, ST_IYA=20, ST_IYB=21, ST_IYRD=22, ST_IYC=23; // (zp),Y
    reg [5:0] state;
    reg [2:0] rst_cnt;
    reg [7:0] ir;
    reg [7:0] eal, eah, ptr, idx, din_r;
    reg [1:0] dst;       // load target: 0=A 1=X 2=Y
    reg       has_idx;   // indexed addressing (abs/zp with X/Y)
    reg       pgx;       // page cross pending (indexed abs / (zp),Y)

    // ---- address source for the current cycle --------------------------------------
    reg [15:0] addr_c;
    always @(*) begin
        case (state)
            ST_RST:  addr_c = 16'hFFFF;
            ST_VECL: addr_c = 16'hFFFC;
            ST_VECH: addr_c = 16'hFFFD;
            ST_LOAD, ST_ZPI, ST_ABX, ST_ABXC, ST_IYRD, ST_IYC: addr_c = {eah, eal};
            ST_IXP, ST_IXA, ST_IYA: addr_c = {8'h00, ptr};
            ST_IXB, ST_IYB:         addr_c = {8'h00, ptr + 8'd1};   // zp wrap
            default: addr_c = PC;   // FETCH / IMM / ZPF / ABL / ABH / IXF / IYF / NOP1 / JMPn
        endcase
    end

    assign addr     = addr_c;
    assign rw       = 1'b1;               // load group is all reads
    assign data_out = 8'h00;
    assign sync     = (state == ST_FETCH);
    wire   advance  = slot_commit && rdy;

    // ---- load writeback: dst <- v, set N/Z, return to fetch ------------------------
    task automatic exec_load(input [7:0] v);
        begin
            case (dst) 2'd0: A <= v; 2'd1: X <= v; 2'd2: Y <= v; default: ; endcase
            P     <= {v[7], P[6:2], (v == 8'h00), P[0]};   // N=v[7], Z=(v==0), rest kept
            state <= ST_FETCH;
        end
    endtask

    // page-cross add of an index to eal: {carry, low}
    wire [8:0] eal_plus_idx = {1'b0, eal} + {1'b0, idx};
    wire [8:0] eal_plus_y   = {1'b0, eal} + {1'b0, Y};

    // ---- data latch (phi2 read slot) -----------------------------------------------
    always @(posedge clk) if (slot_data) din_r <= data_in;

    // ---- FSM + commit (retire slot) ------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_RST; rst_cnt <= 3'd5; PC <= 16'hFFFC;
            A <= 0; X <= 0; Y <= 0; S <= 8'hFD; P <= 8'h34;
            ir <= 8'hEA; eal <= 0; eah <= 0; ptr <= 0; idx <= 0; din_r <= 0;
            dst <= 0; has_idx <= 0; pgx <= 0;
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
                    has_idx <= 1'b0; pgx <= 1'b0;
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
                        // ---- control / nop ----
                        8'h4C: state <= ST_JMP1;                                // JMP abs
                        8'hEA: state <= ST_NOP1;                                // NOP
                        default: state <= ST_NOP1;                              // unimpl -> NOP (fails Harte)
                    endcase
                end

                // immediate
                ST_IMM:  begin PC <= PC + 16'd1; exec_load(din_r); end

                // zero page
                ST_ZPF:  begin eal <= din_r; PC <= PC + 16'd1;
                               state <= has_idx ? ST_ZPI : ST_LOAD; end
                ST_ZPI:  begin eal <= eal + idx; state <= ST_LOAD; end          // dummy read [00,eal]; +idx (zp wrap)

                // absolute
                ST_ABL:  begin eal <= din_r; PC <= PC + 16'd1; state <= ST_ABH; end
                ST_ABH:  begin eah <= din_r; PC <= PC + 16'd1;
                               if (has_idx) begin eal <= eal_plus_idx[7:0]; pgx <= eal_plus_idx[8]; state <= ST_ABX; end
                               else state <= ST_LOAD; end
                ST_ABX:  begin if (pgx) begin eah <= eah + 8'd1; state <= ST_ABXC; end
                               else exec_load(din_r); end                       // no cross: value here
                ST_ABXC: exec_load(din_r);                                      // page-cross fixed read

                // (indirect,X)
                ST_IXF:  begin ptr <= din_r; PC <= PC + 16'd1; state <= ST_IXP; end
                ST_IXP:  begin ptr <= ptr + X; state <= ST_IXA; end             // dummy read [00,ptr]; ptr+=X
                ST_IXA:  begin eal <= din_r; state <= ST_IXB; end               // [00,ptr]   -> adl
                ST_IXB:  begin eah <= din_r; state <= ST_LOAD; end              // [00,ptr+1] -> adh

                // (indirect),Y
                ST_IYF:  begin ptr <= din_r; PC <= PC + 16'd1; state <= ST_IYA; end
                ST_IYA:  begin eal <= din_r; state <= ST_IYB; end               // [00,ptr]   -> adl
                ST_IYB:  begin eah <= din_r; eal <= eal_plus_y[7:0]; pgx <= eal_plus_y[8]; state <= ST_IYRD; end
                ST_IYRD: begin if (pgx) begin eah <= eah + 8'd1; state <= ST_IYC; end
                               else exec_load(din_r); end
                ST_IYC:  exec_load(din_r);

                // load terminal (zp / abs non-indexed / (zp,X))
                ST_LOAD: exec_load(din_r);

                // NOP / JMP
                ST_NOP1: state <= ST_FETCH;
                ST_JMP1: begin eal <= din_r; PC <= PC + 16'd1; state <= ST_JMP2; end
                ST_JMP2: begin PC <= {din_r, eal}; state <= ST_FETCH; end

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
