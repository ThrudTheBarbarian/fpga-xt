// hdl/bus_opcodes.vh — wire-format constants for the FPGA<->RP bus.
//
// MUST stay in sync with rp/src/bus_server.h. See docs/wire-protocol.md.
// The matching assertion lives in rp/sim/tb_bus_pio.c which #includes
// bus_server.h and compile-time-asserts each value below.

`ifndef BUS_OPCODES_VH
`define BUS_OPCODES_VH

// Values are decimal so the rp/sim/Makefile `verify` target can grep
// both this file and rp/src/bus_server.h with a portable awk script.
`define BUS_TAG_FETCH  0
`define BUS_TAG_SET    1
`define BUS_TAG_DRAW   2
`define BUS_TAG_NOP    3

// Beat counts for built-in opcodes (DRAW table is opcode-specific).
`define BUS_FETCH_BEATS 1
`define BUS_SET_BEATS   2

// DRAW opcodes — the value carried in beat 0's payload[7:0]. Sized
// 8-bit decimal so `{arg0[15:0], BUS_DRAW_OP_X}` concatenations have
// a defined width. The rp/sim/Makefile `verify` target strips the
// `8'd` prefix when comparing against the C decimal values.
//
// Layout:
//   op[6:0] — 7-bit base opcode (the "primitive ID"). 128 slots.
//   op[7]   — fill flag. 0 = outline, 1 = filled. Applies only to
//             paired closed-shape primitives (RECT, OVAL, ARC). For
//             unpaired ops (NOP, LINE, FILL, BEZIER) op[7] is
//             reserved (must be 0; receiver may trap on non-zero).
//
// rp_tx's beat-count lookup masks off op[7] so paired ops share a
// single beat-count entry. The RP-side renderer reads op[7] to
// pick outline vs fill.
//
// FILL is the flood-fill primitive (paint-bucket: seed point + new
// colour). It is NOT "RECT with op[7]=1" — it has its own arg list
// and beat count.
//
// Beat counts MUST match the wire-protocol DRAW table; rp_tx decodes
// the count from the opcode at sequence start so receiver and emitter
// agree without a separate length field on the wire.
`define BUS_DRAW_FILL_FLAG 8'h80     // OR-in to a paired base op
`define BUS_DRAW_OP_NOP    8'd0      // 1 beat
`define BUS_DRAW_OP_LINE   8'd1      // 5 beats
`define BUS_DRAW_OP_RECT   8'd2      // 5 beats — outline; OR with FILL_FLAG for filled rect
`define BUS_DRAW_OP_FILL   8'd3      // 3 beats — flood-fill (seed x,y + new colour)
`define BUS_DRAW_OP_OVAL   8'd4      // 5 beats — outline; OR with FILL_FLAG for filled. M18
`define BUS_DRAW_OP_ARC    8'd5      // 7 beats — outline; OR with FILL_FLAG = PIE. M18
`define BUS_DRAW_OP_BEZIER 8'd6      // 9 beats — cubic, 4 control points. M18.1
`define BUS_DRAW_OP_BEZIER_TO 8'd7   // 7 beats — chains: 3 new points (start = prev end). M18.1

`endif
