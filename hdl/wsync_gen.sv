// wsync_gen.sv — WSYNC / RDY handler.
//
// ANTIC holds a WSYNC LATCH, not a countdown:
//
//   * any write to $D40A SETS the latch (the value written is irrelevant),
//   * `line_start` CLEARS it once per scan line,
//   * /RDY is a REGISTERED output of the latch, one machine cycle behind it
//     in BOTH directions (assert and release).
//
// The register stage is what makes a WSYNC write stall the CPU one cycle
// *after* the write.  Avery Lee (ACID800 author): "there is a one-cycle delay
// before RDY is pulled.  That delay is on ANTIC's side, so it is one cycle
// regardless of whether the next cycle is a DMA or CPU cycle."  His
// logic-analyser capture of a real XE, cycles numbered from the opcode fetch:
//
//   STA wsync                     INC wsync
//   3: write to wsync             4: write ORIGINAL value to wsync
//   4: /RDY still high            5: write NEW value to wsync, /RDY still high
//      (next opcode fetch runs)      (the RMW's second write lands here)
//   5: /RDY low, CPU stalls       6: /RDY low, CPU stalls
//
// A read-modify-write writes $D40A twice.  Because the latch is level state,
// the second write merely re-sets an already-set latch and changes nothing —
// the stall is timed from the FIRST write.  That is the entire difference
// between STA WSYNC and INC WSYNC in ACID800's antic_wsync: the extra machine
// cycle the RMW spends is exactly the one the delay slot already allows, which
// is why the test's two reads land one cycle apart (114 vs 115 cycles).
//
// The delay must apply to BOTH edges.  Delaying only the assert side (a
// previous experiment) breaks the straddle-the-release case; a purely
// combinational /RDY has no delay slot at all, so a plain STA parks the CPU
// one stream-position early — the release cycle can be tuned to hide that for
// STA, but then the RMW's read lands one cycle early (the measured
// "$1B != $0D" failure).  One machine cycle of delay on both edges shifts
// assert and release together: plain-STA code is cycle-identical to the
// combinational shape (boot-safe), while the RMW gains the delay-slot cycle
// it needs.  Cycle-modelled against the ACID800 poly-clock values in
// tools/wsyncfix.py (which reproduces both the passing bytes and the failing
// shapes exactly).
//
// WHERE THE EDGES MAY MOVE — the consumer's sampling point.  The fid core
// resets its 56-slot subcycle window on a synchronised copy of phi2_tick and
// retires each machine cycle at SUB_COMMIT = N-3, so its rdy sample for
// window K lands essentially ON the next ANTIC tick T(K+1).  A delayed /RDY
// whose edges are launched BY phi2_tick therefore changes value exactly at
// the sample point: the fall is already visible one window early (the delay
// slot evaporates) and the rise is caught immediately (the release delay
// evaporates) — measured on hardware as behaviour identical to the
// combinational latch.  The delayed edges are instead retimed onto the phi2
// FALLING edge (mid-cycle), half a machine cycle away from the sample point
// in either direction.  With the registered set and the default q1 tap:
//   fall: write in window N -> latch drops at tick N+1 -> q1 low from tick
//         N+2, retimed -> mid-cycle N+2: window N+1 still commits (the RMW's
//         delay slot), window N+2 stalls.
//   rise: release at tick R -> latch high during R -> q1 high from tick R+1,
//         retimed -> mid-cycle R+1: the stalled cycle completes in window
//         R+1.
//
// CLEAR BEATS SET.  A write landing on the same cycle as `line_start` does not
// start a fresh line-long stall — the release wins and the CPU carries on.
// This is antic_wsync's "Late INC WSYNC" case: an RMW whose two writes straddle
// the release point must not cost a whole scan line.
//
// `line_start` must be pulsed one machine cycle BEFORE the cycle the CPU is
// meant to resume on, since /RDY trails the latch by the register stage.
//
// `wsync_overdue_count` ticks each cycle that /RDY has been low for more than
// ~228 clk_bus cycles (one full scan line at the Atari reference clock).  Real
// ANTIC always releases by the next hsync — the counter is a diagnostic for
// vbeam misconfiguration.

`default_nettype none

module wsync_gen #(
    parameter int OVERDUE_THRESHOLD = 256   // clk_bus cycles before flagging
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        phi2_tick,        // machine-cycle boundary (phi2 rising edge)
    input  wire        phi2_fall,        // mid-cycle retime point (phi2 falling edge)
    input  wire  [2:0] shape_sel,        // OR-mask {latch,q1,q2} for the retimed /RDY; 0 = default (011 = q1|q2)
    input  wire        comb_sel,         // 1 = bypass to the combinational latch (escape hatch)
    input  wire        wsync_pending,    // 1-cycle pulse on $D40A write
    input  wire        line_start,       // 1-cycle pulse from vbeam

    output logic       rdy_n,            // active-low /RDY (1 = ready, 0 = stall)
    output logic [31:0] wsync_overdue_count
);

    logic rdy_latch;                // 1 = ready, 0 = stalled
    logic rdy_latch_q;              // latch delayed one machine cycle
    logic rdy_latch_q2;             // latch delayed two machine cycles
    logic rdy_mid;                  // (q1|q2) retimed to the phi2 falling edge
    logic [15:0] low_age;           // cycles since /RDY went low

    // The SET path is registered to the machine-cycle boundary: a $D40A write
    // anywhere inside window K arms `wsync_pend`, which drops the latch at
    // tick K+1 — unless the release fires on that same tick, in which case
    // the clear wins and the write is discarded.  This makes clear-beats-set
    // a true same-edge arbitration (the release pulse is tick-aligned, the
    // raw write strobe is not), which is the behaviour the "late INC WSYNC"
    // straddle needs: the RMW's second write racing the release must not buy
    // a fresh line-long stall.  Measured on hardware: with a mid-window
    // asynchronous set, no delay shape passes the straddle and the delay-slot
    // check together; with the registered set the q1 tap passes all six
    // ACID800 antic_wsync bytes (tools/wsyncrtl.py).
    logic wsync_pend;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                wsync_pend <= 1'b0;
        else if (phi2_tick)     wsync_pend <= wsync_pending;   // pulse landing on the tick starts the new window
        else if (wsync_pending) wsync_pend <= 1'b1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_latch <= 1'b1;
        end else if (phi2_tick) begin
            // Both arms assign the same variable non-blockingly, so the LAST
            // one wins: the release beats a same-tick WSYNC write.
            if (wsync_pend)  rdy_latch <= 1'b0;
            if (line_start)  rdy_latch <= 1'b1;
        end
    end

    // Two machine cycles of latch history (rising-edge launched), then the
    // asymmetric combination (q1|q2) — fall two ticks after the latch, rise
    // one tick after — retimed onto the phi2 FALLING edge so both /RDY edges
    // sit mid-cycle, half a machine cycle from the fid core's commit-slot
    // sample point (see the header).  Net effect through that sampling: both
    // edges land one machine cycle later than the combinational latch.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_latch_q  <= 1'b1;
            rdy_latch_q2 <= 1'b1;
        end else if (phi2_tick) begin
            rdy_latch_q  <= rdy_latch;
            rdy_latch_q2 <= rdy_latch_q;
        end
    end

    // The retimed shape is an OR over selected taps of the latch history so
    // the exact delay pair can be swept on hardware without a rebuild:
    //   mask 010 (default) : q1         — both edges 1 tick behind the latch;
    //                        with the registered set this is the shape that
    //                        passes all six antic_wsync bytes in the model
    //   mask 001           : q2         — both edges 2 ticks behind
    //   mask 011           : q1|q2      — fall 2 ticks, rise 1 tick behind
    //   mask 110           : latch|q1   — fall 1 tick behind, rise immediate
    //   mask 100           : latch      — tick-updated latch, mid-cycle retimed
    wire [2:0] shape_mask = (shape_sel == 3'b000) ? 3'b010 : shape_sel;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)            rdy_mid <= 1'b1;
        else if (phi2_fall) rdy_mid <= |(shape_mask & {rdy_latch, rdy_latch_q, rdy_latch_q2});
    end

    // comb_sel falls back to the plain combinational latch (the previous
    // shipping shape, kept as a runtime escape hatch).
    always_comb begin
        if (comb_sel) rdy_n = rdy_latch;      // combinational fallback
        else          rdy_n = rdy_mid;        // registered mid-cycle (default)
    end

    // ---- Diagnostic: /RDY held low beyond one scan line -------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            low_age             <= 16'h0;
            wsync_overdue_count <= 32'h0;
        end else if (rdy_n) begin
            low_age <= 16'h0;
        end else begin
            low_age <= low_age + 16'd1;
            if (low_age == OVERDUE_THRESHOLD[15:0])
                wsync_overdue_count <= wsync_overdue_count + 32'd1;
        end
    end

endmodule

`default_nettype wire
