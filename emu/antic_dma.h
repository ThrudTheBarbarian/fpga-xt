/*
 * antic_dma.h — ANTIC's per-scanline DMA cycle schedule.
 *
 * Which cycles ANTIC takes from the CPU, for one scanline.  This is the
 * foundation the rest of ANTIC sits on: every other timing behaviour is
 * measured through what the CPU was allowed to run, so if this is wrong
 * nothing above it can be right.
 *
 * Gated against emu/acid_dmatable.h — the 50 rows ACID800's antic_dmapattern
 * carries as data (docs/Acid800/antic_dmapattern.md).
 */
#ifndef ANTIC_DMA_H
#define ANTIC_DMA_H

#include <stdint.h>

#define ANTIC_LINE_CYCLES 114   /* machine cycles per scanline */
#define ANTIC_DMA_CHECKED 112   /* how many the ACID table specifies */

typedef enum { ANTIC_NARROW = 0, ANTIC_NORMAL = 1, ANTIC_WIDE = 2 } antic_width;

/* Fill `blocked[0..ANTIC_LINE_CYCLES-1]` with 1 for each cycle ANTIC takes.
 *
 *   mode        ANTIC mode 2..15
 *   width       playfield width
 *   first_line  1 on a display-list row's FIRST scanline (display-list fetch
 *               plus, for character modes, the name fetches); 0 on the
 *               subsequent scanlines of the same row.
 *   hscrol      HSCROL, in colour clocks (0-15).  Shifts the playfield window
 *               left; the window edges are DERIVED from this and the width,
 *               not tabulated, because antic_pfstarttiming/antic_pfstoptiming
 *               write both mid-scanline and expect the edges to move.
 */
/* Where the playfield WINDOW nominally starts, in machine cycles.  Exposed
 * because the pixel decode must start from the same geometry the DMA schedule
 * uses: display begins exactly PF_DISPLAY_LEAD cycles after this, for every
 * width, so the two cannot drift apart. */
int antic_pf_nominal(antic_width w, int hscrol);

/* Memory refresh: nine cycles a scanline, taken whatever DMACTL says.  Exposed
 * because it happens even with the screen off, where no other DMA does. */
void antic_dma_refresh(uint8_t blocked[ANTIC_LINE_CYCLES]);
#define PF_DISPLAY_LEAD 3

void antic_dma_line(uint8_t mode, antic_width width, int first_line,
                    int hscrol, uint8_t blocked[ANTIC_LINE_CYCLES]);

#endif /* ANTIC_DMA_H */
