// rp/src/draw.c — RP-side DRAW dispatcher + primitive renderers (M17-3).
// See draw.h for the wire protocol; bus_server.h for the BUS_DRAW_OP_*
// constants.

#include "draw.h"
#include "bus_server.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Forward decl — draw_cubic_bezier (defined below) reaches back to
// draw_line for inter-sample fill.
static void draw_line(draw_ctx_t *ctx, int x0, int y0, int x1, int y1, uint8_t color);

// ---- Polar-angle test for ARC / PIE (M18-2) ------------------------------
// Wire-protocol angle units: 0..65535 → 0..360°, screen-coord convention
// (y increases downward, so 0° = +x = "east", 90° = +y = "south").
//
// Returns 1 if the polar angle of (dx, dy) (relative to centre) is in
// the arc [start_angle, start_angle + span_angle] (mod 65 536). The
// span is the unsigned 16-bit difference (end - start), so wrap-around
// arcs work via uint16 arithmetic. Uses atan2f — simple and correct;
// ~20 µs per call on RP2354 with newlib soft-FP. For arcs the per-call
// pixel count is small (≤ 2 πr); not a bottleneck unless we end up
// drawing many large arcs per frame, in which case a sin/cos LUT +
// cross-product test is the obvious follow-up.
static int point_in_arc(int dx, int dy,
                        uint16_t start_a, uint16_t span_a) {
    if (dx == 0 && dy == 0) return 1;
    float ang = atan2f((float)dy, (float)dx);
    if (ang < 0.0f) ang += 2.0f * (float)M_PI;
    uint32_t theta = (uint32_t)(ang * (65536.0f / (2.0f * (float)M_PI)));
    if (theta > 65535u) theta = 65535u;
    uint16_t delta = (uint16_t)((uint16_t)theta - start_a);
    return delta <= span_a;
}

// ---- Beat-count table -----------------------------------------------------
// Returns 0 for unknown opcodes — caller treats that as a sync-loss
// signal (drops the beat, traps into bad_op_count).
//
// Mask off op[7] (the fill flag) before the lookup so paired ops
// share a single entry. FILL is a separate primitive (flood-fill),
// not "RECT with op[7]=1".
static uint8_t draw_beat_count(uint8_t op) {
    const uint8_t base = op & 0x7Fu;
    switch (base) {
        case BUS_DRAW_OP_NOP:  return 1;
        case BUS_DRAW_OP_LINE: return 5;
        case BUS_DRAW_OP_RECT: return 5;   // op[7]=1 → filled
        case BUS_DRAW_OP_FILL: return 3;   // flood-fill
        case BUS_DRAW_OP_OVAL:      return 5;   // op[7]=1 → filled (M18-1)
        case BUS_DRAW_OP_ARC:       return 7;   // op[7]=1 → PIE (M18-2)
        case BUS_DRAW_OP_BEZIER:    return 9;   // cubic, 4 ctl pts + colour (M18.1)
        case BUS_DRAW_OP_BEZIER_TO: return 7;   // chains, P0 = chain_x/y (M18.1)
        default:                    return 0;
    }
}

// ---- Pixel helpers --------------------------------------------------------
static inline void put_pixel(draw_ctx_t *ctx, int x, int y, uint8_t color) {
    if (x < 0 || y < 0) return;
    if (x >= (int)ctx->width || y >= (int)ctx->height) return;
    ctx->fb[(unsigned)y * ctx->width + (unsigned)x] = color;
}

// ---- Primitive: filled rectangle -----------------------------------------
// Used by RECT with op[7]=1 (op == BUS_DRAW_OP_RECT | 0x80).
static void draw_rect_filled(draw_ctx_t *ctx, int x, int y, int w, int h, uint8_t color) {
    if (w <= 0 || h <= 0) return;
    // Clip to FB.
    int x0 = x < 0 ? 0 : x;
    int y0 = y < 0 ? 0 : y;
    int x1 = x + w;  if (x1 > (int)ctx->width)  x1 = ctx->width;
    int y1 = y + h;  if (y1 > (int)ctx->height) y1 = ctx->height;
    if (x0 >= x1 || y0 >= y1) return;
    for (int row = y0; row < y1; row++) {
        memset(&ctx->fb[(unsigned)row * ctx->width + (unsigned)x0],
               color, (size_t)(x1 - x0));
    }
}

// ---- Primitive: scanline flood-fill (Heckbert seed-fill) -----------------
// Replaces every 4-connected pixel of the seed colour, starting at
// (sx, sy), with `new_color`. Pushes per-row segments onto an explicit
// stack rather than per-pixel — bounded depth and friendlier to the
// RP2354's stack/cache. No-op if the seed is OOB or already the new
// colour.
//
// DRAW_FLOOD_STACK_DEPTH bounds the stack. For a 640×240 FB the worst
// case is ~600 segments (a comb pattern); 256 covers everything we
// realistically render at 320×200 / 256×192. Beyond that segments are
// dropped — the fill becomes "best-effort" rather than crashing.
#define DRAW_FLOOD_STACK_DEPTH 256

typedef struct {
    int16_t y;
    int16_t xl;        // leftmost x of the seed segment
    int16_t xr;        // rightmost x (inclusive)
    int8_t  parent_dy; // direction from parent: -1 / 0 / +1 (0 = root seed)
} flood_seg_t;

static void draw_flood_fill(draw_ctx_t *ctx, int sx, int sy, uint8_t new_color) {
    if (sx < 0 || sy < 0 ||
        sx >= (int)ctx->width || sy >= (int)ctx->height) return;
    const uint8_t old_color = ctx->fb[(unsigned)sy * ctx->width + (unsigned)sx];
    if (old_color == new_color) return;

    flood_seg_t stack[DRAW_FLOOD_STACK_DEPTH];
    int sp = 0;
    if (sp < DRAW_FLOOD_STACK_DEPTH) {
        stack[sp++] = (flood_seg_t){ (int16_t)sy, (int16_t)sx, (int16_t)sx, 0 };
    }

    while (sp > 0) {
        const flood_seg_t s = stack[--sp];
        const int y = s.y;
        // Expand the seed segment leftward + rightward to find the
        // full run of old_color on this row that contains [s.xl..s.xr].
        int xl = s.xl;
        while (xl > 0 &&
               ctx->fb[(unsigned)y * ctx->width + (unsigned)(xl - 1)] == old_color)
            xl--;
        int xr = s.xr;
        while (xr + 1 < (int)ctx->width &&
               ctx->fb[(unsigned)y * ctx->width + (unsigned)(xr + 1)] == old_color)
            xr++;

        // Paint the run.
        memset(&ctx->fb[(unsigned)y * ctx->width + (unsigned)xl],
               new_color, (size_t)(xr - xl + 1));

        // Scan the row above (y-1) and below (y+1) for runs of
        // old_color that touch [xl..xr]. Each becomes a new seed.
        // Skip the parent direction's overlap with [s.xl..s.xr] —
        // the run there was just painted by the parent.
        for (int dy = -1; dy <= 1; dy += 2) {
            const int ny = y + dy;
            if (ny < 0 || ny >= (int)ctx->height) continue;
            int x = xl;
            while (x <= xr) {
                // Walk to the start of a same-colour run.
                while (x <= xr &&
                       ctx->fb[(unsigned)ny * ctx->width + (unsigned)x] != old_color)
                    x++;
                if (x > xr) break;
                const int run_xl = x;
                while (x <= xr &&
                       ctx->fb[(unsigned)ny * ctx->width + (unsigned)x] == old_color)
                    x++;
                const int run_xr = x - 1;
                // Skip if this is the segment we came from.
                if (s.parent_dy != 0 && dy == -s.parent_dy &&
                    run_xl >= s.xl && run_xr <= s.xr) continue;
                if (sp < DRAW_FLOOD_STACK_DEPTH) {
                    stack[sp++] = (flood_seg_t){
                        (int16_t)ny, (int16_t)run_xl, (int16_t)run_xr, (int8_t)dy
                    };
                }
                // (else: stack overflow — drop this segment. The fill
                //  region will have a hole; counted via a stat if we
                //  add one later.)
            }
        }
    }
}

// ---- Primitive: rectangle outline (1-pixel thick) ------------------------
static void draw_rect_outline(draw_ctx_t *ctx, int x, int y, int w, int h, uint8_t color) {
    if (w <= 0 || h <= 0) return;
    int top    = y;
    int bottom = y + h - 1;
    int left   = x;
    int right  = x + w - 1;
    // Top + bottom rows.
    for (int c = x; c < x + w; c++) {
        put_pixel(ctx, c, top,    color);
        if (bottom != top) put_pixel(ctx, c, bottom, color);
    }
    // Left + right columns (skip corners — already done above).
    for (int r = y + 1; r < y + h - 1; r++) {
        put_pixel(ctx, left,  r, color);
        if (right != left) put_pixel(ctx, right, r, color);
    }
}

// ---- Primitive: midpoint ellipse outline (M18-1) -------------------------
// Standard 4-way-symmetric ellipse rasteriser. Walks the upper-right
// quadrant in two regions (region 1: |dy/dx| < 1, region 2: |dy/dx| ≥ 1)
// using integer-only midpoint decision values, plotting the four
// reflected pixels each step.
//
// Degenerate cases: rx==0 → vertical line; ry==0 → horizontal line;
// both 0 → single pixel. Negative radii are treated as their absolute
// values (no semantic for "negative ellipse").
static void put4(draw_ctx_t *ctx, int cx, int cy, int x, int y, uint8_t color) {
    put_pixel(ctx, cx + x, cy + y, color);
    put_pixel(ctx, cx - x, cy + y, color);
    put_pixel(ctx, cx + x, cy - y, color);
    put_pixel(ctx, cx - x, cy - y, color);
}

static void draw_oval_outline(draw_ctx_t *ctx, int cx, int cy,
                              int rx, int ry, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 && ry == 0) { put_pixel(ctx, cx, cy, color); return; }
    if (rx == 0) {
        for (int y = -ry; y <= ry; y++) put_pixel(ctx, cx, cy + y, color);
        return;
    }
    if (ry == 0) {
        for (int x = -rx; x <= rx; x++) put_pixel(ctx, cx + x, cy, color);
        return;
    }

    long rx2 = (long)rx * rx, ry2 = (long)ry * ry;
    long tworx2 = 2 * rx2, twory2 = 2 * ry2;
    long x = 0, y = ry;
    long px = 0, py = tworx2 * y;
    long p = (long)(ry2 - rx2 * (long)ry + (rx2 + 2) / 4);   // region-1 init

    // Region 1: slope shallow (|dy/dx| < 1).
    while (px < py) {
        put4(ctx, cx, cy, (int)x, (int)y, color);
        x++;
        px += twory2;
        if (p < 0) {
            p += ry2 + px;
        } else {
            y--;
            py -= tworx2;
            p += ry2 + px - py;
        }
    }

    // Region-2 init.
    p = (long)(ry2 * (2 * x + 1) * (2 * x + 1) / 4
             + rx2 * (y - 1) * (y - 1)
             - rx2 * ry2);
    while (y >= 0) {
        put4(ctx, cx, cy, (int)x, (int)y, color);
        y--;
        py -= tworx2;
        if (p > 0) {
            p += rx2 - py;
        } else {
            x++;
            px += twory2;
            p += rx2 - py + px;
        }
    }
}

// ---- Primitive: filled oval (M18-1) ---------------------------------------
// Per scanline `dy` in [-ry, +ry], the half-width is
//   hx = round( rx * sqrt(1 - dy*dy / ry*ry) ).
// Pure integer form: hx = isqrt( (long long)rx*rx * ( ry*ry - dy*dy ) / (ry*ry) ).
// We avoid a floating-point sqrt with a small integer-sqrt helper —
// fits the RP2354's no-FPU-fast-path constraint.
static long isqrt_l(long long n) {
    if (n < 2) return (long)(n < 0 ? 0 : n);
    long long x = n / 2;     // crude initial guess
    long long last = 0;
    for (int i = 0; i < 32 && x != last; i++) {
        last = x;
        x = (x + n / x) / 2;
    }
    while (x * x > n) x--;
    return (long)x;
}

static void draw_oval_filled(draw_ctx_t *ctx, int cx, int cy,
                             int rx, int ry, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 || ry == 0) {
        // Degenerate: thin line (matches outline behaviour).
        draw_oval_outline(ctx, cx, cy, rx, ry, color);
        return;
    }
    const long long rx2 = (long long)rx * rx;
    const long long ry2 = (long long)ry * ry;
    for (int dy = -ry; dy <= ry; dy++) {
        const long long num = rx2 * (ry2 - (long long)dy * dy);
        const long hx = isqrt_l(num / ry2);
        const int xl = cx - (int)hx, xr = cx + (int)hx;
        // Span-clip to FB.
        int x0 = xl < 0 ? 0 : xl;
        int x1 = xr;
        if (x1 >= (int)ctx->width) x1 = (int)ctx->width - 1;
        const int y = cy + dy;
        if (y < 0 || y >= (int)ctx->height) continue;
        if (x0 > x1) continue;
        memset(&ctx->fb[(unsigned)y * ctx->width + (unsigned)x0],
               color, (size_t)(x1 - x0 + 1));
    }
}

// ---- Primitive: ARC outline (M18-2) --------------------------------------
// Walks the same midpoint ellipse path as draw_oval_outline but gates
// each of the 4 reflected pixels independently against the arc range.
static void draw_arc_outline(draw_ctx_t *ctx, int cx, int cy,
                             int rx, int ry,
                             uint16_t start_a, uint16_t end_a, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    const uint16_t span = (uint16_t)(end_a - start_a);

    if (rx == 0 && ry == 0) {
        if (point_in_arc(0, 0, start_a, span))
            put_pixel(ctx, cx, cy, color);
        return;
    }
    if (rx == 0) {
        for (int dy = -ry; dy <= ry; dy++)
            if (point_in_arc(0, dy, start_a, span))
                put_pixel(ctx, cx, cy + dy, color);
        return;
    }
    if (ry == 0) {
        for (int dx = -rx; dx <= rx; dx++)
            if (point_in_arc(dx, 0, start_a, span))
                put_pixel(ctx, cx + dx, cy, color);
        return;
    }

    long rx2 = (long)rx * rx, ry2 = (long)ry * ry;
    long tworx2 = 2 * rx2, twory2 = 2 * ry2;
    long x = 0, y = ry;
    long px = 0, py = tworx2 * y;
    long p = (long)(ry2 - rx2 * (long)ry + (rx2 + 2) / 4);

    // Region 1.
    while (px < py) {
        if (point_in_arc( (int)x,  (int)y, start_a, span)) put_pixel(ctx, cx + x, cy + y, color);
        if (point_in_arc(-(int)x,  (int)y, start_a, span)) put_pixel(ctx, cx - x, cy + y, color);
        if (point_in_arc( (int)x, -(int)y, start_a, span)) put_pixel(ctx, cx + x, cy - y, color);
        if (point_in_arc(-(int)x, -(int)y, start_a, span)) put_pixel(ctx, cx - x, cy - y, color);
        x++;
        px += twory2;
        if (p < 0)            p += ry2 + px;
        else { y--; py -= tworx2; p += ry2 + px - py; }
    }

    // Region 2.
    p = (long)(ry2 * (2 * x + 1) * (2 * x + 1) / 4
             + rx2 * (y - 1) * (y - 1)
             - rx2 * ry2);
    while (y >= 0) {
        if (point_in_arc( (int)x,  (int)y, start_a, span)) put_pixel(ctx, cx + x, cy + y, color);
        if (point_in_arc(-(int)x,  (int)y, start_a, span)) put_pixel(ctx, cx - x, cy + y, color);
        if (point_in_arc( (int)x, -(int)y, start_a, span)) put_pixel(ctx, cx + x, cy - y, color);
        if (point_in_arc(-(int)x, -(int)y, start_a, span)) put_pixel(ctx, cx - x, cy - y, color);
        y--;
        py -= tworx2;
        if (p > 0)            p += rx2 - py;
        else { x++; px += twory2; p += rx2 - py + px; }
    }
}

// ---- Primitive: PIE / filled ARC (M18-2) ---------------------------------
// Walks each scanline of the bounding ellipse; for every pixel inside
// the ellipse AND inside the angular sector, paints. O(rx·ry·atan2),
// fine for occasional draws — promote to a sweepline with explicit
// sector boundaries if profiling complains.
static void draw_pie(draw_ctx_t *ctx, int cx, int cy,
                     int rx, int ry,
                     uint16_t start_a, uint16_t end_a, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 || ry == 0) {
        // Degenerate — fall back to outline (no interior to fill).
        draw_arc_outline(ctx, cx, cy, rx, ry, start_a, end_a, color);
        return;
    }
    const uint16_t span = (uint16_t)(end_a - start_a);
    const long long rx2 = (long long)rx * rx;
    const long long ry2 = (long long)ry * ry;
    for (int dy = -ry; dy <= ry; dy++) {
        const long long num = rx2 * (ry2 - (long long)dy * dy);
        const long hx = isqrt_l(num / ry2);
        const int y = cy + dy;
        if (y < 0 || y >= (int)ctx->height) continue;
        for (int dx = -hx; dx <= hx; dx++) {
            const int x = cx + dx;
            if (x < 0 || x >= (int)ctx->width) continue;
            if (point_in_arc(dx, dy, start_a, span))
                ctx->fb[(unsigned)y * ctx->width + (unsigned)x] = color;
        }
    }
}

// ---- Primitive: cubic Bezier (M18.1) -------------------------------------
// Plots B(t) for t in [0..1] in steps fine enough that consecutive
// sample points are ≤ 1 px apart. Steps = max(|P0-P1|, |P1-P2|,
// |P2-P3|) × 4 — generous upper bound on actual curve length, but
// O(N) is fine and undersampling would leave gaps. Consecutive
// samples are connected with a 1-pixel line (Bresenham) so any
// remaining gap is filled.
//
// Math:
//   B(t) = (1-t)³ P0 + 3(1-t)²t P1 + 3(1-t)t² P2 + t³ P3
//
// We compute in float (single precision is plenty for 16-bit coords)
// and round to int when plotting. RP2354 has no FPU but newlib's
// soft-FP is fast enough for the once-per-step cost — measured ~3 µs
// per sample on Cortex-M33 at 150 MHz. A 256-sample curve is ~1 ms.
static int abs_int(int v) { return v < 0 ? -v : v; }

static void draw_cubic_bezier(draw_ctx_t *ctx,
                              int x0, int y0, int x1, int y1,
                              int x2, int y2, int x3, int y3,
                              uint8_t color) {
    // Estimate step count.
    int dist01 = abs_int(x1 - x0) + abs_int(y1 - y0);
    int dist12 = abs_int(x2 - x1) + abs_int(y2 - y1);
    int dist23 = abs_int(x3 - x2) + abs_int(y3 - y2);
    int hull = dist01 + dist12 + dist23;
    int steps = hull;
    if (steps < 8) steps = 8;
    if (steps > 4096) steps = 4096;     // cap so we don't burn forever

    int prev_x = x0, prev_y = y0;
    put_pixel(ctx, prev_x, prev_y, color);

    for (int i = 1; i <= steps; i++) {
        float t = (float)i / (float)steps;
        float u = 1.0f - t;
        float w0 = u * u * u;
        float w1 = 3.0f * u * u * t;
        float w2 = 3.0f * u * t * t;
        float w3 = t * t * t;
        float bx = w0 * (float)x0 + w1 * (float)x1 + w2 * (float)x2 + w3 * (float)x3;
        float by = w0 * (float)y0 + w1 * (float)y1 + w2 * (float)y2 + w3 * (float)y3;
        int  ix = (int)(bx + (bx >= 0 ? 0.5f : -0.5f));
        int  iy = (int)(by + (by >= 0 ? 0.5f : -0.5f));
        if (ix != prev_x || iy != prev_y) {
            // Connect to ensure no gap if the step jumped > 1 px.
            // draw_line handles a 1-pixel "line" as a single put_pixel
            // overwrite, so always-call is safe.
            draw_line(ctx, prev_x, prev_y, ix, iy, color);
            prev_x = ix;
            prev_y = iy;
        }
    }

    // Save endpoint for any chained BEZIER_TO that follows.
    ctx->chain_x = (int16_t)x3;
    ctx->chain_y = (int16_t)y3;
}

// ---- Primitive: Bresenham line -------------------------------------------
static void draw_line(draw_ctx_t *ctx, int x0, int y0, int x1, int y1, uint8_t color) {
    int dx =  abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    while (1) {
        put_pixel(ctx, x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

// ---- Opcode dispatch ------------------------------------------------------
// op[7] is the fill flag for paired closed-shape primitives (RECT
// today; OVAL / ARC at M18). The base op (op[6:0]) selects the shape;
// the fill bit picks the renderer.
static void draw_execute(draw_ctx_t *ctx) {
    const uint8_t base = ctx->op & 0x7Fu;
    const uint8_t fill = (ctx->op >> 7) & 0x1u;
    switch (base) {
        case BUS_DRAW_OP_NOP:
            break;
        case BUS_DRAW_OP_LINE: {
            int16_t x0 = (int16_t)ctx->args[0];
            int16_t y0 = (int16_t)ctx->args[1];
            int16_t x1 = (int16_t)ctx->args[2];
            int16_t y1 = (int16_t)ctx->args[3];
            uint8_t color = (uint8_t)(ctx->args[4] & 0xFF);
            draw_line(ctx, x0, y0, x1, y1, color);
            break;
        }
        case BUS_DRAW_OP_RECT: {
            int16_t x = (int16_t)ctx->args[0];
            int16_t y = (int16_t)ctx->args[1];
            int16_t w = (int16_t)ctx->args[2];
            int16_t h = (int16_t)ctx->args[3];
            uint8_t color = (uint8_t)(ctx->args[4] & 0xFF);
            // mode = (ctx->args[4] >> 8) & 0xFF — reserved (line-width
            // / dash / blend, TBD), ignored at M17.
            if (fill) draw_rect_filled (ctx, x, y, w, h, color);
            else      draw_rect_outline(ctx, x, y, w, h, color);
            break;
        }
        case BUS_DRAW_OP_FILL: {
            // Flood-fill: 3 args (x, y, colour). NOT paired with op[7]
            // — it's its own primitive, not "RECT-fill".
            int16_t x = (int16_t)ctx->args[0];
            int16_t y = (int16_t)ctx->args[1];
            uint8_t color = (uint8_t)(ctx->args[2] & 0xFF);
            draw_flood_fill(ctx, x, y, color);
            break;
        }
        case BUS_DRAW_OP_OVAL: {
            int16_t cx    = (int16_t)ctx->args[0];
            int16_t cy    = (int16_t)ctx->args[1];
            int16_t rx    = (int16_t)ctx->args[2];
            int16_t ry    = (int16_t)ctx->args[3];
            uint8_t color = (uint8_t)(ctx->args[4] & 0xFF);
            if (fill) draw_oval_filled (ctx, cx, cy, rx, ry, color);
            else      draw_oval_outline(ctx, cx, cy, rx, ry, color);
            break;
        }
        case BUS_DRAW_OP_ARC: {
            int16_t  cx       = (int16_t)ctx->args[0];
            int16_t  cy       = (int16_t)ctx->args[1];
            int16_t  rx       = (int16_t)ctx->args[2];
            int16_t  ry       = (int16_t)ctx->args[3];
            uint16_t start_a  = ctx->args[4];
            uint16_t end_a    = ctx->args[5];
            uint8_t  color    = (uint8_t)(ctx->args[6] & 0xFF);
            if (fill) draw_pie         (ctx, cx, cy, rx, ry, start_a, end_a, color);
            else      draw_arc_outline (ctx, cx, cy, rx, ry, start_a, end_a, color);
            break;
        }
        case BUS_DRAW_OP_BEZIER: {
            // 4 control points (P0..P3) + colour. After render,
            // chain_x/y holds P3 for any subsequent BEZIER_TO.
            int16_t x0 = (int16_t)ctx->args[0], y0 = (int16_t)ctx->args[1];
            int16_t x1 = (int16_t)ctx->args[2], y1 = (int16_t)ctx->args[3];
            int16_t x2 = (int16_t)ctx->args[4], y2 = (int16_t)ctx->args[5];
            int16_t x3 = (int16_t)ctx->args[6], y3 = (int16_t)ctx->args[7];
            uint8_t color = (uint8_t)(ctx->args[8] & 0xFF);
            draw_cubic_bezier(ctx, x0, y0, x1, y1, x2, y2, x3, y3, color);
            break;
        }
        case BUS_DRAW_OP_BEZIER_TO: {
            // P0 = previous endpoint (chain_x/y); 3 new control
            // points + colour. If no prior BEZIER, P0 = (0, 0).
            int16_t x0 = ctx->chain_x,            y0 = ctx->chain_y;
            int16_t x1 = (int16_t)ctx->args[0],   y1 = (int16_t)ctx->args[1];
            int16_t x2 = (int16_t)ctx->args[2],   y2 = (int16_t)ctx->args[3];
            int16_t x3 = (int16_t)ctx->args[4],   y3 = (int16_t)ctx->args[5];
            uint8_t color = (uint8_t)(ctx->args[6] & 0xFF);
            draw_cubic_bezier(ctx, x0, y0, x1, y1, x2, y2, x3, y3, color);
            break;
        }
        default:
            // Already trapped at beat 0 (draw_beat_count returns 0 for
            // unknowns). This case is unreachable but defensive.
            break;
    }
    // Stats keyed by base op. Filled / outline RECT share a slot.
    if (base < (sizeof(ctx->cmd_count) / sizeof(ctx->cmd_count[0]))) {
        ctx->cmd_count[base]++;
    }
}

// ---- Beat handler --------------------------------------------------------
void draw_beat(draw_ctx_t *ctx, uint32_t payload) {
    if (ctx->beats_remaining == 0) {
        // Beat 0 of a new opcode: payload[7:0] = op, payload[23:8] = arg0.
        const uint8_t  op       = (uint8_t)(payload & 0xFFu);
        const uint16_t arg0     = (uint16_t)((payload >> 8) & 0xFFFFu);
        const uint8_t  cnt      = draw_beat_count(op);
        if (cnt == 0) {
            // Unknown opcode — desync risk. The FPGA-side rp_tx is
            // supposed to reject these at submission time, so this
            // mostly catches transmission corruption.
            ctx->bad_op_count++;
            return;
        }
        ctx->op = op;
        ctx->args[0] = arg0;
        ctx->arg_idx = 1;
        if (cnt == 1) {
            // Single-beat opcode (NOP_DRAW): execute now.
            draw_execute(ctx);
            ctx->arg_idx = 0;
            return;
        }
        ctx->beats_remaining = (uint8_t)(cnt - 1);
    } else {
        // Continuation beat: payload[15:0] = arg, payload[23:16] = 0.
        if ((payload >> 16) & 0xFFu) {
            // Reserved upper byte non-zero — sync-loss flag per the
            // wire protocol. Count it but keep going (the contract
            // says "receiver may trap"; we count and continue).
            ctx->bad_reserved_count++;
        }
        const uint16_t v = (uint16_t)(payload & 0xFFFFu);
        if (ctx->arg_idx < DRAW_MAX_ARGS) {
            ctx->args[ctx->arg_idx++] = v;
        }
        ctx->beats_remaining--;
        if (ctx->beats_remaining == 0) {
            draw_execute(ctx);
            ctx->arg_idx = 0;
        }
    }
}

// ---- Init ----------------------------------------------------------------
void draw_init(draw_ctx_t *ctx, uint8_t *fb, uint16_t width, uint16_t height) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->fb     = fb;
    ctx->width  = width;
    ctx->height = height;
}
