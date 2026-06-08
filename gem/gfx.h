// gfx.h — portable surface + low-level backend primitives for the GEM core.
//
// The GEM service (VDI/AES/window-manager/theming) is platform-neutral C and
// only ever calls the primitives below — never SDL or the blitter directly.
// Two backends implement them:
//   - gfx_soft.c : software, for the SDL host testbed (fast iterate, mouse).
//   - gfx_a9.c   : the Zynq hardware blitter (later, on the A9).
// Selected at link time: the testbed links gfx_soft.c, the A9 build gfx_a9.c.
//
// One pixel format everywhere: RGBA-8888 packed 0xRRGGBBAA (R in the MSB, A in
// the LSB) — matches the on-DDR XL framebuffer the writeback produces, so the
// A9 backend is a straight pass-through to the compositor surface.

#ifndef GEM_GFX_H
#define GEM_GFX_H

#include <stdint.h>

typedef struct {
    int       w, h;      // size in pixels
    int       stride;    // pixels per row (>= w; allows sub-surfaces later)
    uint32_t *px;        // stride*h pixels, RGBA-8888 (0xRRGGBBAA)
} gfx_surface;

#define GFX_RGBA(r, g, b, a) \
    (((uint32_t)(uint8_t)(r) << 24) | ((uint32_t)(uint8_t)(g) << 16) | \
     ((uint32_t)(uint8_t)(b) <<  8) |  (uint32_t)(uint8_t)(a))
#define GFX_RGB(r, g, b)  GFX_RGBA((r), (g), (b), 0xFF)

// Surface lifecycle (host: malloc; A9: a DDR3 region from the allocator).
gfx_surface *gfx_surface_alloc(int w, int h);
void         gfx_surface_free(gfx_surface *s);

// ---- Backend primitives (software in gfx_soft.c, blitter on A9) -----------
// All clip to the destination surface; out-of-range args are safe no-ops.
void gfx_fill_rect(gfx_surface *s, int x, int y, int w, int h, uint32_t rgba);
void gfx_blit(gfx_surface *dst, int dx, int dy,
              const gfx_surface *src, int sx, int sy, int w, int h);
void gfx_line(gfx_surface *s, int x0, int y0, int x1, int y1, uint32_t rgba);

// Blit an 8-bit alpha-coverage rect to (dx,dy), alpha-blending `rgba` (the
// coverage byte is the alpha): out = rgba*cov + dst*(255-cov), dst alpha
// opaque.  `cov` is the coverage buffer (row stride cov_stride bytes); the
// visible sub-rect is (sx,sy,w,h) within it.  This is the glyph-compositing
// path — the A9 backend routes it to the hardware blitter (SRC_BLIT coverage)
// when the dest is the plane; the host does the CPU blend.  Caller has already
// clipped (sx,sy,w,h)/(dx,dy) to the destination.
void gfx_blit_coverage(gfx_surface *dst, int dx, int dy,
                       const uint8_t *cov, int cov_stride,
                       int sx, int sy, int w, int h, uint32_t rgba);

// End of a text run: the A9 backend batches glyph coverage blits into a shared
// atlas and enqueues them without waiting; this drains the queue and resets the
// atlas.  Call it after each string's glyph loop.  No-op on the host backend.
void gfx_text_flush(void);

#endif // GEM_GFX_H
