/* fbgrab.c — /bin/fbgrab: dump the framebuffer to a PPM.
 *
 *   fbgrab [out.ppm]      default /tmp/screen.ppm
 *
 * The board has no screenshot, so "what is actually on screen?" was answerable only by
 * looking at the monitor — which is no use to anything automated, and no use at all when the
 * question is "is the chrome there, or is it there and then painted over?".
 *
 * It reads the plane directly (SEC_PLANE is PL0-RW in every space today — RESPONSIBILITIES.md
 * §2), which is exactly the access the M7 gate will close.  When it does, this becomes gemd's
 * to answer, not a client's, and this tool goes with it: it is a DIAGNOSTIC, and it is on the
 * wrong side of the line it is helping to defend.
 *
 * Pixel format is the VDI's: 0xRRGGBBAA (gfx.h GFX_RGBA).
 */
#include <stdint.h>
#include <stddef.h>
#include "usys.h"

static char *u32d(char *p, unsigned v)          /* decimal, no libc */
{
    char t[12]; int n = 0;
    if (!v) t[n++] = '0';
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) *p++ = t[--n];
    return p;
}

int main(int argc, char **argv)
{
    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) {
        static const char e[] = "fbgrab: no display plane\n";
        sys_write(2, e, sizeof e - 1);
        return 1;
    }
    const char *out = (argc > 1) ? argv[1] : "/tmp/screen.ppm";

    int fd = (int)sys_open(out, 0x0241 /* O_WRONLY|O_CREAT|O_TRUNC */);
    if (fd < 0) {
        static const char e[] = "fbgrab: cannot create the output file\n";
        sys_write(2, e, sizeof e - 1);
        return 1;
    }

    char hdr[64], *p = hdr;                     /* P6 <w> <h> 255 */
    *p++ = 'P'; *p++ = '6'; *p++ = '\n';
    p = u32d(p, (unsigned)fb.w); *p++ = ' ';
    p = u32d(p, (unsigned)fb.h); *p++ = '\n';
    *p++ = '2'; *p++ = '5'; *p++ = '5'; *p++ = '\n';
    sys_write(fd, hdr, (unsigned)(p - hdr));

    const uint32_t *px = (const uint32_t *)fb.addr;
    static unsigned char row[4096 * 3];         /* one scanline of RGB */
    for (int y = 0; y < fb.h; y++) {
        const uint32_t *src = px + (size_t)y * (size_t)fb.stride;
        int n = 0;
        for (int x = 0; x < fb.w && x < 4096; x++) {
            uint32_t v = src[x];                /* 0xRRGGBBAA */
            row[n++] = (unsigned char)(v >> 24);
            row[n++] = (unsigned char)(v >> 16);
            row[n++] = (unsigned char)(v >>  8);
        }
        sys_write(fd, row, (unsigned)n);
    }
    sys_close(fd);

    static const char ok[] = "fbgrab: wrote the plane\n";
    sys_write(1, ok, sizeof ok - 1);
    return 0;
}
