// xt6502_debug.sv — in-fabric 6502 debugger: halt / single-step / breakpoint /
// register snapshot + injection.  Drives /bin/6502 via the GP0 DEBUG block.
//
// Runs in clk_sally (the core's clock) so it sees the core taps with no CDC.
// Control (toggles + level values) arrives from the GP0 clk_sys domain and is
// synchronised here.  Everything aligns to the core's once-per-instruction
// boundary — dbg_boundary = (state == ST_FETCH) — so the core is only ever
// frozen or sampled at a clean architectural boundary.
//
// HALT is non-destructive: it gates the core's `rdy` low (core_run=0), freezing
// every flop with nothing cleared (unlike SALLYRST, which zeroes the core).
// A snapshot of {PC,A,X,Y,SP,P} is latched at every boundary, so the register
// read-back is a coherent architectural state independent of exactly where the
// core froze — and static while halted, so the clk_sys reader needs no CDC.
//
// RESET semantics: this module is reset by rst_sally (power-on) — NOT by
// rst_sally_core (SALLYRST) — so it survives a core reset.  With halt_at_reset
// set, it re-arms a halt on the SALLYRST release, freezing at the reset-vector
// fetch (icnt=0) so coldstart can be stepped from instruction zero.
`default_nettype none

module xt6502_debug (
    input  wire        clk,          // clk_sally
    input  wire        rst,          // rst_sally — power-on only, survives SALLYRST
    input  wire        core_rst,     // rst_sally_core — SALLYRST-inclusive core reset

    // ---- core taps (clk_sally, no CDC) ----
    input  wire        dbg_boundary, // 1 = ST_FETCH boundary
    input  wire [15:0] dbg_pc,
    input  wire [7:0]  dbg_a,
    input  wire [7:0]  dbg_x,
    input  wire [7:0]  dbg_y,
    input  wire [7:0]  dbg_s,
    input  wire [7:0]  dbg_p,
    input  wire [3:0]  dbg_shigh,

    // ---- control from GP0 (clk_sys) — toggles pulse a command, levels are values ----
    input  wire        halt_tog,
    input  wire        go_tog,
    input  wire        step_tog,
    input  wire        commit_tog,
    input  wire [1:0]  cfg,          // [0]=bkpt_en [1]=halt_at_reset
    input  wire [15:0] bkpt_addr,
    input  wire [15:0] step_count,
    input  wire [15:0] wpc,
    input  wire [31:0] waxys,        // [7:0]A [15:8]X [23:16]Y [31:24]S
    input  wire [11:0] wpsh,         // [7:0]P [11:8]S_high

    // ---- core register injection (clk_sally) ----
    output reg         dbg_wr,
    output wire [15:0] dbg_wpc,
    output wire [7:0]  dbg_wa,
    output wire [7:0]  dbg_wx,
    output wire [7:0]  dbg_wy,
    output wire [7:0]  dbg_ws,
    output wire [7:0]  dbg_wp,
    output wire [3:0]  dbg_wshigh,

    // ---- core rdy gate ----
    output wire        core_run,     // AND into the core's .rdy

    // ---- status to GP0 (clk_sys reads; coherent when halted) ----
    output wire [3:0]  stat,         // [3]=running [2]=stepping [1]=bkpt_hit [0]=halted
    output reg  [15:0] snap_pc,
    output reg  [31:0] snap_axys,
    output reg  [11:0] snap_psh,
    output reg  [31:0] icnt,

    // ---- instruction-trace ring (control from GP0; readback coherent when halted) ----
    input  wire [1:0]  trc_ctrl,     // [0]=enable [1]=break_on_full
    input  wire [11:0] trc_idx,      // read index (0..4095)
    output reg  [31:0] trc_wptr_stat,// [11:0]=wptr [16]=wrapped [17]=broke_on_full
    output reg  [15:0] trc_pc,
    output reg  [31:0] trc_axys,
    output reg  [11:0] trc_p
);
    // ================= CDC: level synchronisers =================
    // The level buses are stable in clk_sys whenever their command pulse fires
    // (software writes the value, then triggers the toggle), so a plain 2-FF
    // register on the multi-bit bus is safe — no capture-while-moving.
    (* ASYNC_REG = "TRUE" *) reg [1:0]  cfg_s1,   cfg_s;
    (* ASYNC_REG = "TRUE" *) reg [15:0] bkpt_s1,  bkpt_s;
    (* ASYNC_REG = "TRUE" *) reg [15:0] stepc_s1, stepc_s;
    (* ASYNC_REG = "TRUE" *) reg [15:0] wpc_s1,   wpc_s;
    (* ASYNC_REG = "TRUE" *) reg [31:0] waxys_s1, waxys_s;
    (* ASYNC_REG = "TRUE" *) reg [11:0] wpsh_s1,  wpsh_s;
    always @(posedge clk) begin
        cfg_s1   <= cfg;        cfg_s   <= cfg_s1;
        bkpt_s1  <= bkpt_addr;  bkpt_s  <= bkpt_s1;
        stepc_s1 <= step_count; stepc_s <= stepc_s1;
        wpc_s1   <= wpc;        wpc_s   <= wpc_s1;
        waxys_s1 <= waxys;      waxys_s <= waxys_s1;
        wpsh_s1  <= wpsh;       wpsh_s  <= wpsh_s1;
    end
    assign dbg_wpc    = wpc_s;
    assign dbg_wa     = waxys_s[7:0];
    assign dbg_wx     = waxys_s[15:8];
    assign dbg_wy     = waxys_s[23:16];
    assign dbg_ws     = waxys_s[31:24];
    assign dbg_wp     = wpsh_s[7:0];
    assign dbg_wshigh = wpsh_s[11:8];

    // ================= CDC: command toggles -> 1-cycle pulses =================
    (* ASYNC_REG = "TRUE" *) reg [2:0] h_s, g_s, s_s, c_s;
    always @(posedge clk) begin
        h_s <= {h_s[1:0], halt_tog};
        g_s <= {g_s[1:0], go_tog};
        s_s <= {s_s[1:0], step_tog};
        c_s <= {c_s[1:0], commit_tog};
    end
    wire do_halt   = h_s[2] ^ h_s[1];
    wire do_go     = g_s[2] ^ g_s[1];
    wire do_step   = s_s[2] ^ s_s[1];
    wire do_commit = c_s[2] ^ c_s[1];

    // ================= boundary edge =================
    reg bnd_q; wire bnd_pulse = dbg_boundary & ~bnd_q;

    // ================= debug FSM =================
    localparam [1:0] S_RUN = 2'd0, S_HALT = 2'd1, S_STEP = 2'd2;
    reg [1:0]  fsm;
    reg [15:0] step_rem;
    reg        halt_pending;
    reg        bkpt_hit_r;
    reg        run_r;
    reg        do_step_q;    // step pulse delayed one cycle so stepc_s has settled

    // At the ST_DECODE boundary PC points one past the opcode, so the instruction
    // address is PC-1 (what the user sees and sets breakpoints on).
    wire [15:0] inst_pc = dbg_pc - 16'd1;

    // Breakpoint match: REGISTER the boundary pulse + inst_pc, so the PC compare that
    // feeds the halt FSM runs off a local register (reg -> subtract -> 16-bit == ->
    // FSM) instead of the long, high-fanout core-PC route. That un-registered compare
    // was marginal on silicon -> INTERMITTENT breakpoints (missed one-time addresses,
    // matched some and not others), while the snapshot/step (shorter paths off the
    // same tap) stayed exact. bkpt_fire lands one clk_sally after the boundary; the
    // snapshot already latched the breakpoint instruction at that boundary, so the
    // halt still reports the right PC. Snapshot/step/commit stay on the direct taps.
    reg        bnd_pulse_d;
    reg [15:0] inst_pc_d;
    always @(posedge clk) begin
        if (rst) bnd_pulse_d <= 1'b0;
        else     bnd_pulse_d <= bnd_pulse;
        inst_pc_d <= inst_pc;
    end
    wire bkpt_fire = bnd_pulse_d && cfg_s[0] && (inst_pc_d == bkpt_s);

    always @(posedge clk) begin
        if (rst) begin
            fsm <= S_RUN; run_r <= 1'b1; halt_pending <= 1'b0;
            step_rem <= 16'd0; bkpt_hit_r <= 1'b0;
            snap_pc <= 16'd0; snap_axys <= 32'd0; snap_psh <= 12'd0; icnt <= 32'd0;
            dbg_wr <= 1'b0; do_step_q <= 1'b0; bnd_q <= 1'b0;
        end else begin
            bnd_q     <= dbg_boundary;
            dbg_wr    <= 1'b0;
            do_step_q <= do_step;

            // Snapshot the architectural state at each instruction boundary; count
            // retired instructions.  Frozen while halted (no boundaries occur), so
            // the clk_sys reader always sees a stable value.
            if (bnd_pulse) begin
                snap_pc   <= inst_pc;
                snap_axys <= {dbg_s, dbg_y, dbg_x, dbg_a};
                snap_psh  <= {dbg_shigh, dbg_p};
                icnt      <= icnt + 32'd1;
            end

            // ---- boundary-driven transitions (commands below override) ----
            // Breakpoint uses the registered bkpt_fire (one cycle after the boundary);
            // halt/step use the direct bnd_pulse.
            case (fsm)
                S_RUN: begin
                    if (bkpt_fire)                      begin bkpt_hit_r <= 1'b1; run_r <= 1'b0; fsm <= S_HALT; end
                    else if (bnd_pulse && halt_pending) begin run_r <= 1'b0; fsm <= S_HALT; end
                end
                S_STEP: if (bkpt_fire) begin bkpt_hit_r <= 1'b1; run_r <= 1'b0; fsm <= S_HALT; end
                else    if (bnd_pulse) begin
                    if      (step_rem <= 16'd1) begin run_r <= 1'b0; fsm <= S_HALT; end
                    else                        step_rem <= step_rem - 16'd1;
                end
                default: /* S_HALT */ run_r <= 1'b0;
            endcase

            // ---- commands (take priority over the boundary logic above) ----
            if (do_halt)   halt_pending <= 1'b1;       // freeze at the next boundary
            if (do_go)     begin fsm <= S_RUN;  run_r <= 1'b1; halt_pending <= 1'b0; bkpt_hit_r <= 1'b0; end
            if (do_step_q) begin fsm <= S_STEP; run_r <= 1'b1; halt_pending <= 1'b0; bkpt_hit_r <= 1'b0;
                                 step_rem <= (stepc_s == 16'd0) ? 16'd1 : stepc_s; end
            if (do_commit) begin
                dbg_wr    <= 1'b1;                      // inject regs into the core (halted)
                snap_pc   <= wpc_s;                     // reflect the injected state immediately
                snap_axys <= waxys_s;
                snap_psh  <= wpsh_s;
                // Re-anchor: let the core fetch+decode the injected instruction and
                // halt mid-it (halt_pending) — the same resting position as a normal
                // halt, so a following `step` executes it rather than just decoding it.
                fsm <= S_RUN; run_r <= 1'b1; halt_pending <= 1'b1; bkpt_hit_r <= 1'b0;
            end

            // ---- core reset (SALLYRST) dominates: keep the debugger from wedging
            // the core out of reset, and (if halt_at_reset) re-arm a freeze so the
            // core stops at the reset-vector fetch.  When halt_at_reset is off this
            // is fully transparent to a normal xl_boot launch (core just runs). ----
            if (core_rst) begin
                icnt         <= 32'd0;        // count instructions from this reset
                fsm          <= S_RUN;
                run_r        <= 1'b1;         // never leave the core un-runnable post-reset
                halt_pending <= cfg_s[1];     // halt_at_reset -> freeze at first boundary
                bkpt_hit_r   <= 1'b0;
            end
        end
    end

    assign core_run = run_r;
    assign stat = {(fsm == S_RUN), (fsm == S_STEP), bkpt_hit_r, (fsm == S_HALT)};

    // ================= instruction-trace ring =================
    // 4096 entries x {shigh,P,S,Y,X,A,inst_pc}, one per ST_DECODE boundary while
    // enabled. Continuous wrap keeps the LAST 4096 instructions, so any halt
    // (breakpoint/step/halt) freezes the path that led there for readback. With
    // break_on_full it instead freezes the FIRST 4096 from the enable. Read only
    // when halted (the core is static, so the clk_sys readback needs no CDC).
    (* ASYNC_REG = "TRUE" *) reg [1:0]  trcc1, trcc2;
    (* ASYNC_REG = "TRUE" *) reg [11:0] trci1, trci2;
    always @(posedge clk) begin
        trcc1 <= trc_ctrl; trcc2 <= trcc1;
        trci1 <= trc_idx;  trci2 <= trci1;
    end
    wire trace_en   = trcc2[0];
    wire break_full = trcc2[1];

    reg [63:0] tbram [0:4095];
    reg [11:0] wptr;
    reg        wrapped, trc_broke, trace_en_d;
    reg [63:0] trd;
    always @(posedge clk) begin
        if (rst) begin
            wptr <= 12'd0; wrapped <= 1'b0; trc_broke <= 1'b0; trace_en_d <= 1'b0;
        end else begin
            trace_en_d <= trace_en;
            if (trace_en && !trace_en_d) begin
                wptr <= 12'd0; wrapped <= 1'b0; trc_broke <= 1'b0;   // clear ring on enable
            end else if (bnd_pulse && trace_en && !trc_broke) begin
                tbram[wptr] <= {4'd0, dbg_shigh, dbg_p, dbg_s, dbg_y, dbg_x, dbg_a, inst_pc};
                wptr <= wptr + 12'd1;
                if (wptr == 12'hFFF) begin
                    wrapped <= 1'b1;
                    if (break_full) trc_broke <= 1'b1;              // freeze at first 4096
                end
            end
        end
        trd <= tbram[trci2];                                        // registered BRAM read
    end
    always @(posedge clk) begin
        trc_pc        <= trd[15:0];
        trc_axys      <= trd[47:16];
        trc_p         <= trd[59:48];
        trc_wptr_stat <= {14'd0, trc_broke, wrapped, 4'd0, wptr};
    end

endmodule

`default_nettype wire
