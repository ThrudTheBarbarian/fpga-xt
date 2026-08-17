/* fbgrab.c — /bin/fbgrab: dump the framebuffer to a PPM.
 *
 *   fbgrab [out.ppm]      default /tmp/screen.ppm
 *
 * The board has no screenshot, so "what is actually on screen?" was answerable only by
 * looking at the monitor — which is no use to anything automated, and no use at all when the
 * question is "is the chrome there, or is it there and then painted over?".
 *
 * The M7 gate made the plane PL0-none, so the pixels come from /dev/fb0 — a READ-ONLY
 * kernel-mediated stream of the raw plane (stride*4*h bytes) — instead of a direct mapping.
 * A grab is a legitimate diagnostic; writing the plane is not, and this tool never needed
 * to. Geometry still comes from SYS_fb_info, whose numbers survived the gate for exactly
 * this kind of use.
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
    /* -xl grabs the ATARI surface instead of the desktop. It is not a convenience:
     * the desktop composites on top with alpha=0 punched out where the emulator
     * window sits, so a plain grab shows that window as a BLACK HOLE and can never
     * capture the Atari image, however long it is given. The XL surface is ANTIC's
     * DDR3 writeback, fixed 320x192 RGBA8888 = 2 px per colour clock. */
    int xl = (argc > 1 && argv[1][0] == '-' && argv[1][1] == 'x' && argv[1][2] == 'l'
              && argv[1][3] == 0);
    if (xl) { argc--; argv++; }

    struct os_fbinfo fb;
    if (xl) { fb.w = 320; fb.h = 192; fb.stride = 320; }
    else if (sys_fb_info(&fb) != 0) {
        static const char e[] = "fbgrab: no display plane\n";
        sys_write(2, e, sizeof e - 1);
        return 1;
    }
    const char *out = (argc > 1) ? argv[1] : "/tmp/screen.ppm";

    int pfd = (int)sys_open(xl ? "/OS/dev/fb1" : "/OS/dev/fb0", 0 /* O_RDONLY */);
    if (pfd < 0) {
        static const char e[] = "fbgrab: /OS/dev/fb0 not there (pre-M7 kernel?)\n";
        sys_write(2, e, sizeof e - 1);
        return 1;
    }

    int fd = (int)sys_open(out, 0x0241 /* O_WRONLY|O_CREAT|O_TRUNC */);
    if (fd < 0) {
        static const char e[] = "fbgrab: cannot create the output file\n";
        sys_write(2, e, sizeof e - 1);
        sys_close(pfd);
        return 1;
    }

    char hdr[64], *p = hdr;                     /* P6 <w> <h> 255 */
    *p++ = 'P'; *p++ = '6'; *p++ = '\n';
    p = u32d(p, (unsigned)fb.w); *p++ = ' ';
    p = u32d(p, (unsigned)fb.h); *p++ = '\n';
    *p++ = '2'; *p++ = '5'; *p++ = '5'; *p++ = '\n';
    sys_write(fd, hdr, (unsigned)(p - hdr));

    static uint32_t src[4096];                  /* one scanline of plane words */
    static unsigned char row[4096 * 3];         /* one scanline of RGB */
    unsigned rowbytes = (unsigned)fb.stride * 4u;   /* the STREAM carries full stride rows */
    int trunc = (rowbytes > sizeof src);        /* never expected (stride 2048); stay safe */
    for (int y = 0; y < fb.h && !trunc; y++) {
        unsigned got = 0;                       /* a device read may return short: loop */
        while (got < rowbytes) {
            long r = sys_read(pfd, (char *)src + got, rowbytes - got);
            if (r <= 0) { trunc = 1; break; }   /* stream ended early: stop cleanly */
            got += (unsigned)r;
        }
        if (trunc) break;
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
    sys_close(pfd);

    static const char ok[] = "fbgrab: wrote the plane\n";
    sys_write(1, ok, sizeof ok - 1);
    return 0;
}
