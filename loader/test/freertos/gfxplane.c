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

#ifdef XT_HW

#define FB_W      1920
#define FB_H      1080
#define FB_STRIDE 2048                 /* words per row (8192 B); compositor's stride */

void fb_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_STRIDE; *addr = FB_BASE;
}

void fb_present(void)
{
    __asm__ volatile("dsb");           /* order the plane writes; compositor scans DDR */
}

/* clear to opaque black (compositor uses bits [31:8] as RGB). Pre-scheduler. */
void gfxplane_init(void)
{
    volatile uint32_t *p = (volatile uint32_t *)FB_BASE;
    for (uint32_t i = 0; i < (uint32_t)FB_H * FB_STRIDE; i++) p[i] = 0x000000FFu;
    __asm__ volatile("dsb");
}

#else  /* qemu: small plane + ASCII dump */

#define FB_W 200
#define FB_H 120

void fb_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_W; *addr = FB_BASE;
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
