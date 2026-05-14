// draw_regs.sv — chiplet-extension register port for software-driven
// DRAW commands (M17-2).
//
// 6502-side software stages a DRAW opcode into 16 bytes of the chiplet-
// extension window, then strobes DRAW_GO. This module latches the op +
// 7 16-bit args, raises a `pending` flag, and dispatches to rp_tx's
// draw_cmd port whenever rp_tx is ready (draw_cmd_ready high). Software
// can read DRAW_GO to poll the pending flag for back-pressure.
//
//   $D488 DRAW_OP        — opcode (BUS_DRAW_OP_*)
//   $D489 DRAW_ARG0_LO ┐
//   $D48A DRAW_ARG0_HI │
//   $D48B DRAW_ARG1_LO │ each arg is 16 bits, little-endian
//   $D48C DRAW_ARG1_HI │ (write LO then HI, or in any order — they
//   $D48D DRAW_ARG2_LO │ latch independently and only DRAW_GO commits)
//   $D48E DRAW_ARG2_HI │
//   $D48F DRAW_ARG3_LO │
//   $D490 DRAW_ARG3_HI │
//   $D491 DRAW_ARG4_LO │
//   $D492 DRAW_ARG4_HI ┘
//   $D493 DRAW_GO        — write: any value strobes pending (commit).
//                          read: bit 0 = pending (1 = a DRAW is queued
//                                or in flight; software polls before
//                                writing the next DRAW_GO).
//   $D494 DRAW_ARG5_LO ┐  added at M18-2 for ARC's start_angle /
//   $D495 DRAW_ARG5_HI │  end_angle / colour (7-arg opcode).
//   $D496 DRAW_ARG6_LO │
//   $D497 DRAW_ARG6_HI ┘
//   $D498 DRAW_ARG7_LO ┐  added at M18.1 for cubic BEZIER's 4th
//   $D499 DRAW_ARG7_HI │  control point + colour (9-arg opcode).
//   $D49A DRAW_ARG8_LO │
//   $D49B DRAW_ARG8_HI ┘
//
// Address decode: chiplet-ext is the upper half of the $D4xx window,
// addresses where bit 7 of the offset is 1 (waddr[7]=1). The 7-bit
// chiplet offset for our regs is 7'h08..7'h13.
//
// Pending semantics: a write to DRAW_GO sets `pending`. The dispatch
// path watches draw_cmd_ready; on a ready cycle with pending=1 we
// pulse draw_cmd_valid for one clock and clear pending. If software
// writes DRAW_GO twice while pending is still 1, the second write is
// LOST (and the first cmd's args, possibly half-updated by the second
// write's arg setup, will fire). Software MUST poll DRAW_GO[0] until
// 0 before staging the next cmd.

`default_nettype none

module draw_regs (
    input  wire        clk,
    input  wire        rst,

    // Write port (from bus_snoop, same shape as antic_regs).
    input  wire        we,                 // snoop_we_antic
    input  wire [7:0]  waddr,              // snoop_addr[7:0]
    input  wire [7:0]  wdata,

    // Read port (combinational from live bus signals).
    input  wire [7:0]  raddr,
    output logic [7:0] rdata,

    // Dispatch to rp_tx's DRAW host port.
    output logic        draw_cmd_valid,
    input  wire         draw_cmd_ready,
    output wire  [7:0]  draw_op,
    output wire  [15:0] draw_arg0,
    output wire  [15:0] draw_arg1,
    output wire  [15:0] draw_arg2,
    output wire  [15:0] draw_arg3,
    output wire  [15:0] draw_arg4,
    output wire  [15:0] draw_arg5,
    output wire  [15:0] draw_arg6,
    output wire  [15:0] draw_arg7,
    output wire  [15:0] draw_arg8
);

    // ---- Storage ------------------------------------------------------
    logic [7:0]  op_q;
    logic [15:0] arg0_q, arg1_q, arg2_q, arg3_q, arg4_q;
    logic [15:0] arg5_q, arg6_q, arg7_q, arg8_q;
    logic        pending_q;

    assign draw_op   = op_q;
    assign draw_arg0 = arg0_q;
    assign draw_arg1 = arg1_q;
    assign draw_arg2 = arg2_q;
    assign draw_arg3 = arg3_q;
    assign draw_arg4 = arg4_q;
    assign draw_arg5 = arg5_q;
    assign draw_arg6 = arg6_q;
    assign draw_arg7 = arg7_q;
    assign draw_arg8 = arg8_q;

    // ---- Address decode ----------------------------------------------
    wire       is_chiplet_w = waddr[7];
    wire [6:0] off_w        = waddr[6:0];

    wire       is_chiplet_r = raddr[7];
    wire [6:0] off_r        = raddr[6:0];

    // ---- Write + dispatch FSM ----------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            op_q           <= 8'h00;
            arg0_q         <= 16'h0;
            arg1_q         <= 16'h0;
            arg2_q         <= 16'h0;
            arg3_q         <= 16'h0;
            arg4_q         <= 16'h0;
            arg5_q         <= 16'h0;
            arg6_q         <= 16'h0;
            arg7_q         <= 16'h0;
            arg8_q         <= 16'h0;
            pending_q      <= 1'b0;
            draw_cmd_valid <= 1'b0;
        end else begin
            // Default: deassert valid each cycle (it's a one-cycle pulse).
            draw_cmd_valid <= 1'b0;

            // ---- Register writes -------------------------------------
            if (we && is_chiplet_w) begin
                case (off_w)
                    7'h08: op_q          <= wdata;
                    7'h09: arg0_q[7:0]   <= wdata;
                    7'h0A: arg0_q[15:8]  <= wdata;
                    7'h0B: arg1_q[7:0]   <= wdata;
                    7'h0C: arg1_q[15:8]  <= wdata;
                    7'h0D: arg2_q[7:0]   <= wdata;
                    7'h0E: arg2_q[15:8]  <= wdata;
                    7'h0F: arg3_q[7:0]   <= wdata;
                    7'h10: arg3_q[15:8]  <= wdata;
                    7'h11: arg4_q[7:0]   <= wdata;
                    7'h12: arg4_q[15:8]  <= wdata;
                    7'h13: pending_q     <= 1'b1;   // DRAW_GO strobe
                    7'h14: arg5_q[7:0]   <= wdata;
                    7'h15: arg5_q[15:8]  <= wdata;
                    7'h16: arg6_q[7:0]   <= wdata;
                    7'h17: arg6_q[15:8]  <= wdata;
                    7'h18: arg7_q[7:0]   <= wdata;
                    7'h19: arg7_q[15:8]  <= wdata;
                    7'h1A: arg8_q[7:0]   <= wdata;
                    7'h1B: arg8_q[15:8]  <= wdata;
                    default: ;
                endcase
            end

            // ---- Dispatch --------------------------------------------
            // When pending and rp_tx ready, fire a 1-cycle valid pulse
            // and clear pending. The "&& !draw_cmd_valid" guard is
            // belt-and-braces — without it, a flag that races with the
            // ready edge would risk a 2-cycle pulse.
            if (pending_q && draw_cmd_ready && !draw_cmd_valid) begin
                draw_cmd_valid <= 1'b1;
                pending_q      <= 1'b0;
            end
        end
    end

    // ---- Read side ----------------------------------------------------
    always_comb begin
        rdata = 8'h00;
        if (is_chiplet_r) begin
            case (off_r)
                7'h08:   rdata = op_q;
                7'h09:   rdata = arg0_q[7:0];
                7'h0A:   rdata = arg0_q[15:8];
                7'h0B:   rdata = arg1_q[7:0];
                7'h0C:   rdata = arg1_q[15:8];
                7'h0D:   rdata = arg2_q[7:0];
                7'h0E:   rdata = arg2_q[15:8];
                7'h0F:   rdata = arg3_q[7:0];
                7'h10:   rdata = arg3_q[15:8];
                7'h11:   rdata = arg4_q[7:0];
                7'h12:   rdata = arg4_q[15:8];
                7'h13:   rdata = {7'h00, pending_q};
                7'h14:   rdata = arg5_q[7:0];
                7'h15:   rdata = arg5_q[15:8];
                7'h16:   rdata = arg6_q[7:0];
                7'h17:   rdata = arg6_q[15:8];
                7'h18:   rdata = arg7_q[7:0];
                7'h19:   rdata = arg7_q[15:8];
                7'h1A:   rdata = arg8_q[7:0];
                7'h1B:   rdata = arg8_q[15:8];
                default: rdata = 8'h00;
            endcase
        end
    end

endmodule

`default_nettype wire
