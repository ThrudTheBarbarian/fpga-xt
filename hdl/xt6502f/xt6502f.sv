// xt6502f.sv — the fidelity ("single-speed Sally") 6502 core. PHASE 1 SKELETON.
//
// Design authority: docs/Design/fidelity-6502.md. This is a fresh, time-native core
// (NOT xt6502 reused): each 6502 MACHINE CYCLE is one window of ~N clk_sally clocks
// (N ≈ 56 at 100 MHz / 1.7898 MHz), paced by `phi2_tick` from sally_clock. Work is
// slotted within the window (`sub` = clocks since the tick): address early (phi1),
// data latched late (phi2), architectural commit late — so every path is multicycle
// and the whole thing (plus the debug facility, later) closes timing with vast slack.
//
// PHASE 1 scope: the cycle engine + bus handshake + reset sequence + a 3-opcode ISA
// (NOP $EA, JMP-abs $4C, unknown→NOP) — enough to run a reset→loop at real-time 1× and
// prove the pacing / phi1-phi2 slotting / SYNC / RDY contract before the full ISA
// (Phase 2), quirks (Phase 3), debug slots (Phase 4) and the resident mux (Phase 5).
//
// Bus contract mirrors what sally_mem expects (addr/data_in/data_out/rw); one access
// per machine cycle, always. RDY (= ANTIC /HALT) stalls read cycles only (datasheet).

`default_nettype none

module xt6502f #(
    // ONE knob: the clk_sally operating point. Everything scales from it, so a future
    // 120 MHz+ point just widens the window (more slack), no hand-tuning. (Decision 1.)
    parameter int unsigned CLK_SALLY_HZ = 100_000_000,  // clk_sally (max operating point)
    parameter int unsigned PHI2_HZ      = 1_789_773     // emulated phi2: NTSC (PAL 1_773_447)
) (
    input  wire        clk,          // clk_sally
    input  wire        rst,          // synchronous reset (power-on / SALLYRST)
    input  wire        phi2_tick,    // 1-cycle pulse marking each machine-cycle boundary

    // 6502 bus
    output wire [15:0] addr,
    input  wire  [7:0] data_in,
    output wire  [7:0] data_out,
    output wire        rw,           // 1 = read, 0 = write
    input  wire        rdy,          // 1 = run, 0 = halt this cycle (read cycles only)
    input  wire        irq_n,        // (Phase 3)
    input  wire        nmi_n,        // (Phase 3)

    // status / debug taps
    output wire        sync,         // high during an opcode-fetch cycle (datasheet SYNC)
    output wire [15:0] dbg_pc,
    output wire  [7:0] dbg_a,
    output wire  [7:0] dbg_x,
    output wire  [7:0] dbg_y,
    output wire  [7:0] dbg_s,
    output wire  [7:0] dbg_p,
    output wire  [7:0] dbg_sub       // window position, for observability
);
    // ---- machine-cycle window: N clk_sally per emulated 6502 cycle -----------------
    // N and the phase-constants are all derived from the one knob (symbolic).
    localparam int unsigned N          = CLK_SALLY_HZ / PHI2_HZ;   // ~56 @100MHz, ~67 @120MHz
    localparam int unsigned SUB_DATA   = N - 7;   // phi2 read-latch (late; ~sub 49 @N=56)
    localparam int unsigned SUB_COMMIT = N - 3;   // retire / arch commit (~sub 53 @N=56)

    // `sub` = clocks since the last phi2_tick (8-bit covers N up to 255).
    reg [7:0] sub;
    always @(posedge clk) begin
        if (rst)            sub <= 8'd0;
        else if (phi2_tick) sub <= 8'd0;
        else                sub <= sub + 8'd1;
    end
    wire slot_data   = (sub == SUB_DATA[7:0]);
    wire slot_commit = (sub == SUB_COMMIT[7:0]);

    // ---- architectural state -------------------------------------------------------
    reg [15:0] PC;
    reg  [7:0] A, X, Y, S, P;

    // ---- cycle FSM -----------------------------------------------------------------
    localparam [3:0]
        ST_RST   = 4'd0,   // reset dummy cycles
        ST_VECL  = 4'd1,   // read $FFFC -> PCL
        ST_VECH  = 4'd2,   // read $FFFD -> PCH
        ST_FETCH = 4'd3,   // opcode fetch (SYNC)
        ST_NOP1  = 4'd4,   // NOP second cycle (dummy read of PC)
        ST_JMP1  = 4'd5,   // JMP: fetch ADL
        ST_JMP2  = 4'd6;   // JMP: fetch ADH -> PC
    reg [3:0] state;
    reg [2:0] rst_cnt;     // reset dummy-cycle countdown
    reg [7:0] ir;          // instruction register (opcode)
    reg [7:0] adl;         // operand low latch
    reg [7:0] din_r;       // data latched at slot_data

    // ---- address source for the current cycle (stable for the whole window) --------
    reg [15:0] addr_c;
    always @(*) begin
        case (state)
            ST_RST:  addr_c = 16'hFFFF;   // dummy reads during reset
            ST_VECL: addr_c = 16'hFFFC;
            ST_VECH: addr_c = 16'hFFFD;
            default: addr_c = PC;         // FETCH / NOP1 / JMP1 / JMP2 all read at PC
        endcase
    end

    assign addr     = addr_c;             // driven from window start (Phase 1: register-early)
    assign rw       = 1'b1;               // skeleton: all reads (writes arrive with STx etc.)
    assign data_out = 8'h00;
    assign sync     = (state == ST_FETCH);

    // RDY halts read cycles: with an all-read ISA, !rdy holds the FSM (cycle repeats).
    wire advance = slot_commit && rdy;

    // ---- data latch (phi2 read slot) -----------------------------------------------
    always @(posedge clk) if (slot_data) din_r <= data_in;

    // ---- FSM + register commit (retire slot) ---------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state   <= ST_RST;
            rst_cnt <= 3'd5;              // ~6-cycle reset init (datasheet), then vector
            PC      <= 16'hFFFC;
            A <= 8'h00; X <= 8'h00; Y <= 8'h00; S <= 8'hFD; P <= 8'h34; // I=1,B=1,bit5=1
            ir <= 8'hEA; adl <= 8'h00; din_r <= 8'h00;
        end else if (advance) begin
            case (state)
                ST_RST:   if (rst_cnt == 3'd0) state <= ST_VECL;
                          else                 rst_cnt <= rst_cnt - 3'd1;
                ST_VECL:  begin PC[7:0]  <= din_r; state <= ST_VECH; end   // addr was $FFFC
                ST_VECH:  begin PC[15:8] <= din_r; state <= ST_FETCH; end  // addr was $FFFD
                ST_FETCH: begin
                    ir <= din_r; PC <= PC + 16'd1;                 // latch opcode, PC++
                    case (din_r)
                        8'hEA:   state <= ST_NOP1;   // NOP
                        8'h4C:   state <= ST_JMP1;   // JMP abs
                        default: state <= ST_NOP1;   // Phase 1: unknown opcodes act as NOP
                    endcase
                end
                ST_NOP1:  state <= ST_FETCH;                       // dummy read of PC, no change
                ST_JMP1:  begin adl <= din_r; PC <= PC + 16'd1; state <= ST_JMP2; end
                ST_JMP2:  begin PC <= {din_r, adl}; state <= ST_FETCH; end
                default:  state <= ST_FETCH;
            endcase
        end
    end

    assign dbg_pc  = PC;
    assign dbg_a   = A;   assign dbg_x = X;  assign dbg_y = Y;
    assign dbg_s   = S;   assign dbg_p = P;
    assign dbg_sub = sub;
endmodule

`default_nettype wire
