// xt6502f_debug.sv — the fidelity 6502's first-class debug facility (docs/Design/
// fidelity-6502.md §6). A companion to xt6502f that reads the core's settled debug outputs
// in-domain — no CDC, no marginal compare — and produces the debug slot contract:
//
//   * two COHERENT sample windows per machine cycle: an EARLY latch (cycle-entry state, the
//     "clocks 2,3,4" idea) and a LATE latch (settled state after retire, "clocks 53,54,55").
//     Because the arch regs only move at the core's commit slot, latching the core's live
//     dbg_* at a fixed `sub` gives a stable, coherent snapshot by construction.
//   * breakpoint (PC compare at opcode fetch) and data watchpoint (bus addr+dir) evaluated
//     off registered state; a hit drives `cpu_halt`, which the SoC ANDs into the core's
//     `rdy` (same rdy-gate the turbo debugger uses) to freeze at the boundary.
//   * a per-machine-cycle TRACE ring {pc, ir, addr, data, rw} — cycle-level visibility.
//   * single-instruction STEP.
//
// Everything here is free (the core is multicycle), so it is permanent + always-on.
`default_nettype none

module xt6502f_debug #(
    parameter int unsigned N          = 56,   // clk_sally per machine cycle (match the core)
    parameter integer      TRACE_DEPTH = 16,
    parameter integer      STREAM_DEPTH = 4096 // long-run streaming ring depth (A9-drained)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- taps from xt6502f (settled outputs, same clock domain) ----
    input  wire  [7:0] sub,          // dbg_sub: clocks since phi2_tick
    input  wire        sync,         // high during an opcode-fetch cycle
    input  wire [15:0] pc,           // dbg_pc  (live arch regs)
    input  wire  [7:0] a, x, y, s, p,
    input  wire  [7:0] ir_in,        // current opcode (dbg_ir)
    input  wire [15:0] cyc_addr,     // per-machine-cycle bus capture (dbg_cyc_*)
    input  wire  [7:0] cyc_val,
    input  wire        cyc_rw,        // 1=read 0=write
    input  wire        cyc_valid,

    // ---- control (from the GP0 DEBUG block / /bin/6502) ----
    input  wire        halt_req,     // level: force-halt request
    input  wire        resume,       // 1-cycle: clear halt
    input  wire        step,         // 1-cycle: run exactly one instruction then re-halt
    input  wire        bkpt_en,
    input  wire [15:0] bkpt_addr,
    input  wire        wp_en,
    input  wire [15:0] wp_addr,
    input  wire  [1:0] wp_mode,      // bit0 = break on read, bit1 = break on write

    // ---- coherent snapshots ----
    output reg  [15:0] entry_pc,   output reg [7:0] entry_a, entry_x, entry_y, entry_s, entry_p,
    output reg  [15:0] settled_pc, output reg [7:0] settled_a, settled_x, settled_y, settled_s, settled_p,

    // ---- halt/event status ----
    output wire        cpu_halt,     // drive: rdy_core = real_rdy & ~cpu_halt
    output reg         halted,
    output reg         hit_bkpt,
    output reg         hit_wp,

    // ---- trace ring read port ----
    input  wire  [$clog2(TRACE_DEPTH)-1:0] trace_idx,   // 0 = most recent
    output wire [15:0] trace_pc,
    output wire  [7:0] trace_ir,
    output wire [15:0] trace_addr,
    output wire  [7:0] trace_val,
    output wire        trace_rw,
    output wire  [$clog2(TRACE_DEPTH):0]   trace_count,

    // ---- streaming trace to DDR (fidelity long-run capture; A9-drained) ----
    // Per-INSTRUCTION {PC,A,X,Y,SP,P,IR} into a STREAM_DEPTH ring. When it fills
    // the core AUTO-HALTS (folded into cpu_halt) and strm_flush_req rises; the A9
    // drains strm_rdata across strm_raddr (0..strm_wptr-1, static because the core
    // is frozen) then pulses strm_drain_done (4-phase level handshake) to reset the
    // ring and resume. strm_en/strm_drain_done/strm_raddr arrive from GP0 (clk_sys)
    // and are 2-FF synced inside here.
    input  wire        strm_en,          // level: enable per-instruction capture
    input  wire        strm_drain_done,  // level: A9 drained the ring; clear+resume
    input  wire [11:0] strm_raddr,       // ring read address (GP0 domain)
    output wire        strm_flush_req,   // ring full + core halted -> drain now
    output wire [12:0] strm_wptr,        // valid entry count (STREAM_DEPTH when full)
    output wire [63:0] strm_rdata,       // ring[strm_raddr]

    // ---- CONTINUOUS tap for xt_trace_axi (never halts the core) ---------
    // The ring above freezes the CPU when it fills so the A9 can drain it, and
    // that freeze is fatal to anything timing-coupled outside the core (the
    // virtual SIO drive keeps clocking bytes at a frozen guest until its load
    // fails).  This tap is deliberately INDEPENDENT of s_en/s_full: it just
    // reports every retirement and lets the DDR streamer decide what to keep.
    output wire        tr_valid,         // 1 cycle per retired instruction
    output wire [63:0] tr_data           // same packing as strm_rdata
);
    // sample slots: early ~ cycle entry (pre-commit), late ~ settled (post-commit)
    localparam [7:0] SLOT_EARLY = 8'd3;
    localparam [7:0] SLOT_LATE  = N[7:0] - 8'd2;

    // ---- coherent snapshots -------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            entry_pc<=0; entry_a<=0; entry_x<=0; entry_y<=0; entry_s<=0; entry_p<=0;
            settled_pc<=0; settled_a<=0; settled_x<=0; settled_y<=0; settled_s<=0; settled_p<=0;
        end else begin
            if (sub == SLOT_EARLY) begin
                entry_pc<=pc; entry_a<=a; entry_x<=x; entry_y<=y; entry_s<=s; entry_p<=p;
            end
            if (sub == SLOT_LATE) begin
                settled_pc<=pc; settled_a<=a; settled_x<=x; settled_y<=y; settled_s<=s; settled_p<=p;
            end
        end
    end

    // ---- breakpoint (PC compare at the fetch cycle, before the instruction executes) -----
    // dbg_pc holds the fetch address until the core's commit slot, so this is stable+exact.
    wire bkpt_match = bkpt_en && sync && (pc == bkpt_addr);

    // ---- watchpoint (bus access match; registered capture => fires the cycle after) -------
    wire wp_match = wp_en && cyc_valid && (cyc_addr == wp_addr) &&
                    ((cyc_rw && wp_mode[0]) || (!cyc_rw && wp_mode[1]));

    // ---- halt / step FSM ----------------------------------------------------------------
    // A clean instruction boundary is the RISING edge of `sync` (core enters ST_FETCH). When
    // halted at a fetch, the core freezes there (rdy-gated), sub keeps counting but nothing
    // retires. STEP: resume, then re-halt at the next fetch entry = exactly one instruction.
    reg step_arm;
    reg sync_d;
    wire sync_rise = sync && !sync_d;

    reg s_full;                          // streaming ring full -> freeze core (driven below)
    assign cpu_halt = halted || s_full;

    always @(posedge clk) begin
        if (rst) begin
            halted <= 1'b0; hit_bkpt <= 1'b0; hit_wp <= 1'b0; step_arm <= 1'b0; sync_d <= 1'b0;
        end else begin
            sync_d <= sync;
            if (resume) begin
                halted <= 1'b0; step_arm <= 1'b0; hit_bkpt <= 1'b0; hit_wp <= 1'b0;
            end else if (step && halted) begin
                halted <= 1'b0; step_arm <= 1'b1; hit_bkpt <= 1'b0; hit_wp <= 1'b0;
            end else if (!halted) begin
                if (step_arm && sync_rise) begin halted <= 1'b1; step_arm <= 1'b0; end // one instruction done
                else if (bkpt_match && !step_arm) begin halted <= 1'b1; hit_bkpt <= 1'b1; end
                else if (wp_match) begin halted <= 1'b1; hit_wp <= 1'b1; end
                else if (halt_req && sync_rise) halted <= 1'b1;  // halt at the NEXT opcode-fetch boundary,
                                                                 // not mid-instruction (clean freeze/resume)
            end
        end
    end

    // ---- trace ring (per machine-cycle bus + instruction context) -----------------------
    localparam integer AW = $clog2(TRACE_DEPTH);
    reg [15:0] t_pc  [0:TRACE_DEPTH-1];
    reg  [7:0] t_ir  [0:TRACE_DEPTH-1];
    reg [15:0] t_ad  [0:TRACE_DEPTH-1];
    reg  [7:0] t_dv  [0:TRACE_DEPTH-1];
    reg        t_rw  [0:TRACE_DEPTH-1];
    reg [AW-1:0] head;                 // next write slot
    reg [AW:0]   count;

    always @(posedge clk) begin
        if (rst) begin head <= 0; count <= 0; end
        else if (cyc_valid && !halted) begin
            t_pc[head] <= pc;  t_ir[head] <= ir_in; t_ad[head] <= cyc_addr;
            t_dv[head] <= cyc_val; t_rw[head] <= cyc_rw;
            head  <= head + 1'b1;
            if (count != TRACE_DEPTH[AW:0]) count <= count + 1'b1;
        end
    end
    // read: idx 0 = most recent = head-1
    wire [AW-1:0] rd = head - 1'b1 - trace_idx;
    assign trace_pc    = t_pc[rd];
    assign trace_ir    = t_ir[rd];
    assign trace_addr  = t_ad[rd];
    assign trace_val   = t_dv[rd];
    assign trace_rw    = t_rw[rd];
    assign trace_count = count;

    // ================= streaming trace (long-run, A9-drained) =================
    // Per-INSTRUCTION {PC,A,X,Y,SP,P,IR} into a STREAM_DEPTH ring, one write per
    // opcode-fetch boundary (sync_rise). On fill the core freezes (s_full folded
    // into cpu_halt) so the ring is static for the A9 drain; a 4-phase drain_done
    // handshake resets the ring and resumes. Contiguous windows (minus the ~1
    // instruction at the freeze boundary) give a complete long trace across many
    // DDR flushes. The GP0-domain controls are 2-FF synced here.
    localparam integer SAW = $clog2(STREAM_DEPTH);
    (* ASYNC_REG = "TRUE" *) reg [1:0]  sen_s, sdd_s;
    (* ASYNC_REG = "TRUE" *) reg [11:0] sra_s0, sra_s1;
    always @(posedge clk) begin
        sen_s  <= {sen_s[0],  strm_en};
        sdd_s  <= {sdd_s[0],  strm_drain_done};
        sra_s0 <= strm_raddr; sra_s1 <= sra_s0;
    end
    wire s_en = sen_s[1];
    wire s_dd = sdd_s[1];

    reg [63:0]    s_bram [0:STREAM_DEPTH-1];
    reg [SAW-1:0] s_wptr;
    reg           s_en_d, s_dd_d;
    reg [63:0]    s_trd;
    // packed entry: [15:0]=PC [23:16]=A [31:24]=X [39:32]=Y [47:40]=SP [55:48]=P [63:56]=IR
    wire [63:0] s_sample = {ir_in, p, s, y, x, a, pc};
    assign tr_valid = sync_rise && !halted;
    assign tr_data  = s_sample;
    always @(posedge clk) begin
        if (rst) begin
            s_wptr <= {SAW{1'b0}}; s_full <= 1'b0; s_en_d <= 1'b0; s_dd_d <= 1'b0;
        end else begin
            s_en_d <= s_en;
            s_dd_d <= s_dd;
            if (s_en && !s_en_d) begin
                s_wptr <= {SAW{1'b0}}; s_full <= 1'b0;             // enable rising edge: reset ring
            end else if (!s_full) begin
                if (s_en && sync_rise && !halted) begin
                    s_bram[s_wptr] <= s_sample;
                    if (s_wptr == (STREAM_DEPTH-1)) s_full <= 1'b1; // ring full -> freeze the core
                    else s_wptr <= s_wptr + 1'b1;
                end
            end else begin
                if (s_dd && !s_dd_d) begin s_full <= 1'b0; s_wptr <= {SAW{1'b0}}; end // drain_done edge: resume
            end
        end
        s_trd <= s_bram[sra_s1[SAW-1:0]];
    end
    assign strm_flush_req = s_full;
    assign strm_wptr      = s_full ? STREAM_DEPTH[12:0] : {{(13-SAW){1'b0}}, s_wptr};
    assign strm_rdata     = s_trd;
endmodule

`default_nettype wire
