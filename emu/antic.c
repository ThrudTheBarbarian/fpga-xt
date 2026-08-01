/*
 * antic.c — the ANTIC timing core.  See antic.h.
 */
#include "antic.h"
#include <string.h>

void antic_init(antic *a, antic_fetch_fn fetch, void *ctx, int lines)
{
    memset(a, 0, sizeof *a);
    a->fetch = fetch;
    a->ctx   = ctx;
    a->lines = lines ? lines : ANTIC_LINES_NTSC;
    antic_reset(a);
}

void antic_reset(antic *a)
{
    a->cycle = a->scanline = a->vcount = 0;
    a->wsync_halt = 0;
    a->nmi = 0;
    a->nmist = 0;
    a->nmien = 0;
}

int antic_tick(antic *a)
{
    int c = a->cycle;
    int took = 0;

    /* ---- status and interrupt timing, all at fixed cycles ------------------
     * NMIST bits set at cycle 6 REGARDLESS of NMIEN — NMIEN gates the
     * interrupt, not the status — and NMIEN is sampled at the same cycle to
     * decide whether the interrupt is raised (antic_nmist). */
    if (c == ANTIC_CYC_NMIST) {
        int vbi = (a->scanline == 248);
        if (vbi) {
            /* the DLI and VBI status bits clear each other on arrival */
            a->nmist = (uint8_t)((a->nmist & ~ANTIC_NMI_DLI) | ANTIC_NMI_VBI);
            if (a->nmien & ANTIC_NMI_VBI) a->nmi = 1;
        }
    }

    /* VCOUNT is scanline>>1, so it advances at cycle 111 of every ODD scanline.
     * Because that advance happens on the LAST scanline too (261 is odd), it
     * momentarily reads lines/2 = 131 for cycles 111-113 before the frame wrap
     * clears it — antic_vcount's "nasty one, single cycle rollover". */
    if (c == ANTIC_CYC_VCOUNT && (a->scanline & 1))
        a->vcount++;

    /* WSYNC releases /RDY at 104: the first CPU cycle after a halt is 105. */
    if (a->wsync_halt) {
        if (c == ANTIC_CYC_WSYNC) a->wsync_halt = 0;
        else                      took = 1;
    }

    if (!took && c < ANTIC_LINE_CYCLES && a->blocked[c])
        took = 1;

    /* ---- advance ---------------------------------------------------------- */
    if (++a->cycle >= ANTIC_LINE_CYCLES) {
        a->cycle = 0;
        if (++a->scanline >= a->lines) {
            a->scanline = 0;
            a->vcount   = 0;     /* the wrap is at the END of the last line */
        }
    }
    return took;
}

uint8_t antic_read(antic *a, uint16_t addr)
{
    switch (addr & 0x0F) {          /* ANTIC decodes 4 bits; $D400-$D40F
                                     * mirrors across the page (antic_addrmirror) */
    case 0x0B: return (uint8_t)a->vcount;         /* VCOUNT */
    case 0x0F: return a->nmist;                   /* NMIST  */
    default:   return 0xFF;                       /* antic_default: unused
                                                   * ANTIC reads are $FF, unlike
                                                   * GTIA's $0F */
    }
}

void antic_write(antic *a, uint16_t addr, uint8_t val)
{
    switch (addr & 0x0F) {
    case 0x00: a->dmactl = val; break;
    case 0x01: a->chactl = val; break;
    case 0x02: a->dlist  = (uint16_t)((a->dlist & 0xFF00) | val); break;
    case 0x03: a->dlist  = (uint16_t)((a->dlist & 0x00FF) | (val << 8)); break;
    case 0x04: a->hscrol = val; break;
    case 0x05: a->vscrol = val; break;
    case 0x07: a->pmbase = val; break;
    case 0x09: a->chbase = val; break;
    case 0x0A:
        /* WSYNC.  Arms on the FIRST write — an RMW writes it twice and the
         * halt must not re-arm on the second (antic_wsync, d5). */
        if (!a->wsync_halt) a->wsync_halt = 1;
        break;
    case 0x0E: a->nmien = val; break;
    case 0x0F:
        /* NMIRES clears the STATUS but must not retract an interrupt already
         * raised — "VBI was blocked by NMIRES" is a failure (antic_nmist). */
        a->nmist = 0;
        break;
    default: break;
    }
}
