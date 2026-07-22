// wsync_gen.sv — WSYNC / RDY handler.
//
// ANTIC holds a WSYNC LATCH, not a countdown:
//
//   * any write to $D40A SETS the latch (the value written is irrelevant),
//   * `line_start` CLEARS it once per scan line,
//   * /RDY is a REGISTERED output of the latch, two machine cycles behind it.
//
// The register stages are what make a WSYNC write stall the CPU one cycle
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
// CLEAR BEATS SET.  A write landing on the same cycle as `line_start` does not
// start a fresh line-long stall — the release wins and the CPU carries on.
// This is antic_wsync's "Late INC WSYNC" case: an RMW whose two writes straddle
// the release point must not cost a whole scan line.
//
// `line_start` must be pulsed two machine cycles BEFORE the cycle the CPU is
// meant to resume on, since /RDY trails the latch by both register stages.
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
    input  wire  [1:0] pipe_sel,         // /RDY pipeline depth: 0=2 (default), 1=1, 2=3, 3=comb
    input  wire        wsync_pending,    // 1-cycle pulse on $D40A write
    input  wire        line_start,       // 1-cycle pulse from vbeam

    output logic       rdy_n,            // active-low /RDY (1 = ready, 0 = stall)
    output logic [31:0] wsync_overdue_count
);

    logic rdy_latch;                // 1 = ready, 0 = stalled
    logic rdy_q1, rdy_q2, rdy_q3;   // /RDY output pipeline (machine cycles)
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

    // /RDY trails the latch by two machine cycles, so the CPU executes one
    // more cycle after the write before it stalls.  The depth is selectable so
    // the true value can be swept on hardware without a rebuild.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_q1 <= 1'b1;
            rdy_q2 <= 1'b1;
            rdy_q3 <= 1'b1;
        end else if (phi2_tick) begin
            rdy_q1 <= rdy_latch;
            rdy_q2 <= rdy_q1;
            rdy_q3 <= rdy_q2;
        end
    end

    // Depth 3 is the DEFAULT because it is the shallowest depth the fid core
    // actually runs at: measured on hardware, 1 and 2 stages deadlock the OS
    // coldstart outright (it hangs in the hardware-clear loop), while 3 and the
    // combinational path both run.  cfg = 0 must therefore select a depth that
    // boots, or a fresh board wedges its 6502 until someone pokes the register.
    always_comb begin
        case (pipe_sel)
            2'd0:    rdy_n = rdy_q3;      // 3 stages — default, boots
            2'd1:    rdy_n = rdy_q2;      // 2 stages
            2'd2:    rdy_n = rdy_q1;      // 1 stage
            default: rdy_n = rdy_latch;   // combinational
        endcase
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
