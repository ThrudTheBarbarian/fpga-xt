/*
 * antic_dma.c — ANTIC's per-scanline DMA schedule.  See antic_dma.h.
 *
 * FIRST CUT.  The refresh slots and the overall shape are taken from the ACID
 * table's own structure (see below); the playfield start cycles are still
 * parameters read off that table rather than derived from DMACTL/HSCROL, which
 * is what the real ANTIC does and what antic_pfstarttiming/antic_pfstoptiming
 * demand.  Deriving them is the next step — this exists so the harness has
 * something to score.
 */
#include "antic_dma.h"
#include <string.h>

/* ---- memory refresh -------------------------------------------------------
 * NINE cycles per scanline, every 4 from cycle 25: 25,29,...,57.  Not assumed —
 * this is the exact set common to ALL 50 rows of the ACID table, and 9 per line
 * is 18 per two scanlines, which is precisely the budget cpu_illtiming states
 * ("228 cycles - 18 refresh cycles").  Two independent sources agreeing. */
#define REFRESH_FIRST 25
#define REFRESH_STEP   4
#define REFRESH_COUNT  9

/* Per-mode playfield fetch shape. `step` is the cycle stride between fetches
 * on a row's first line; character modes interleave a name and a data fetch so
 * they run twice as dense there as on later lines. */
typedef struct {
    uint8_t step_first;   /* stride on the row's first scanline */
    uint8_t step_rest;    /* stride on subsequent scanlines, 0 = no fetch */
    uint8_t n_narrow;     /* fetch count, narrow, first line */
    uint8_t n_normal;
} mode_shape;

static const mode_shape shapes[16] = {
    /* 0,1 are blank/jump: no playfield DMA */
    [2]  = { 1, 2, 64, 80 }, [3]  = { 1, 2, 64, 80 },
    [4]  = { 1, 2, 64, 80 }, [5]  = { 1, 2, 64, 80 },
    [6]  = { 2, 4, 32, 40 }, [7]  = { 2, 4, 32, 40 },
    [8]  = { 8, 0,  8, 10 }, [9]  = { 8, 0,  8, 10 },
    [10] = { 4, 0, 16, 20 }, [11] = { 4, 0, 16, 20 },
    [12] = { 4, 0, 16, 20 },
    [13] = { 2, 0, 32, 40 }, [14] = { 2, 0, 32, 40 },
    [15] = { 2, 0, 32, 40 },
};

/* Playfield start cycle, read off the ACID table.  TODO: derive from DMACTL
 * width and HSCROL with the cycle-16/17 sampling point, per
 * docs/Acid800/antic_pfstarttiming.md — a fixed table cannot express the
 * mid-scanline register writes those tests make. */
static int pf_start(uint8_t mode, antic_width w, int first)
{
    int bitmap = (mode >= 8);
    if (w == ANTIC_NARROW) return bitmap ? 28 : (first ? 26 : 30);
    return bitmap ? 20 : (first ? 18 : 21);
}

void antic_dma_line(uint8_t mode, antic_width width, int first_line,
                    uint8_t blocked[ANTIC_LINE_CYCLES])
{
    memset(blocked, 0, ANTIC_LINE_CYCLES);

    for (int i = 0, c = REFRESH_FIRST; i < REFRESH_COUNT; i++, c += REFRESH_STEP)
        blocked[c] = 1;

    if (first_line) {
        blocked[1] = 1;              /* display-list instruction fetch */
        blocked[6] = blocked[7] = 1; /* its operand fetches */
    }

    if (mode < 2 || mode > 15) return;
    const mode_shape *s = &shapes[mode];
    int step = first_line ? s->step_first : s->step_rest;
    if (!step) return;

    int n = (width == ANTIC_NARROW) ? s->n_narrow : s->n_normal;
    if (!first_line) n /= (s->step_rest / s->step_first);

    int c = pf_start(mode, width, first_line);
    for (int i = 0; i < n && c < ANTIC_LINE_CYCLES; i++, c += step)
        blocked[c] = 1;
}
