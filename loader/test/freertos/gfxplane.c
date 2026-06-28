/*
 * gfxplane.c — the OS-owned display plane.
 *
 * The OS owns one RGBA-8888 plane at FB_BASE (the same compositor-plane address
 * as the hardware memory map — docs/Zynq/memory-map.md). Apps don't malloc a
 * private surface: they query its descriptor (SYS_fb_info) and draw straight
 * into it, then SYS_fb_present pushes it. On real hardware present hands the
 * plane to the compositor; under qemu (no display) it ASCII-dumps it, so we can
 * see the result. On qemu FB_BASE is just RAM at 0x3000_0000 (within -m 1024).
 */
#include <stdint.h>
#include "bare_rt.h"

#define FB_BASE   0x30000000u
#define FB_W      180
#define FB_H      44

void fb_info(int *w, int *h, int *stride, uint32_t *addr)
{
    *w = FB_W; *h = FB_H; *stride = FB_W; *addr = FB_BASE;
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
