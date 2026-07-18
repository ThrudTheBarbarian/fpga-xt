/* graboverlay.c — /bin/graboverlay: dump the on-screen 6502/XL emulation plane as a
 * 24-bit BMP on stdout.  Redirect to a file (`graboverlay > /tmp/6502.bmp`) or pull it
 * straight off the board (`ssh xtos.local graboverlay > shot.bmp`).
 *
 * The compositor planes live in the PL0-NONE graphics window (M7 gate), so a userland
 * program can't map them; SYS_plane_grab has the kernel copy the EXACT triple-buffer
 * slot the compositor is scanning (DIAG4 = the XL plane's live read address) into our
 * buffer — tear-free.  Plane id XT_PLANE_XL (=1) is the 6502; the m68k plane is a later
 * id.  Pixels are RGBA-8888, the compositor's bits[31:8] = RGB, [7:0] = alpha. */
#include <stdint.h>
#include "usys.h"

#ifndef XT_PLANE_XL
#define XT_PLANE_XL 1
#endif

static uint32_t fb[320 * 192];        /* filled by the kernel grab (RGBA-8888) */
static uint8_t  hdr[54];
static uint8_t  row[320 * 3 + 3];

static void put32(uint8_t *p, uint32_t v){ p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void put16(uint8_t *p, uint16_t v){ p[0]=v; p[1]=v>>8; }
static void die(const char *s){ unsigned n=0; while(s[n]) n++; sys_write(2,s,n); sys_exit(1); }

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    long r = sys_plane_grab(XT_PLANE_XL, fb);
    if (r < 0) die("graboverlay: SYS_plane_grab failed\n");
    int w = (int)((r >> 16) & 0xFFFF), h = (int)(r & 0xFFFF);
    if (w <= 0 || h <= 0 || (uint32_t)w * (uint32_t)h > 320u * 192u) die("graboverlay: bad dims\n");

    uint32_t rowb = (uint32_t)w * 3;
    uint32_t pad  = (4 - (rowb & 3)) & 3;
    uint32_t imgsz= (rowb + pad) * (uint32_t)h;

    hdr[0]='B'; hdr[1]='M'; put32(hdr+2, 54 + imgsz); put32(hdr+6,0); put32(hdr+10,54);
    put32(hdr+14,40); put32(hdr+18,(uint32_t)w); put32(hdr+22,(uint32_t)h);   /* +h = bottom-up */
    put16(hdr+26,1); put16(hdr+28,24); put32(hdr+30,0); put32(hdr+34,imgsz);
    put32(hdr+38,2835); put32(hdr+42,2835); put32(hdr+46,0); put32(hdr+50,0);
    sys_write(1, hdr, 54);

    for (int y = h - 1; y >= 0; y--) {              /* BMP rows are bottom-up */
        uint8_t *o = row;
        const uint32_t *ln = fb + (uint32_t)y * (uint32_t)w;
        for (int x = 0; x < w; x++) {
            uint32_t px = ln[x];
            *o++ = (uint8_t)(px >> 8);              /* B */
            *o++ = (uint8_t)(px >> 16);             /* G */
            *o++ = (uint8_t)(px >> 24);             /* R */
        }
        for (uint32_t p = 0; p < pad; p++) *o++ = 0;
        sys_write(1, row, rowb + pad);
    }
    sys_exit(0);
}
