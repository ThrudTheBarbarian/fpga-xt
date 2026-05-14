// wsync_gen.sv — WSYNC / RDY handler.
//
// $D40A write (any value) asserts /RDY active-low. /RDY releases on
// the next vbeam line_start. The CPU bus master is expected to stall
// while /RDY is low.
//
// wsync_pending arrives from antic_regs as a 1-cycle pulse.
// line_start arrives from vbeam as a 1-cycle pulse at the start of
// each visible scan line. Same-cycle WSYNC + line_start: WSYNC wins —
// /RDY is held low for one cycle and released on the *next* line_start
// (matches Atari behaviour where a WSYNC write "at" hsync still
// stalls until the following one).
//
// `wsync_overdue_count` ticks each cycle that /RDY has been low for
// more than ~228 clk_bus cycles (one full scan line at the Atari
// reference clock). Real ANTIC always releases by the next hsync —
// the counter is a diagnostic for vbeam misconfiguration.

`default_nettype none

module wsync_gen #(
    parameter int OVERDUE_THRESHOLD = 256   // clk_bus cycles before flagging
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        wsync_pending,    // 1-cycle pulse on $D40A write
    input  wire        line_start,       // 1-cycle pulse from vbeam

    output logic       rdy_n,            // active-low /RDY (1 = ready, 0 = stall)
    output logic [31:0] wsync_overdue_count
);

    logic rdy_internal;             // 1 = ready, 0 = stalled
    logic [15:0] low_age;           // cycles since rdy went low

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_internal        <= 1'b1;
            low_age             <= 16'h0;
            wsync_overdue_count <= 32'h0;
        end else begin
            // WSYNC dominates — set wins over a same-cycle line_start.
            if (wsync_pending) begin
                rdy_internal <= 1'b0;
                low_age      <= 16'h0;
            end else if (line_start && !rdy_internal) begin
                rdy_internal <= 1'b1;
                low_age      <= 16'h0;
            end else if (!rdy_internal) begin
                low_age <= low_age + 16'd1;
                if (low_age == OVERDUE_THRESHOLD[15:0])
                    wsync_overdue_count <= wsync_overdue_count + 32'd1;
            end
        end
    end

    assign rdy_n = rdy_internal;

endmodule

`default_nettype wire
