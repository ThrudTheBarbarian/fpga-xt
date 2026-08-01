/*
 * antic.h — the ANTIC timing core.
 *
 * ANTIC owns the bus and hands the CPU its cycles.  The system's read/write
 * callbacks call antic_tick() until it yields, so a halted CPU is simply a
 * callback that takes longer to return.  There is no CDC, no second raster with
 * its own phase, and no /RDY sampling window — see emu/antic-design.md.
 *
 * Every timing landmark below is a measured ACID800 result, with the test that
 * establishes it named.  None of them are guesses.
 */
#ifndef ANTIC_H
#define ANTIC_H

#include <stdint.h>
#include "antic_dma.h"

/* Scanline cycle landmarks (docs/Acid800/). */
#define ANTIC_CYC_NMIST   6     /* NMIST bits set; NMIEN sampled  (antic_nmist) */
#define ANTIC_CYC_NMIRES  7     /* NMIRES takes effect from here  (antic_nmist) */
#define ANTIC_CYC_WSYNC 104     /* WSYNC releases /RDY            (antic_wsync) */
#define ANTIC_CYC_VCOUNT 111    /* VCOUNT advances                (antic_vcount) */

#define ANTIC_LINES_NTSC 262
#define ANTIC_LINES_PAL  312

/* NMIST/NMIEN bits */
#define ANTIC_NMI_DLI 0x80
#define ANTIC_NMI_VBI 0x40

typedef uint8_t (*antic_fetch_fn)(void *ctx, uint16_t addr);

typedef struct {
    /* registers */
    uint8_t  dmactl, chactl, hscrol, vscrol, pmbase, chbase;
    uint8_t  nmien, nmist;
    uint16_t dlist;

    /* timing */
    int cycle;        /* 0..113 within the scanline */
    int scanline;     /* 0..lines-1 */
    int lines;        /* ANTIC_LINES_NTSC or _PAL */
    int vcount;       /* the register's own counter — see antic_vcount.md */

    /* WSYNC: the CPU is held until cycle ANTIC_CYC_WSYNC.  Arms on the FIRST
     * $D40A write of a read-modify-write, which writes it twice. */
    int wsync_halt;

    int nmi;          /* NMI line to the CPU */

    antic_fetch_fn fetch;
    void          *ctx;

    /* the DMA schedule for the scanline in progress */
    uint8_t blocked[ANTIC_LINE_CYCLES];
} antic;

void    antic_init(antic *a, antic_fetch_fn fetch, void *ctx, int lines);
void    antic_reset(antic *a);

/* Advance one machine cycle.  Returns 1 if ANTIC (or a WSYNC halt) took the
 * bus, meaning the CPU did NOT get this cycle. */
int     antic_tick(antic *a);

uint8_t antic_read(antic *a, uint16_t addr);
void    antic_write(antic *a, uint16_t addr, uint8_t val);

#endif /* ANTIC_H */
