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
/* As antic_pf_nominal, but told explicitly whether the row is SCROLLED — a
 * scrolled row runs the next width up, and it can be scrolled with HSCROL=0.
 * antic_pf_nominal keeps the old inference (scrolled iff HSCROL != 0). */
int antic_pf_nominal_s(antic_width w, int hscrol, int scrolled);

/* Memory refresh: nine cycles a scanline, taken whatever DMACTL says.  Exposed
 * because it happens even with the screen off, where no other DMA does. */
void antic_dma_refresh(uint8_t blocked[ANTIC_LINE_CYCLES]);
#define PF_DISPLAY_LEAD 3

void antic_dma_line(uint8_t mode, antic_width width, int first_line,
                    int hscrol, uint8_t blocked[ANTIC_LINE_CYCLES]);

/* The same schedule, plus WHICH playfield byte each cycle fetches.
 * `name_at[c]` is the index into the line buffer of the byte fetched from the
 * playfield scan address on cycle `c`, or -1 for every other cycle — refresh,
 * the display-list fetches, and (in the character modes) the glyph half of each
 * name/glyph pair, none of which advance the scan address.
 *
 * This exists so the fetch can be PROGRESSIVE.  ANTIC reads the playfield
 * across the scanline, so a DMACTL or HSCROL write part way down the line moves
 * the window under a fetch that is already running — which is the whole of
 * antic_pfstarttiming, antic_pfstoptiming and antic_hscrolbug.  A model that
 * fetches the row in one go at cycle 0 cannot express any of them. */
void antic_dma_line_map(uint8_t mode, antic_width width, int first_line,
                        int hscrol, uint8_t blocked[ANTIC_LINE_CYCLES],
                        int8_t name_at[ANTIC_LINE_CYCLES]);

/* Where the fetch stream begins, in machine cycles.  Exposed so antic.c can tell
 * whether a mid-line DMACTL or HSCROL write arrived before or after it. */
int antic_pf_start(uint8_t mode, antic_width w, int first, int hscrol);

/* The fetch stream's grid step in machine cycles, so antic.c can say where the
 * LAST fetch the window could still schedule would land. */
int antic_pf_grid(uint8_t mode, int first);

/* The same schedule with the grid PINNED to `nom_start` while the stream still
 * ends where `width`'s own last fetch cycle is (-1 = derive both, i.e. plain
 * antic_dma_line_map).  ANTIC commits the START of the fetch a cycle or two
 * ahead but goes on comparing the STOP against the horizontal counter, so a
 * write landing in between produces a row belonging to NEITHER width. */
/* As antic_dma_line_map, but for a stream that may already be RUNNING when the
 * scanline starts (`carry_in` = the cycle of its next fetch, -1 for idle) and
 * that may still be running when the scanline ends (`*carry_out`, likewise).
 * See the stop-comparator note in antic_dma.c: the stop is missable. */
void antic_dma_line_map_carry(uint8_t mode, antic_width width, int first_line,
                              int hscrol, int carry_in,
                              uint8_t blocked[ANTIC_LINE_CYCLES],
                              int8_t name_at[ANTIC_LINE_CYCLES],
                              int *carry_out);

void antic_dma_line_map_at(uint8_t mode, antic_width width, int first_line,
                           int hscrol, int nom_start,
                           uint8_t blocked[ANTIC_LINE_CYCLES],
                           int8_t name_at[ANTIC_LINE_CYCLES]);

#endif /* ANTIC_DMA_H */
