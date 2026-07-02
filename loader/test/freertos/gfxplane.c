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
    {
        volatile uint32_t *xl = (volatile uint32_t *)0x43C00500u;  /* XT_BLK_XLCTL */
        xl[0] = 1920; xl[1] = 1080;     /* X,Y: off the bottom-right corner */
        xl[2] = 1;    xl[3] = 1;        /* W,H: 1x1 */
        xl[4] = 1;                      /* scale */
        xl[5] = 1;                      /* EN: commit the rect (clk_pix CDC) */
    }
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
