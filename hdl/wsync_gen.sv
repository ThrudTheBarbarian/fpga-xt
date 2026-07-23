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
// "$1B != $0D" failure).  One register on both edges shifts assert and
// release together: plain-STA code is cycle-identical to the combinational
// shape (boot-safe), while the RMW gains the delay-slot cycle it needs.
// Cycle-modelled against the ACID800 poly-clock values in tools/wsyncfix.py
// (which reproduces both the passing bytes and the failing shapes exactly).
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

    input  wire        phi2_tick,        // machine-cycle boundary
    input  wire  [1:0] pipe_sel,         // [1]: 0 = registered /RDY (default), 1 = combinational fallback
    input  wire        wsync_pending,    // 1-cycle pulse on $D40A write
    input  wire        line_start,       // 1-cycle pulse from vbeam

    output logic       rdy_n,            // active-low /RDY (1 = ready, 0 = stall)
    output logic [31:0] wsync_overdue_count
);

    logic rdy_latch;                // 1 = ready, 0 = stalled
    logic rdy_latch_q;              // latch delayed one machine cycle
    logic [15:0] low_age;           // cycles since /RDY went low

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_latch <= 1'b1;
        end else begin
            // Both arms assign the same variable non-blockingly, so the LAST
            // one wins: the release beats a same-cycle WSYNC write.
            if (wsync_pending) rdy_latch <= 1'b0;
            if (line_start)    rdy_latch <= 1'b1;
        end
    end

    // One machine cycle of latch history: /RDY falls one cycle after the
    // WSYNC write (the delay slot an RMW's second write lands in) and rises
    // one cycle after the release clears the latch.  Shifting both edges
    // together keeps plain-STA code cycle-identical to the combinational
    // shape, so the OS coldstart resume point does not move.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)            rdy_latch_q <= 1'b1;
        else if (phi2_tick) rdy_latch_q <= rdy_latch;
    end

    // pipe_sel[1] falls back to the plain combinational latch (the previous
    // shipping shape, kept as a runtime escape hatch); pipe_sel[0] is spare
    // (the CPU-side write-immunity knob lives in fpga_xt_top).  Encoding 0 —
    // the power-on default — is the registered stage.
    always_comb begin
        if (pipe_sel[1]) rdy_n = rdy_latch;      // combinational fallback
        else             rdy_n = rdy_latch_q;    // registered (default)
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
