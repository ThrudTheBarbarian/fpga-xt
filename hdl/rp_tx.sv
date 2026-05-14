// rp_tx.sv — FPGA-side TX onto the FPGA->RP bus.
//
// Two host-side submission ports:
//   - cmd_*       : FETCH / SET (1- or 2-beat sequences)
//   - draw_cmd_*  : DRAW (1, 5, or — at M18 — 4/6 beat sequences)
//
// One bus output (tag + payload). The FSM serialises the in-flight
// sequence one beat per clk and emits BUS_TAG_NOP on idle cycles so
// the RP-side PIO always sees valid traffic.
//
// Wire format: docs/wire-protocol.md § "FPGA<->RP bus" + DRAW table.
//
// Latency model:
//   - cmd_valid && cmd_ready captured this cycle → bus carries the
//     first beat of the FETCH/SET on the NEXT cycle. SET takes 2 bus
//     cycles total; FETCH takes 1.
//   - draw_cmd_valid && draw_cmd_ready captured this cycle → bus
//     carries the first DRAW beat on the NEXT cycle. Sequence runs
//     to completion (option-A atomic — no FETCH/SET interleave).
//
// Priority on the next cycle when entering S_IDLE: FETCH/SET first
// (cmd_valid wins), then DRAW. cmd_ready is high only in S_IDLE;
// draw_cmd_ready is high only in S_IDLE AND when no FETCH/SET is
// being accepted this cycle AND draw_full is low.
//
// Back-pressure: `draw_full` (one of the spare control wires from
// the RP) gates DRAW emission. When asserted in S_DRAW the FSM
// stalls — emits NOP and holds the beat counter — until it
// deasserts. This is correct but conservative: the wire-protocol
// allows FETCH/SET to interleave during a DRAW pause; we keep that
// optimisation out for now (M17-2 follow-up if measurement shows it
// matters; the RP queue is sized to keep draw_full assertion rare).
//
// Invalid opcodes (anything not in the DRAW opcode table) trap into
// `tx_draw_op_invalid_count` and the command is silently dropped —
// emitting an unknown opcode would desync the receiver, which
// demarcates DRAW sequences by opcode→beat-count lookup.

`default_nettype none
`include "bus_opcodes.vh"

module rp_tx (
    input  wire        clk,
    input  wire        rst,

    // ---- FETCH / SET host port ----------------------------------------
    input  wire [1:0]  cmd_tag,         // BUS_TAG_FETCH | BUS_TAG_SET
    input  wire [23:0] cmd_addr,        // 24-bit byte address (low bit MUST be 0 for SET)
    input  wire [23:0] cmd_data,        // SET payload — 2× 12-bit pixels (lo at [11:0], hi at [23:12])
    input  wire        cmd_valid,
    output wire        cmd_ready,

    // ---- DRAW host port -----------------------------------------------
    // The opcode is in draw_op; up to 9 16-bit args fill the per-opcode
    // beat layout (see wire-protocol.md DRAW table). Unused arg slots
    // for shorter opcodes are ignored. arg5/arg6 added at M18-2 for
    // ARC; arg7/arg8 added at M18.1 for cubic BEZIER (4 control points
    // = 8 16-bit coords + colour = 9 args).
    input  wire        draw_cmd_valid,
    output wire        draw_cmd_ready,
    input  wire [7:0]  draw_op,
    input  wire [15:0] draw_arg0,
    input  wire [15:0] draw_arg1,
    input  wire [15:0] draw_arg2,
    input  wire [15:0] draw_arg3,
    input  wire [15:0] draw_arg4,
    input  wire [15:0] draw_arg5,
    input  wire [15:0] draw_arg6,
    input  wire [15:0] draw_arg7,
    input  wire [15:0] draw_arg8,

    // RP-side queue back-pressure. High = stall DRAW emission.
    input  wire        draw_full,

    // ---- Bus output (one beat per clk) --------------------------------
    output logic [1:0]  bus_tag,
    output logic [23:0] bus_payload,

    // ---- Trap counters ------------------------------------------------
    output logic [31:0] tx_set_misalign_count,
    output logic [31:0] tx_draw_op_invalid_count
);

    // ---- FSM ----------------------------------------------------------
    localparam logic [2:0] S_IDLE     = 3'd0;
    localparam logic [2:0] S_FETCH    = 3'd1;     // emit FETCH addr (1 beat)
    localparam logic [2:0] S_SET_ADDR = 3'd2;     // emit SET addr  (beat 0 of 2)
    localparam logic [2:0] S_SET_DATA = 3'd3;     // emit SET data  (beat 1 of 2)
    localparam logic [2:0] S_DRAW     = 3'd4;     // emit DRAW beat sequence

    logic [2:0] state;

    // FETCH/SET pending fields.
    logic [1:0]  pending_tag;
    logic [23:0] pending_addr;
    logic [23:0] pending_data;

    // DRAW captured args + sequence position.
    logic [7:0]  d_op;
    logic [15:0] d_arg0, d_arg1, d_arg2, d_arg3, d_arg4;
    logic [15:0] d_arg5, d_arg6, d_arg7, d_arg8;
    logic [3:0]  d_beat_idx;
    logic [3:0]  d_beat_count;

    // ---- Beat-count decoder -------------------------------------------
    // Returns 0 for unknown / unsupported opcodes. S_IDLE traps those
    // (increments tx_draw_op_invalid_count and stays idle).
    //
    // op[7] is the fill flag — same beat count as the outline variant
    // for paired ops, so we mask it off before the lookup. FILL is its
    // own primitive (flood-fill, 3 beats) and is NOT op[7]=1 of RECT.
    //
    // M17 / M18 / M18.1 opcodes. Beat counts ≤ 9 fit in this rp_tx's
    // 9-arg storage. d_beat_count is 4 bits so up to 15 beats works
    // if we ever need it.
    function automatic [3:0] draw_beats(input [7:0] op);
        logic [7:0] base_op;
        base_op = {1'b0, op[6:0]};
        case (base_op)
            `BUS_DRAW_OP_NOP:       draw_beats = 4'd1;
            `BUS_DRAW_OP_LINE:      draw_beats = 4'd5;
            `BUS_DRAW_OP_RECT:      draw_beats = 4'd5;   // op[7]=1 → filled rect
            `BUS_DRAW_OP_FILL:      draw_beats = 4'd3;   // flood-fill: x, y, colour
            `BUS_DRAW_OP_OVAL:      draw_beats = 4'd5;   // op[7]=1 → filled oval
            `BUS_DRAW_OP_ARC:       draw_beats = 4'd7;   // op[7]=1 → PIE (filled)
            `BUS_DRAW_OP_BEZIER:    draw_beats = 4'd9;   // M18.1 — cubic, 4 control pts + colour
            `BUS_DRAW_OP_BEZIER_TO: draw_beats = 4'd7;   // M18.1 — chains, P0 = prev endpoint
            default:                draw_beats = 4'd0;
        endcase
    endfunction

    // ---- Beat-payload builder -----------------------------------------
    // Wire layout (per docs/wire-protocol.md):
    //   beat 0: { arg0[15:0], op }            — op in payload[7:0]
    //   beat N (N>0): { 8'h00, argN[15:0] }   — upper byte reserved
    function automatic [23:0] beat_payload(input [3:0] idx);
        case (idx)
            4'd0:    beat_payload = {d_arg0, d_op};
            4'd1:    beat_payload = {8'h00, d_arg1};
            4'd2:    beat_payload = {8'h00, d_arg2};
            4'd3:    beat_payload = {8'h00, d_arg3};
            4'd4:    beat_payload = {8'h00, d_arg4};
            4'd5:    beat_payload = {8'h00, d_arg5};
            4'd6:    beat_payload = {8'h00, d_arg6};
            4'd7:    beat_payload = {8'h00, d_arg7};
            4'd8:    beat_payload = {8'h00, d_arg8};
            default: beat_payload = 24'h000000;
        endcase
    endfunction

    assign cmd_ready      = (state == S_IDLE);
    // DRAW only accepts when idle, no FETCH/SET coming in this cycle, and
    // draw_full is low — avoids latching a cmd we'd immediately stall.
    assign draw_cmd_ready = (state == S_IDLE) && !cmd_valid && !draw_full;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state                    <= S_IDLE;
            pending_tag              <= `BUS_TAG_NOP;
            pending_addr             <= 24'h0;
            pending_data             <= 24'h0;
            d_op                     <= 8'h00;
            d_arg0                   <= 16'h0;
            d_arg1                   <= 16'h0;
            d_arg2                   <= 16'h0;
            d_arg3                   <= 16'h0;
            d_arg4                   <= 16'h0;
            d_arg5                   <= 16'h0;
            d_arg6                   <= 16'h0;
            d_arg7                   <= 16'h0;
            d_arg8                   <= 16'h0;
            d_beat_idx               <= 4'h0;
            d_beat_count             <= 4'h0;
            bus_tag                  <= `BUS_TAG_NOP;
            bus_payload              <= 24'h0;
            tx_set_misalign_count    <= 32'h0;
            tx_draw_op_invalid_count <= 32'h0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    bus_tag     <= `BUS_TAG_NOP;
                    bus_payload <= 24'h0;
                    if (cmd_valid) begin
                        pending_tag  <= cmd_tag;
                        pending_addr <= cmd_addr;
                        pending_data <= cmd_data;
                        state        <= (cmd_tag == `BUS_TAG_SET) ? S_SET_ADDR : S_FETCH;
                        if ((cmd_tag == `BUS_TAG_SET) && cmd_addr[0])
                            tx_set_misalign_count <= tx_set_misalign_count + 32'd1;
                    end else if (draw_cmd_valid && !draw_full) begin
                        if (draw_beats(draw_op) == 4'd0) begin
                            // Unknown opcode — trap and stay idle; the
                            // host sees draw_cmd_ready=1 (this cycle) so
                            // the bad cmd is consumed, not retried.
                            tx_draw_op_invalid_count <= tx_draw_op_invalid_count + 32'd1;
                        end else begin
                            d_op         <= draw_op;
                            d_arg0       <= draw_arg0;
                            d_arg1       <= draw_arg1;
                            d_arg2       <= draw_arg2;
                            d_arg3       <= draw_arg3;
                            d_arg4       <= draw_arg4;
                            d_arg5       <= draw_arg5;
                            d_arg6       <= draw_arg6;
                            d_arg7       <= draw_arg7;
                            d_arg8       <= draw_arg8;
                            d_beat_count <= draw_beats(draw_op);
                            d_beat_idx   <= 4'd0;
                            state        <= S_DRAW;
                        end
                    end
                end

                S_FETCH: begin
                    bus_tag     <= pending_tag;     // BUS_TAG_FETCH
                    bus_payload <= pending_addr;
                    state       <= S_IDLE;
                end

                S_SET_ADDR: begin
                    bus_tag     <= pending_tag;     // BUS_TAG_SET
                    bus_payload <= pending_addr;
                    state       <= S_SET_DATA;
                end

                S_SET_DATA: begin
                    bus_tag     <= `BUS_TAG_SET;
                    bus_payload <= pending_data;
                    state       <= S_IDLE;
                end

                S_DRAW: begin
                    if (draw_full) begin
                        // Stall — emit NOP, hold the beat index. The RP
                        // queue drains, draw_full deasserts, we resume.
                        bus_tag     <= `BUS_TAG_NOP;
                        bus_payload <= 24'h0;
                    end else begin
                        bus_tag     <= `BUS_TAG_DRAW;
                        bus_payload <= beat_payload(d_beat_idx);
                        if (d_beat_idx == d_beat_count - 4'd1) begin
                            state <= S_IDLE;
                        end else begin
                            d_beat_idx <= d_beat_idx + 4'd1;
                        end
                    end
                end

                default: begin
                    state       <= S_IDLE;
                    bus_tag     <= `BUS_TAG_NOP;
                    bus_payload <= 24'h0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
