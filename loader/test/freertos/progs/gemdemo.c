/* /bin/gemdemo — links libGEM.so, draws shapes to an RGBA surface, and dumps it
 * as ASCII (no display in qemu). Proves libGEM-as-a-shared-library on XTOS. */
#include "usys.h"
#include "vdi.h"

#define W 64
#define H 28
static uint32_t fb[W * H];
static vdi_surface surf = { fb, W, H };

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    v_clear(&surf, 0x000000ffu);                       /* black background    */
    v_bar(&surf, 3, 3, 26, 11, 0x3366ffffu);           /* blue filled rect    */
    v_circle(&surf, 46, 15, 9, 0xff7733ffu);           /* orange filled circle*/
    v_pline(&surf, 0, H - 1, W - 1, 0, 0x33ff66ffu);   /* green diagonal      */

    static const char ramp[] = " .:-=+*#%@";           /* 10-step brightness  */
    char row[W + 2];
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            uint32_t p = fb[y * W + x];
            int r = (p >> 24) & 0xff, g = (p >> 16) & 0xff, b = (p >> 8) & 0xff;
            int lum = (r * 30 + g * 59 + b * 11) / 100;
            row[x] = ramp[lum * 9 / 255];
        }
        row[W] = '\n'; row[W + 1] = 0;
        sys_write(1, row, W + 1);
    }
    sys_exit(0);
}
