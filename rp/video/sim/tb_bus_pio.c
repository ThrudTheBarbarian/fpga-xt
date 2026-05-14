// tb_bus_pio.c — host-built C model of the RP-side bus dispatch.
//
// Mirrors hdl/rp_bus_mock.sv. Both models read the same wire-format
// constants from rp/src/bus_server.h (C) and hdl/bus_opcodes.vh
// (SV); the makefile target `verify_opcodes` cross-checks the two
// files via grep so they cannot drift.
//
// What this test validates:
//   1. BUS_TAG_* constants are 0/1/2/3 (compile-time asserts).
//   2. The C dispatch logic produces the same FETCH responses as the
//      SV mock for a sequence of SET/FETCH ops.
//
// Build:  make -C rp/sim
// Run:    ./build/tb_bus_pio  → exits 0 on success.

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/bus_server.h"
#include "../src/draw.h"

#include <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ---- Compile-time wire-format checks ---------------------------------
_Static_assert(BUS_TAG_FETCH == 0u, "FETCH tag must be 0 (matches bus_opcodes.vh)");
_Static_assert(BUS_TAG_SET   == 1u, "SET tag must be 1");
_Static_assert(BUS_TAG_DRAW  == 2u, "DRAW tag must be 2");
_Static_assert(BUS_TAG_NOP   == 3u, "NOP tag must be 3");

_Static_assert(BUS_DRAW_OP_NOP       == 0u, "NOP_DRAW op must be 0");
_Static_assert(BUS_DRAW_OP_LINE      == 1u, "LINE op must be 1");
_Static_assert(BUS_DRAW_OP_RECT      == 2u, "RECT op must be 2");
_Static_assert(BUS_DRAW_OP_FILL      == 3u, "FILL op must be 3");
_Static_assert(BUS_DRAW_OP_OVAL      == 4u, "OVAL op must be 4");
_Static_assert(BUS_DRAW_OP_ARC       == 5u, "ARC op must be 5");
_Static_assert(BUS_DRAW_OP_BEZIER    == 6u, "BEZIER op must be 6");
_Static_assert(BUS_DRAW_OP_BEZIER_TO == 7u, "BEZIER_TO op must be 7");
_Static_assert(BUS_DRAW_FILL_FLAG    == 0x80u, "fill-flag mask must be op[7]");

// ---- C model -----------------------------------------------------------
// 64×64 framebuffer for DRAW tests; flat byte addressing for FETCH/SET
// (a + 1 < FB_BYTES) — same array, different access patterns.
#define MODEL_FB_W      64u
#define MODEL_FB_H      64u
#define MODEL_FB_BYTES  (MODEL_FB_W * MODEL_FB_H)

typedef struct {
    uint8_t      fb[MODEL_FB_BYTES];
    int          set_addr_pending;
    uint32_t     set_addr;

    draw_ctx_t   draw;

    uint32_t fetch_count;
    uint32_t set_count;
    uint32_t bad_tag_count;
    uint32_t set_misalign_count;
} model_t;

static void model_reset(model_t *m) {
    memset(m, 0, sizeof(*m));
    draw_init(&m->draw, m->fb, (uint16_t)MODEL_FB_W, (uint16_t)MODEL_FB_H);
}

// Process one bus beat. If the beat is a FETCH, write the 16-bit
// response into *fetch_response and set *has_response to 1. Else
// has_response stays 0.
static void model_step(model_t *m,
                       uint8_t  tag,
                       uint32_t payload,
                       uint16_t *fetch_response,
                       int      *has_response) {
    *has_response = 0;
    *fetch_response = 0;

    switch (tag) {
        case BUS_TAG_NOP:
            m->set_addr_pending = 0;
            break;
        case BUS_TAG_FETCH: {
            const uint32_t a = payload & 0xFFFFFFu;
            uint16_t r = 0;
            if (a + 1u < MODEL_FB_BYTES) {
                r = (uint16_t)m->fb[a] | ((uint16_t)m->fb[a + 1u] << 8);
            }
            *fetch_response = r;
            *has_response = 1;
            m->fetch_count++;
            m->set_addr_pending = 0;
            break;
        }
        case BUS_TAG_SET:
            if (!m->set_addr_pending) {
                m->set_addr_pending = 1;
                m->set_addr = payload & 0xFFFFFFu;
                if (m->set_addr & 1u) m->set_misalign_count++;
            } else {
                const uint32_t a = m->set_addr;
                if (a + 1u < MODEL_FB_BYTES) {
                    m->fb[a]      = (uint8_t)(payload & 0xFFu);
                    m->fb[a + 1u] = (uint8_t)((payload >> 8) & 0xFFu);
                }
                m->set_count++;
                m->set_addr_pending = 0;
            }
            break;
        case BUS_TAG_DRAW:
            // M17-3: route to the draw module which gathers the per-op
            // beat sequence and renders into the framebuffer.
            draw_beat(&m->draw, payload);
            m->set_addr_pending = 0;
            break;
        default:
            m->bad_tag_count++;
            m->set_addr_pending = 0;
            break;
    }
}

// ---- Test harness ------------------------------------------------------
static uint32_t lcg(uint32_t *s) { *s = (*s) * 1664525u + 1013904223u; return *s; }

// Issue a complete DRAW command as the right number of bus beats. Beat 0
// packs op + arg0; beats 1..N-1 carry arg1..arg(N-1) in the low 16 bits.
// The FPGA-side rp_tx serialises the same way (see hdl/rp_tx.sv).
static void issue_draw7(model_t *m, uint8_t op,
                        uint16_t a0, uint16_t a1, uint16_t a2, uint16_t a3,
                        uint16_t a4, uint16_t a5, uint16_t a6) {
    uint16_t r; int has_r;
    const uint32_t beat0 = ((uint32_t)a0 << 8) | (uint32_t)op;
    model_step(m, BUS_TAG_DRAW, beat0, &r, &has_r);
    int more = 0;
    switch (op & 0x7Fu) {
        case BUS_DRAW_OP_NOP:       more = 0; break;
        case BUS_DRAW_OP_LINE:      more = 4; break;
        case BUS_DRAW_OP_RECT:      more = 4; break;
        case BUS_DRAW_OP_FILL:      more = 2; break;
        case BUS_DRAW_OP_OVAL:      more = 4; break;
        case BUS_DRAW_OP_ARC:       more = 6; break;
        case BUS_DRAW_OP_BEZIER_TO: more = 6; break;
        default:                     more = 0; break;
    }
    if (more >= 1) model_step(m, BUS_TAG_DRAW, (uint32_t)a1, &r, &has_r);
    if (more >= 2) model_step(m, BUS_TAG_DRAW, (uint32_t)a2, &r, &has_r);
    if (more >= 3) model_step(m, BUS_TAG_DRAW, (uint32_t)a3, &r, &has_r);
    if (more >= 4) model_step(m, BUS_TAG_DRAW, (uint32_t)a4, &r, &has_r);
    if (more >= 5) model_step(m, BUS_TAG_DRAW, (uint32_t)a5, &r, &has_r);
    if (more >= 6) model_step(m, BUS_TAG_DRAW, (uint32_t)a6, &r, &has_r);
}

// 9-arg form for BEZIER (4 control points + colour).
static void issue_draw9(model_t *m, uint8_t op,
                        uint16_t a0, uint16_t a1, uint16_t a2, uint16_t a3,
                        uint16_t a4, uint16_t a5, uint16_t a6, uint16_t a7,
                        uint16_t a8) {
    uint16_t r; int has_r;
    const uint32_t beat0 = ((uint32_t)a0 << 8) | (uint32_t)op;
    model_step(m, BUS_TAG_DRAW, beat0, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a1, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a2, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a3, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a4, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a5, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a6, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a7, &r, &has_r);
    model_step(m, BUS_TAG_DRAW, (uint32_t)a8, &r, &has_r);
}

// 5-arg shim for the ops shipping in M17 / M18-1.
static void issue_draw(model_t *m, uint8_t op,
                       uint16_t a0, uint16_t a1, uint16_t a2,
                       uint16_t a3, uint16_t a4) {
    issue_draw7(m, op, a0, a1, a2, a3, a4, 0, 0);
}

// Software oracles — these mirror draw.c's primitives. Used to build
// the expected framebuffer for comparison.
static void oracle_rect_filled(uint8_t *fb, int W, int H,
                                int x, int y, int w, int h, uint8_t color) {
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w; if (x1 > W) x1 = W;
    int y1 = y + h; if (y1 > H) y1 = H;
    for (int r = y0; r < y1; r++)
        for (int c = x0; c < x1; c++)
            fb[r * W + c] = color;
}
static void oracle_rect(uint8_t *fb, int W, int H,
                        int x, int y, int w, int h, uint8_t color) {
    if (w <= 0 || h <= 0) return;
    for (int c = x; c < x + w; c++) {
        if (c >= 0 && c < W) {
            if (y >= 0 && y < H)            fb[y * W + c] = color;
            int b = y + h - 1;
            if (b >= 0 && b < H && b != y)  fb[b * W + c] = color;
        }
    }
    for (int r = y + 1; r < y + h - 1; r++) {
        if (r < 0 || r >= H) continue;
        int l = x, ri = x + w - 1;
        if (l  >= 0 && l  < W) fb[r * W + l]  = color;
        if (ri >= 0 && ri < W && ri != l) fb[r * W + ri] = color;
    }
}
static void oracle_line(uint8_t *fb, int W, int H,
                        int x0, int y0, int x1, int y1, uint8_t color) {
    int dx =  abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    while (1) {
        if (x0 >= 0 && x0 < W && y0 >= 0 && y0 < H)
            fb[y0 * W + x0] = color;
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

// OVAL oracles — call into draw.c's primitives via the dispatcher
// is not an option (the FB write would conflict), so duplicate the
// algorithm here. Keep these BIT-FOR-BIT identical to the renderers
// in rp/src/draw.c so the test catches regressions on either side.
static void oracle_put4(uint8_t *fb, int W, int H,
                        int cx, int cy, int x, int y, uint8_t c) {
    if (cx + x >= 0 && cx + x < W && cy + y >= 0 && cy + y < H) fb[(cy + y) * W + cx + x] = c;
    if (cx - x >= 0 && cx - x < W && cy + y >= 0 && cy + y < H) fb[(cy + y) * W + cx - x] = c;
    if (cx + x >= 0 && cx + x < W && cy - y >= 0 && cy - y < H) fb[(cy - y) * W + cx + x] = c;
    if (cx - x >= 0 && cx - x < W && cy - y >= 0 && cy - y < H) fb[(cy - y) * W + cx - x] = c;
}

static void oracle_oval_outline(uint8_t *fb, int W, int H,
                                int cx, int cy, int rx, int ry, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 && ry == 0) {
        if (cx >= 0 && cx < W && cy >= 0 && cy < H) fb[cy * W + cx] = color;
        return;
    }
    if (rx == 0) { for (int y = -ry; y <= ry; y++) if (cx >= 0 && cx < W && cy + y >= 0 && cy + y < H) fb[(cy + y) * W + cx] = color; return; }
    if (ry == 0) { for (int x = -rx; x <= rx; x++) if (cx + x >= 0 && cx + x < W && cy >= 0 && cy < H) fb[cy * W + cx + x] = color; return; }
    long rx2 = (long)rx * rx, ry2 = (long)ry * ry;
    long tworx2 = 2 * rx2, twory2 = 2 * ry2;
    long x = 0, y = ry;
    long px = 0, py = tworx2 * y;
    long p = (long)(ry2 - rx2 * (long)ry + (rx2 + 2) / 4);
    while (px < py) {
        oracle_put4(fb, W, H, cx, cy, (int)x, (int)y, color);
        x++;
        px += twory2;
        if (p < 0)            p += ry2 + px;
        else { y--; py -= tworx2; p += ry2 + px - py; }
    }
    p = (long)(ry2 * (2 * x + 1) * (2 * x + 1) / 4
             + rx2 * (y - 1) * (y - 1)
             - rx2 * ry2);
    while (y >= 0) {
        oracle_put4(fb, W, H, cx, cy, (int)x, (int)y, color);
        y--;
        py -= tworx2;
        if (p > 0)            p += rx2 - py;
        else { x++; px += twory2; p += rx2 - py + px; }
    }
}

static long oracle_isqrt_l(long long n) {
    if (n < 2) return (long)(n < 0 ? 0 : n);
    long long x = n / 2, last = 0;
    for (int i = 0; i < 32 && x != last; i++) { last = x; x = (x + n / x) / 2; }
    while (x * x > n) x--;
    return (long)x;
}

static void oracle_oval_filled(uint8_t *fb, int W, int H,
                               int cx, int cy, int rx, int ry, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 || ry == 0) { oracle_oval_outline(fb, W, H, cx, cy, rx, ry, color); return; }
    const long long rx2 = (long long)rx * rx, ry2 = (long long)ry * ry;
    for (int dy = -ry; dy <= ry; dy++) {
        const long long num = rx2 * (ry2 - (long long)dy * dy);
        const long hx = oracle_isqrt_l(num / ry2);
        int x0 = cx - (int)hx, x1 = cx + (int)hx;
        if (x0 < 0) x0 = 0;
        if (x1 >= W) x1 = W - 1;
        const int y = cy + dy;
        if (y < 0 || y >= H) continue;
        if (x0 > x1) continue;
        memset(&fb[y * W + x0], color, (size_t)(x1 - x0 + 1));
    }
}

static int oracle_point_in_arc(int dx, int dy, uint16_t start_a, uint16_t span_a) {
    if (dx == 0 && dy == 0) return 1;
    float ang = atan2f((float)dy, (float)dx);
    if (ang < 0.0f) ang += 2.0f * (float)M_PI;
    uint32_t theta = (uint32_t)(ang * (65536.0f / (2.0f * (float)M_PI)));
    if (theta > 65535u) theta = 65535u;
    uint16_t delta = (uint16_t)((uint16_t)theta - start_a);
    return delta <= span_a;
}

static void oracle_arc_outline(uint8_t *fb, int W, int H,
                               int cx, int cy, int rx, int ry,
                               uint16_t start_a, uint16_t end_a, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    const uint16_t span = (uint16_t)(end_a - start_a);

    if (rx == 0 && ry == 0) {
        if (oracle_point_in_arc(0, 0, start_a, span) &&
            cx >= 0 && cx < W && cy >= 0 && cy < H) fb[cy * W + cx] = color;
        return;
    }
    if (rx == 0 || ry == 0) {
        // Skip degenerate cases for the oracle (algorithmic match isn't
        // worth duplicating; tests use rx, ry > 0).
        return;
    }

    long rx2 = (long)rx * rx, ry2 = (long)ry * ry;
    long tworx2 = 2 * rx2, twory2 = 2 * ry2;
    long x = 0, y = ry;
    long px = 0, py = tworx2 * y;
    long p = (long)(ry2 - rx2 * (long)ry + (rx2 + 2) / 4);
    #define ARC_PUT(_dx,_dy) do { \
        if (oracle_point_in_arc((int)(_dx), (int)(_dy), start_a, span)) { \
            int _xx = cx + (int)(_dx), _yy = cy + (int)(_dy); \
            if (_xx >= 0 && _xx < W && _yy >= 0 && _yy < H) fb[_yy * W + _xx] = color; \
        } \
    } while (0)
    while (px < py) {
        ARC_PUT( x,  y); ARC_PUT(-x,  y); ARC_PUT( x, -y); ARC_PUT(-x, -y);
        x++;
        px += twory2;
        if (p < 0) p += ry2 + px;
        else { y--; py -= tworx2; p += ry2 + px - py; }
    }
    p = (long)(ry2 * (2 * x + 1) * (2 * x + 1) / 4
             + rx2 * (y - 1) * (y - 1)
             - rx2 * ry2);
    while (y >= 0) {
        ARC_PUT( x,  y); ARC_PUT(-x,  y); ARC_PUT( x, -y); ARC_PUT(-x, -y);
        y--;
        py -= tworx2;
        if (p > 0) p += rx2 - py;
        else { x++; px += twory2; p += rx2 - py + px; }
    }
    #undef ARC_PUT
}

static void oracle_pie(uint8_t *fb, int W, int H,
                       int cx, int cy, int rx, int ry,
                       uint16_t start_a, uint16_t end_a, uint8_t color) {
    if (rx < 0) rx = -rx;
    if (ry < 0) ry = -ry;
    if (rx == 0 || ry == 0) return;
    const uint16_t span = (uint16_t)(end_a - start_a);
    const long long rx2 = (long long)rx * rx, ry2 = (long long)ry * ry;
    for (int dy = -ry; dy <= ry; dy++) {
        const long long num = rx2 * (ry2 - (long long)dy * dy);
        const long hx = oracle_isqrt_l(num / ry2);
        const int y = cy + dy;
        if (y < 0 || y >= H) continue;
        for (int dx = -hx; dx <= hx; dx++) {
            const int x = cx + dx;
            if (x < 0 || x >= W) continue;
            if (oracle_point_in_arc(dx, dy, start_a, span))
                fb[y * W + x] = color;
        }
    }
}

static int compare_fb(const uint8_t *got, const uint8_t *want, int n,
                      const char *label) {
    int diffs = 0;
    for (int i = 0; i < n; i++) {
        if (got[i] != want[i]) {
            if (diffs < 4)
                fprintf(stderr, "FAIL %s: fb[%d]=$%02x expected $%02x\n",
                        label, i, got[i], want[i]);
            diffs++;
        }
    }
    return diffs;
}

int main(void) {
    model_t m;
    model_reset(&m);

    // Software shadow that mirrors what we expect to be in the model
    // framebuffer.
    uint8_t shadow[MODEL_FB_BYTES] = {0};

    uint32_t seed = 0xCAFEBABEu;
    int fail_count = 0;

    // Phase 1: 256 SET ops to populate.
    for (int i = 0; i < 256; i++) {
        const uint32_t addr = (uint32_t)(i * 2);
        const uint16_t data = (uint16_t)(lcg(&seed) & 0xFFFFu);
        uint16_t r; int has_r;
        // SET beat 0 (address)
        model_step(&m, BUS_TAG_SET, addr, &r, &has_r);
        // SET beat 1 (data)
        model_step(&m, BUS_TAG_SET, (uint32_t)data, &r, &has_r);
        if (addr + 1 < MODEL_FB_BYTES) {
            shadow[addr]     = (uint8_t)(data & 0xFFu);
            shadow[addr + 1] = (uint8_t)((data >> 8) & 0xFFu);
        }
    }

    // Phase 2: 1024 mixed FETCH/SET ops.
    int fetch_verified = 0;
    for (int op = 0; op < 1024; op++) {
        const uint32_t dice = lcg(&seed) & 0x3u;
        const uint32_t addr = (uint32_t)(lcg(&seed) & 0xFFEu);
        const uint16_t data = (uint16_t)(lcg(&seed) & 0xFFFFu);
        uint16_t r; int has_r;

        switch (dice) {
            case 0: case 1: { // FETCH
                model_step(&m, BUS_TAG_FETCH, addr, &r, &has_r);
                if (!has_r) {
                    fprintf(stderr, "FAIL: FETCH produced no response\n");
                    fail_count++;
                    break;
                }
                const uint16_t expected =
                    (uint16_t)shadow[addr] | ((uint16_t)shadow[addr + 1] << 8);
                if (r != expected) {
                    fprintf(stderr,
                            "FAIL fetch[%d] addr=$%06x: got $%04x, expected $%04x\n",
                            fetch_verified, addr, r, expected);
                    fail_count++;
                }
                fetch_verified++;
                break;
            }
            case 2: { // SET
                model_step(&m, BUS_TAG_SET, addr, &r, &has_r);
                model_step(&m, BUS_TAG_SET, (uint32_t)data, &r, &has_r);
                if (addr + 1 < MODEL_FB_BYTES) {
                    shadow[addr]     = (uint8_t)(data & 0xFFu);
                    shadow[addr + 1] = (uint8_t)((data >> 8) & 0xFFu);
                }
                break;
            }
            case 3: { // NOP
                model_step(&m, BUS_TAG_NOP, 0, &r, &has_r);
                model_step(&m, BUS_TAG_NOP, 0, &r, &has_r);
                model_step(&m, BUS_TAG_NOP, 0, &r, &has_r);
                break;
            }
        }
    }

    if (m.bad_tag_count != 0) {
        fprintf(stderr, "FAIL: bad_tag_count=%u\n", m.bad_tag_count);
        fail_count++;
    }
    if (m.set_misalign_count != 0) {
        fprintf(stderr, "FAIL: set_misalign_count=%u\n", m.set_misalign_count);
        fail_count++;
    }

    // ---- M17-3: DRAW dispatch tests --------------------------------------
    // Clear the FB to zero so each DRAW phase compares against a clean
    // canvas (Phase 1+2 left random data behind from FETCH/SET work).
    // We do NOT reset the model — that would wipe set_count/fetch_count
    // and lose the totals from Phases 1+2. draw_init() is also already
    // done from model_reset() at the top; the dispatcher state is
    // already idle (no DRAW-tagged beats have been issued yet).
    memset(m.fb, 0, sizeof(m.fb));
    uint8_t expected[MODEL_FB_BYTES];
    memset(expected, 0, sizeof(expected));

    // Phase 3: RECT-filled (op[7]=1) — solid rectangle.
    {
        const uint8_t color = 0x42;
        const int x = 4, y = 6, w = 16, h = 8;
        issue_draw(&m, BUS_DRAW_OP_RECT | 0x80,
                   (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h, color);
        oracle_rect_filled(expected, MODEL_FB_W, MODEL_FB_H, x, y, w, h, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "RECT-fill") != 0) fail_count++;
    }

    // Phase 4: LINE — non-trivial diagonal.
    {
        const uint8_t color = 0xC8;
        const int x0 = 2, y0 = 2, x1 = 50, y1 = 30;
        issue_draw(&m, BUS_DRAW_OP_LINE,
                   (uint16_t)x0, (uint16_t)y0, (uint16_t)x1, (uint16_t)y1, color);
        oracle_line(expected, MODEL_FB_W, MODEL_FB_H, x0, y0, x1, y1, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "LINE") != 0) fail_count++;
    }

    // Phase 5: RECT — outline only (interior pixels untouched).
    {
        const uint8_t color = 0x99;
        const int x = 32, y = 40, w = 20, h = 16;
        issue_draw(&m, BUS_DRAW_OP_RECT,
                   (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h, color);
        oracle_rect(expected, MODEL_FB_W, MODEL_FB_H, x, y, w, h, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "RECT") != 0) fail_count++;
    }

    // Phase 6: NOP_DRAW — no FB change, but cmd_count increments.
    {
        uint32_t before = m.draw.cmd_count[BUS_DRAW_OP_NOP];
        issue_draw(&m, BUS_DRAW_OP_NOP, 0xCAFE, 0, 0, 0, 0);
        if (m.draw.cmd_count[BUS_DRAW_OP_NOP] != before + 1) {
            fprintf(stderr, "FAIL NOP_DRAW: cmd_count %u → %u (expected +1)\n",
                    before, m.draw.cmd_count[BUS_DRAW_OP_NOP]);
            fail_count++;
        }
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "NOP_DRAW") != 0) fail_count++;
    }

    // Phase 7: invalid opcode — bad_op_count increments, FB unchanged.
    {
        uint32_t before = m.draw.bad_op_count;
        // Issue ONE beat with an unknown op — draw module should trap
        // and stay idle; we don't follow up with continuation beats.
        uint16_t r; int has_r;
        const uint32_t beat = (0x4321u << 8) | 0x7Fu; // op=$7F not in table
        model_step(&m, BUS_TAG_DRAW, beat, &r, &has_r);
        if (m.draw.bad_op_count != before + 1) {
            fprintf(stderr, "FAIL invalid op: bad_op_count %u → %u (expected +1)\n",
                    before, m.draw.bad_op_count);
            fail_count++;
        }
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "invalid op") != 0) fail_count++;
    }

    // Phase 8: clipping — RECT-filled partly outside FB. Clear FB +
    // expected to start from a clean canvas; counters keep
    // accumulating across phases.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0x55;
        const int x = (int)MODEL_FB_W - 8, y = (int)MODEL_FB_H - 4, w = 16, h = 8;
        issue_draw(&m, BUS_DRAW_OP_RECT | 0x80,
                   (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h, color);
        oracle_rect_filled(expected, MODEL_FB_W, MODEL_FB_H, x, y, w, h, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "clip") != 0) fail_count++;
    }

    // Phase 9: FILL (flood-fill). Paint a hollow RECT outline as a
    // boundary in colour A; flood-fill the interior from a seed point
    // with colour B. Verify only the interior pixels (where the FB
    // was 0 at fill time) became colour B; the outline stays A; the
    // exterior stays 0.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t outline_c = 0xAA;
        const uint8_t fill_c    = 0x77;
        const int x = 8, y = 12, w = 14, h = 10;
        // Paint the boundary on both the model and the oracle.
        issue_draw(&m, BUS_DRAW_OP_RECT,
                   (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h, outline_c);
        oracle_rect(expected, MODEL_FB_W, MODEL_FB_H, x, y, w, h, outline_c);
        // Seed inside the rectangle.
        const int sx = x + w / 2, sy = y + h / 2;
        issue_draw(&m, BUS_DRAW_OP_FILL,
                   (uint16_t)sx, (uint16_t)sy, fill_c, 0, 0);
        // Oracle: flood-fill the interior (= rect-fill the open
        // region inside the outline).
        oracle_rect_filled(expected, MODEL_FB_W, MODEL_FB_H,
                           x + 1, y + 1, w - 2, h - 2, fill_c);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "flood") != 0) fail_count++;
    }

    // Phase 10: OVAL outline (M18-1).
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0x33;
        const int cx = 32, cy = 32, rx = 20, ry = 12;
        issue_draw(&m, BUS_DRAW_OP_OVAL,
                   (uint16_t)cx, (uint16_t)cy, (uint16_t)rx, (uint16_t)ry, color);
        oracle_oval_outline(expected, MODEL_FB_W, MODEL_FB_H, cx, cy, rx, ry, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "OVAL-outline") != 0) fail_count++;
    }

    // Phase 11: OVAL filled (op[7]=1) — equal radii = circle.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0x66;
        const int cx = 28, cy = 28, rx = 15, ry = 15;     // circle
        issue_draw(&m, BUS_DRAW_OP_OVAL | 0x80,
                   (uint16_t)cx, (uint16_t)cy, (uint16_t)rx, (uint16_t)ry, color);
        oracle_oval_filled(expected, MODEL_FB_W, MODEL_FB_H, cx, cy, rx, ry, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "OVAL-fill (circle)") != 0) fail_count++;
    }

    // Phase 12: OVAL filled with rx != ry (true ellipse) + clipping.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0x88;
        const int cx = 50, cy = 50, rx = 25, ry = 18;   // partly off bottom-right
        issue_draw(&m, BUS_DRAW_OP_OVAL | 0x80,
                   (uint16_t)cx, (uint16_t)cy, (uint16_t)rx, (uint16_t)ry, color);
        oracle_oval_filled(expected, MODEL_FB_W, MODEL_FB_H, cx, cy, rx, ry, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "OVAL-fill (clip)") != 0) fail_count++;
    }

    // Phase 13: ARC outline (M18-2). Quarter-arc from 0° to 90° on a
    // circle. Verify perimeter pixels in the south-east quadrant get
    // painted; pixels in other quadrants are left zero.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0xCC;
        const int cx = 32, cy = 32, rx = 12, ry = 12;
        const uint16_t start_a = 0x0000;     // 0° = +x (east)
        const uint16_t end_a   = 0x4000;     // 90° = +y (south)
        issue_draw7(&m, BUS_DRAW_OP_ARC,
                    (uint16_t)cx, (uint16_t)cy, (uint16_t)rx, (uint16_t)ry,
                    start_a, end_a, color);
        oracle_arc_outline(expected, MODEL_FB_W, MODEL_FB_H,
                           cx, cy, rx, ry, start_a, end_a, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "ARC-outline") != 0) fail_count++;
    }

    // Phase 14: PIE (filled arc). 1/3-revolution wedge.
    memset(m.fb, 0, sizeof(m.fb));
    memset(expected, 0, sizeof(expected));
    {
        const uint8_t color = 0xDE;
        const int cx = 30, cy = 30, rx = 14, ry = 10;
        const uint16_t start_a = 0x2000;     // 45°
        const uint16_t end_a   = 0xA000;     // 225° (sweeps 180° CW)
        issue_draw7(&m, BUS_DRAW_OP_ARC | 0x80,
                    (uint16_t)cx, (uint16_t)cy, (uint16_t)rx, (uint16_t)ry,
                    start_a, end_a, color);
        oracle_pie(expected, MODEL_FB_W, MODEL_FB_H,
                   cx, cy, rx, ry, start_a, end_a, color);
        if (compare_fb(m.fb, expected, MODEL_FB_BYTES, "PIE") != 0) fail_count++;
    }

    // Phase 15: BEZIER (M18.1). Verify the curve passes through P0
    // and P3 (start + end control points) and that the chained
    // endpoint state captured P3 for a follow-up BEZIER_TO.
    memset(m.fb, 0, sizeof(m.fb));
    {
        const uint8_t color = 0xBE;
        const int x0 = 5, y0 = 5;
        const int x1 = 20, y1 = 30;
        const int x2 = 40, y2 = 30;
        const int x3 = 55, y3 = 5;
        issue_draw9(&m, BUS_DRAW_OP_BEZIER,
                    (uint16_t)x0, (uint16_t)y0,
                    (uint16_t)x1, (uint16_t)y1,
                    (uint16_t)x2, (uint16_t)y2,
                    (uint16_t)x3, (uint16_t)y3,
                    color);
        // Endpoints must be painted.
        if (m.fb[y0 * MODEL_FB_W + x0] != color) {
            fprintf(stderr, "FAIL BEZIER P0: fb[%d,%d]=$%02x expected $%02x\n",
                    x0, y0, m.fb[y0 * MODEL_FB_W + x0], color);
            fail_count++;
        }
        if (m.fb[y3 * MODEL_FB_W + x3] != color) {
            fprintf(stderr, "FAIL BEZIER P3: fb[%d,%d]=$%02x expected $%02x\n",
                    x3, y3, m.fb[y3 * MODEL_FB_W + x3], color);
            fail_count++;
        }
        // chain endpoint should now be P3.
        if (m.draw.chain_x != x3 || m.draw.chain_y != y3) {
            fprintf(stderr, "FAIL BEZIER chain: got (%d,%d), expected (%d,%d)\n",
                    m.draw.chain_x, m.draw.chain_y, x3, y3);
            fail_count++;
        }
        // Curve must touch a non-trivial number of pixels (sanity).
        int painted = 0;
        for (int i = 0; i < (int)MODEL_FB_BYTES; i++)
            if (m.fb[i] == color) painted++;
        if (painted < 30) {
            fprintf(stderr, "FAIL BEZIER coverage: only %d pixels painted\n", painted);
            fail_count++;
        }
    }

    // Phase 16: BEZIER_TO chains from the previous endpoint.
    {
        const uint8_t color = 0xCE;
        // P0 is the chain endpoint from Phase 15 = (55, 5).
        const int x0_chained = 55, y0_chained = 5;
        const int x1 = 60, y1 = 20;
        const int x2 = 30, y2 = 35;
        const int x3 = 10, y3 = 45;
        issue_draw7(&m, BUS_DRAW_OP_BEZIER_TO,
                    (uint16_t)x1, (uint16_t)y1,
                    (uint16_t)x2, (uint16_t)y2,
                    (uint16_t)x3, (uint16_t)y3,
                    color);
        // Endpoint at P0 (the chain) should be painted in the new colour.
        if (m.fb[y0_chained * MODEL_FB_W + x0_chained] != color) {
            fprintf(stderr, "FAIL BEZIER_TO P0(chained): fb[%d,%d]=$%02x expected $%02x\n",
                    x0_chained, y0_chained,
                    m.fb[y0_chained * MODEL_FB_W + x0_chained], color);
            fail_count++;
        }
        if (m.fb[y3 * MODEL_FB_W + x3] != color) {
            fprintf(stderr, "FAIL BEZIER_TO P3: fb[%d,%d]=$%02x expected $%02x\n",
                    x3, y3, m.fb[y3 * MODEL_FB_W + x3], color);
            fail_count++;
        }
        if (m.draw.chain_x != x3 || m.draw.chain_y != y3) {
            fprintf(stderr, "FAIL BEZIER_TO chain: got (%d,%d), expected (%d,%d)\n",
                    m.draw.chain_x, m.draw.chain_y, x3, y3);
            fail_count++;
        }
    }

    if (fail_count == 0) {
        printf("*** BUS_PIO OK *** fetches=%d sets=%u "
               "draws={fill=%u line=%u rect=%u nop=%u oval=%u arc=%u "
                      "bez=%u bez_to=%u} bad_op=%u\n",
               fetch_verified, m.set_count,
               m.draw.cmd_count[BUS_DRAW_OP_FILL],
               m.draw.cmd_count[BUS_DRAW_OP_LINE],
               m.draw.cmd_count[BUS_DRAW_OP_RECT],
               m.draw.cmd_count[BUS_DRAW_OP_NOP],
               m.draw.cmd_count[BUS_DRAW_OP_OVAL],
               m.draw.cmd_count[BUS_DRAW_OP_ARC],
               m.draw.cmd_count[BUS_DRAW_OP_BEZIER],
               m.draw.cmd_count[BUS_DRAW_OP_BEZIER_TO],
               m.draw.bad_op_count);
        return 0;
    }
    printf("*** BUS_PIO FAIL *** %d failures\n", fail_count);
    return 1;
}
