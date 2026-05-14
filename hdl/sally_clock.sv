// sally_clock.sv — SALLY clock-enable + RDY gating (M24-5).
//
// Combines four inputs into the single `sally_rdy` line that drives
// Arlet's `cpu.v` RDY pin:
//
//   1. A "step" pulse at the SALLY clock rate. At CLOCK_MULT=1 this is
//      `phi2_tick` directly (lockstep with ANTIC, ~1.79 MHz). At
//      CLOCK_MULT≥2 it's a sub-phi2 counter pulse — SALLY runs N times
//      per phi2 cycle, where N = CLOCK_MULT.
//   2. /HALT from ANTIC's DMA scheduler — at CLOCK_MULT=1 this gates
//      RDY to 0 during DL/PM/playfield bus-stealing cycles, giving
//      cycle-accurate emulation of original /HALT timing. At
//      CLOCK_MULT≥2 it's bypassed (always asserted as "not halted")
//      so SALLY runs free; ANTIC still reads BRAM via dual-port.
//   3. WSYNC ($D40A write) — pulls RDY low until horizontal blank.
//      Always honoured regardless of CLOCK_MULT, since software
//      relies on WSYNC for cycle-accurate display effects.
//
// Implementation:
// - At CLOCK_MULT=1, `sally_rdy = phi2_tick & halt_n & wsync_rdy`.
//   That's a 1-cycle pulse per phi2 (= 1 SALLY step per Atari
//   machine cycle) with the full /HALT and WSYNC chain.
// - At CLOCK_MULT=K, a sub-phi2 counter generates K pulses per phi2
//   cycle. Spacing = floor(BASE_DIV / K) fabric cycles. /HALT is
//   bypassed; only WSYNC + step gate the line.
// - CLOCK_MULT=0 or unrecognised values default to 1× behaviour.
//
// BASE_DIV is the cycles-per-phi2 ratio at CLOCK_MULT=1. The case
// statement enumerates every CLOCK_MULT value that divides cleanly
// into either of the two production BASE_DIVs in current use:
//
//   BASE_DIV=12 (legacy / sim default): clean grades = {1,2,3,4,6,12}
//   BASE_DIV=90 (M-cache-rework Step 5b ceiling): clean grades =
//                          {1,2,3,5,6,9,10,15,18,30,45,90}
//
// Software is responsible for picking a clock_mult that divides
// BASE_DIV cleanly — non-clean combinations still produce a step
// pulse (rounded by integer division) but the effective frequency
// won't match the requested K×.
//
// At BASE_DIV=90 the design exposes 12 clean speed grades up to
// 90× original Atari (= 90 × 1.7898 MHz ≈ 161 MHz). See `docs/
// Issues.md` `clock-mult-range`.

`default_nettype none

module sally_clock #(
    parameter int unsigned BASE_DIV = 90,    // cycles per phi2 at CLOCK_MULT=1
    parameter int unsigned CTR_W    = $clog2(BASE_DIV)
) (
    input  wire        clk,
    input  wire        rst,

    // Aligned phi2 strobe — 1-cycle pulse per phi2 rising edge,
    // generated externally (antic_top has it already).
    input  wire        phi2_tick,

    // Software-selected speed multiplier ($D480 register).
    // 1 = lockstep with ANTIC (cycle-accurate /HALT mode).
    // 2..BASE_DIV = SALLY runs that many times per phi2 cycle.
    input  wire [7:0]  clock_mult,

    // /HALT from dma_arbiter (active-low: 1 = run, 0 = halt).
    // Honoured only at CLOCK_MULT=1.
    input  wire        halt_n,

    // WSYNC's RDY signal from wsync_gen (active-low: 1 = ready,
    // 0 = stall). Always honoured.
    input  wire        wsync_rdy_n,

    // Cache / memory busy from sally_mem (active-low: 1 = ready,
    // 0 = stall). Active during cache-miss refills and (with the
    // M24-int-cache sync-read pipeline) during 2-cycle hits. Always
    // honoured. Defaults `1'b1` so existing testbenches that don't
    // wire it up keep working.
    input  wire        busy_n,

    // Combined output to sally_core's rdy port (active-high: 1 = run).
    output wire        sally_rdy,

    // Diagnostic — useful for tb timing checks.
    output wire        sally_step
);

    // ---- Sub-phi2 step generator (CLOCK_MULT >= 2) -------------------
    // Counter cycles 0..(BASE_DIV/clock_mult - 1). Step pulses on the
    // wrap. At CLOCK_MULT=BASE_DIV, threshold=0 and step pulses every
    // cycle. Width is $clog2(BASE_DIV) so BASE_DIV up to 128 fits.
    logic [CTR_W-1:0] sub_counter_q;
    logic [CTR_W-1:0] sub_threshold;

    always_comb begin
        // Each branch encodes (BASE_DIV / K) - 1 — the integer-divide
        // result is computed at synth time when BASE_DIV is a constant.
        // Branches not used by the current BASE_DIV still synthesise
        // safely (just produce a non-clean rate that software is
        // expected to avoid).
        case (clock_mult)
            8'd1:  sub_threshold = CTR_W'(BASE_DIV - 1);
            8'd2:  sub_threshold = CTR_W'((BASE_DIV / 2)  - 1);
            8'd3:  sub_threshold = CTR_W'((BASE_DIV / 3)  - 1);
            8'd4:  sub_threshold = CTR_W'((BASE_DIV / 4)  - 1);   // clean: BASE_DIV=12
            8'd5:  sub_threshold = CTR_W'((BASE_DIV / 5)  - 1);   // clean: BASE_DIV=90
            8'd6:  sub_threshold = CTR_W'((BASE_DIV / 6)  - 1);
            8'd9:  sub_threshold = CTR_W'((BASE_DIV / 9)  - 1);   // clean: BASE_DIV=90
            8'd10: sub_threshold = CTR_W'((BASE_DIV / 10) - 1);   // clean: BASE_DIV=90
            8'd12: sub_threshold = CTR_W'((BASE_DIV / 12) - 1);   // clean: BASE_DIV=12
            8'd15: sub_threshold = CTR_W'((BASE_DIV / 15) - 1);   // clean: BASE_DIV=90
            8'd18: sub_threshold = CTR_W'((BASE_DIV / 18) - 1);   // clean: BASE_DIV=90
            8'd30: sub_threshold = CTR_W'((BASE_DIV / 30) - 1);   // clean: BASE_DIV=90
            8'd45: sub_threshold = CTR_W'((BASE_DIV / 45) - 1);   // clean: BASE_DIV=90
            8'd90: sub_threshold = CTR_W'((BASE_DIV / 90) - 1);   // clean: BASE_DIV=90
            default: sub_threshold = CTR_W'(BASE_DIV - 1);        // 1× fallback
        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                 sub_counter_q <= '0;
        else if (sub_counter_q >= sub_threshold) sub_counter_q <= '0;
        else                                     sub_counter_q <= sub_counter_q + 1;
    end

    wire sub_step    = (sub_counter_q == sub_threshold);

    // Use the sub-counter unconditionally — at CLOCK_MULT=1 it
    // pulses every BASE_DIV cycles, matching phi2 rate. (We could
    // additionally lockstep to phi2_tick for clean ANTIC alignment
    // but that masks debugging — the counter alone is simpler and
    // gives the same effective rate.)
    wire step        = sub_step;
    assign sally_step = step;

    // /HALT only gates at CLOCK_MULT=1; bypassed at higher rates so
    // ANTIC's bus-stealing cycles don't slow the CPU. WSYNC always
    // honoured.
    wire halt_effective = (clock_mult == 8'd1) ? halt_n : 1'b1;

    assign sally_rdy = step & halt_effective & wsync_rdy_n & busy_n;

endmodule

`default_nettype wire
