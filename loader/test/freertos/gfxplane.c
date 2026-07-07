/*
 * gfxplane.c — the OS-owned display plane.
 *
 * One RGBA-8888 plane at FB_BASE (0x3000_0000), the compositor-plane address in
 * the Zynq memory map. Apps query its descriptor (SYS_fb_info), draw into it,
 * then SYS_fb_present.
 *
 * On HW the PL compositor free-runs, scanning this plane out to HDMI every frame
 * (1920x1080, stride 2048 words). The plane is mapped Normal NON-cacheable, so CPU
 * writes hit DDR directly and the compositor sees them — present is just a barrier,
 * not a cache flush. gfxplane_init() clears it at boot (else the compositor scans
 * uninitialised DDR = full-screen noise).
 *
 * On qemu (no display) FB is small and present ASCII-dumps it so we can see it.
 */
#include <stdint.h>
#include "bare_rt.h"

#define FB_BASE   0x30000000u
/* WM backdrop buffer — the reserved 16 MB wallpaper region in the PL0-RW graphics
 * window (docs/Zynq/memory-map.md). The desktop decodes the wallpaper into it and
 * hands it to gem_wm as a desk-sized surface; keeping it out of the 8 MB per-process
 * heap (a 1080p surface is ~8 MB on its own). Packed stride (= width). */
#define WALLPAPER_BASE 0x33000000u
/* drag-overlay pixel buffer — reserved 16 MB (docs/Zynq/memory-map.md); the
 * desktop copies the window being dragged here and the COMP plane composites it. */
#define DRAG_BASE 0x32000000u

#ifdef XT_HW

#define FB_W      1920
#define FB_H      1080
#define FB_STRIDE 2048                 /* words per row (8192 B); compositor's stride */

void fb_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_STRIDE; *addr = FB_BASE;
}

void fb_wallpaper_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_W; *addr = WALLPAPER_BASE;
}

void fb_present(void)
{
    __asm__ volatile("dsb");           /* order the plane writes; compositor scans DDR */
}

/* The XL plane (plane 1) is a HARDWIRED centred overlay the compositor always
 * composites, reading the ANTIC->DDR writeback triple-buffer (HP3). With no
 * emulator running those buffers are uninitialised, so the overlay scans garbage
 * (visible on a cold SD boot; a warm JTAG reload masked it with stale pixels).
 * The compositor is alpha-blind, so clear them to opaque black -> clean overlay.
 * Mirrors hdl/fpga_xt_top.sv: XL_BASE_{0,1,2} 1 MB apart, 320x192 RGBA. */
#define XL_BASE0   0x31000000u
#define XL_SLOT    0x00100000u         /* buffers 1 MB apart */
#define XL_WORDS   (320u * 192u)       /* XL_SRC_W * XL_SRC_H, RGBA words */

void overlay_set(int en, int x, int y, int w, int h);   /* defined below; used in init */

/* clear to opaque black (compositor uses bits [31:8] as RGB). Pre-scheduler. */
void gfxplane_init(void)
{
    volatile uint32_t *p = (volatile uint32_t *)FB_BASE;
    for (uint32_t i = 0; i < (uint32_t)FB_H * FB_STRIDE; i++) p[i] = 0x000000FFu;
    for (int b = 0; b < 3; b++) {      /* the XL writeback triple-buffer */
        volatile uint32_t *x = (volatile uint32_t *)(XL_BASE0 + (uint32_t)b * XL_SLOT);
        for (uint32_t i = 0; i < XL_WORDS; i++) x[i] = 0x000000FFu;
    }
    /* Hide the always-on XL emulation plane (no emulator running): the XLCTL GP0
     * block lets the A9 place plane 1 at an arbitrary rect — put it 1x1 off-screen.
     * EN=1 adopts these regs; EN=0 would be the legacy centred placement that
     * composited over the middle of the desktop. (GP0 @0x43C0_0000 = Device.) */
    xl_window_set(0, 0, 0, 0, 0);
    overlay_set(1, 1920, 1080, 1, 1);  /* overlay ALWAYS enabled, parked 1x1 off-screen. Toggling
                                        * EN 0<->1 per grab/release glitched the compositor (link
                                        * drop); grab/release now just MOVE it, like the smooth
                                        * drag motion.  Mirrors the always-on XL plane above. */
    __asm__ volatile("dsb");
}

/* Place the XL emulation plane at an on-screen rect (the desktop frames the live
 * emulation inside a GEM window's work area — SYS_xl_window).  scale = integer
 * pixel zoom 1..5; scale <= 0 hides the plane (1x1 off-screen — EN stays 1 so
 * the legacy centred placement never comes back). */
void xl_window_set(int x, int y, int w, int h, int scale)
{
    volatile uint32_t *xl = (volatile uint32_t *)0x43C00500u;  /* XT_BLK_XLCTL */
    if (scale <= 0) { x = 1920; y = 1080; w = 1; h = 1; scale = 1; }
    if (scale > 5) scale = 5;
    xl[0] = (uint32_t)x & 0x0FFFu;
    xl[1] = (uint32_t)y & 0x0FFFu;
    xl[2] = (uint32_t)w & 0x0FFFu;
    xl[3] = (uint32_t)h & 0x0FFFu;
    xl[4] = (uint32_t)scale & 0x7u;
    xl[5] = 1;                          /* EN: commit the rect (clk_pix CDC) */
    __asm__ volatile("dsb");
}

/* Drag-overlay plane (COMP GP0 block @0x43C0_0200): composite a w*h RGBA patch
 * from DRAG_BASE (packed, stride = w<<2 bytes) at on-screen (x,y).  Used for
 * tear-free window drag — the client copies the window into DRAG_BASE once, then
 * MOVES it by rewriting X/Y (no plane redraw).  en=0 hides it. */
void overlay_set(int en, int x, int y, int w, int h)
{
    volatile uint32_t *ovl = (volatile uint32_t *)0x43C00200u;  /* XT_BLK_COMP */
    ovl[1] = DRAG_BASE;                 /* OVL_BASE (0x04) */
    ovl[2] = (uint32_t)x & 0x0FFFu;     /* OVL_X    (0x08) */
    ovl[3] = (uint32_t)y & 0x0FFFu;     /* OVL_Y    (0x0C) */
    ovl[4] = (uint32_t)w & 0x0FFFu;     /* OVL_W    (0x10; stride = w<<2) */
    ovl[5] = (uint32_t)h & 0x0FFFu;     /* OVL_H    (0x14) */
    ovl[0] = en ? 1u : 0u;              /* OVL_EN   (0x00) — commits the config */
    __asm__ volatile("dsb");
}

#else  /* qemu: small plane + ASCII dump */

#define FB_W 200
#define FB_H 120

void fb_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_W; *addr = FB_BASE;
}

void fb_wallpaper_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_W; *addr = WALLPAPER_BASE;
}

void gfxplane_init(void) { }

/* no XL compositor plane on qemu — accept and ignore */
void xl_window_set(int x, int y, int w, int h, int scale)
{
    (void)x; (void)y; (void)w; (void)h; (void)scale;
}
void overlay_set(int en, int x, int y, int w, int h)
{
    (void)en; (void)x; (void)y; (void)w; (void)h;
}

void fb_present(void)
{
    const uint32_t *px = (const uint32_t *)FB_BASE;
    static const char ramp[] = " .:-=+*#%@";
    char line[FB_W + 2];
    for (int y = 0; y < FB_H; y += 2) {                 /* 2 rows -> ~square chars */
        int n = 0;
        for (int x = 0; x < FB_W; x++) {
            uint32_t p = px[y * FB_W + x];
            int r = (p >> 24) & 255, g = (p >> 16) & 255, b = (p >> 8) & 255;
            int ink = 255 - (r * 30 + g * 59 + b * 11) / 100;   /* dark ink -> dense */
            line[n++] = ramp[ink * 9 / 255];
        }
        line[n++] = '\n';
        rt_write(line, n);
    }
}

#endif
