/* How does a row's fetch count depend on WHEN a mid-line DMACTL write lands?
 *
 * antic_pfstarttiming's two cases differ by ONE cycle in the write position --
 * dli1 writes narrow at cycle 13 and its row fetches 16 (correct), dli2 at
 * cycle 14 and its row fetches 11 where hardware wants 18.  A five-byte jump
 * for a one-cycle move is a bound being crossed.  This prints the whole curve
 * so the bound names itself. */
#include <stdio.h>
#include <string.h>
#include "antic.h"

static uint8_t mem[65536];
static uint8_t fetchb(void *ctx, uint16_t a) { (void)ctx; return mem[a]; }

static int run(int at, int back)             /* -1 = no write */
{
    antic a;
    antic_init(&a, fetchb, NULL, ANTIC_LINES_NTSC);
    antic_write(&a, 0xD402, 0x00);
    antic_write(&a, 0xD403, 0x2C);           /* DLIST = $2C00 */
    antic_write(&a, 0xD400, 0x22);           /* normal width, DL DMA */
    antic_write(&a, 0xD405, 0x07);           /* VSCROL 7 */
    antic_write(&a, 0xD409, 0xE0);           /* CHBASE */

    int n = -1;
    for (long i = 0; i < 400000; i++) {
        int is66 = (a.dl_insn & 0x7F) == 0x66;
        if (is66 && a.cycle == at)   antic_write(&a, 0xD400, 0x21);
        if (is66 && back >= 0 && a.cycle == back) antic_write(&a, 0xD400, 0x22);
        antic_tick(&a);
        /* count at the END of the $66 line */
        if (is66 && a.cycle == 0) {
            n = 0;
            for (int c = 0; c < ANTIC_LINE_CYCLES; c++) if (a.pf_at[c] >= 0) n++;
            break;
        }
    }
    return n;
}

int main(void)
{
    for (int i = 0; i < 64; i++)   mem[0x2D00 + i] = (uint8_t)(0x40 + i);
    for (int i = 0; i < 1024; i++) mem[0xE000 + i] = (uint8_t)(0x81 + (i & 7));
    uint16_t d = 0x2C00;
    mem[d++] = 0x70; mem[d++] = 0x70; mem[d++] = 0xF0; mem[d++] = 0x00;
    mem[d++] = 0x66; mem[d++] = 0x00; mem[d++] = 0x2D;
    mem[d++] = 0x0A; mem[d++] = 0x41; mem[d++] = 0x00; mem[d++] = 0x2C;

    printf("no write: %d fetches\n", run(-1, -1));
    printf("narrow at 13, restored to normal at cycle N:\n");
    for (int b = 14; b <= 113; b += 7)
        printf("   back at %3d -> %2d fetches\n", b, run(13, b));
    printf("narrow at 14, restored at cycle N:\n");
    for (int b = 15; b <= 113; b += 7)
        printf("   back at %3d -> %2d fetches\n", b, run(14, b));
    return 0;
}
