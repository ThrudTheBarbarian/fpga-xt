// rp/src/draw.h — RP-side DRAW dispatcher + primitive renderers (M17-3).
//
// Receives DRAW-tagged bus beats from the FPGA, gathers the per-opcode
// argument list, and renders LINE / RECT / FILL into a caller-provided
// framebuffer. Self-contained — the production glue (bus_server.c) and
// the host test (rp/sim/tb_bus_pio.c) both drop a `draw_ctx_t` into
// their own model and feed it beats.
//
// Beat layout (matches hdl/rp_tx.sv emit + docs/wire-protocol.md):
//   beat 0:  payload = { arg0[15:0], op[7:0] }
//   beats 1..N-1: payload = { 8'h00,  argK[15:0] }
//
// Beat counts (M17 set; M18+ adds OVAL / ARC / BEZIER):
//   NOP_DRAW = 1
//   LINE     = 5    (x0, y0, x1, y1, colour)
//   RECT     = 5    (x, y, w, h, colour+mode) — op[7]=1 → filled
//   FILL     = 3    flood-fill (x, y, colour) — paint-bucket style
//
// op[7] is the fill flag for paired closed-shape primitives (RECT
// today; OVAL / ARC at M18). FILL is a separate primitive — its name
// is historic; functionally it is paint-bucket flood-fill, not a
// filled rectangle (that's RECT with op[7]=1).
//
// Framebuffer model: 8-bit indexed pixels in row-major order; `width`
// is the row stride. Coordinates are 16-bit signed; out-of-bounds
// pixels are silently clipped (no wrap, no trap).

#pragma once

#include <stdint.h>

#define DRAW_MAX_ARGS 9   // BEZIER (M18.1) needs 9 (4 ctl pts + colour).

typedef struct {
    // Framebuffer geometry — set by draw_init.
    uint8_t  *fb;
    uint16_t  width;
    uint16_t  height;

    // Dispatch state. `beats_remaining == 0` means the next DRAW beat
    // starts a new opcode (carries op + arg0). Otherwise it carries
    // the next 16-bit arg in payload[15:0].
    uint8_t   op;
    uint8_t   beats_remaining;
    uint8_t   arg_idx;
    uint16_t  args[DRAW_MAX_ARGS];

    // Chained-curve state for BEZIER_TO. After any BEZIER / BEZIER_TO,
    // (chain_x, chain_y) holds the curve's endpoint (P3). A subsequent
    // BEZIER_TO uses that as P0. Initial value is (0, 0).
    int16_t   chain_x;
    int16_t   chain_y;

    // Counters.
    uint32_t  cmd_count[8];      // by base op (mod 8)
    uint32_t  bad_op_count;      // beats with an opcode the dispatcher doesn't know
    uint32_t  bad_reserved_count;// continuation beat with payload[23:16] != 0 (sync-loss flag)
} draw_ctx_t;

// Initialise `ctx`, point it at a framebuffer of `width` × `height`
// 8-bit-indexed pixels.
void draw_init(draw_ctx_t *ctx, uint8_t *fb, uint16_t width, uint16_t height);

// Feed one DRAW-tagged bus beat (24-bit payload). Internally tracks
// the beat sequence; executes the primitive on the last beat.
void draw_beat(draw_ctx_t *ctx, uint32_t payload);
