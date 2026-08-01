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

/* Per-mode playfield fetch shape.
 *
 * Character modes (2-7) fetch a character NAME and its DATA on a row's first
 * scanline and only the DATA on later ones, so the first line runs twice as
 * dense.  Bitmap modes (8-15) fetch once per ROW, so their later scanlines
 * fetch nothing at all. */
typedef struct {
    uint8_t stride_first;  /* cycle stride on the row's first scanline */
    uint8_t stride_rest;   /* stride on subsequent scanlines, 0 = no fetch */
    uint8_t chars_narrow;  /* playfield units across, narrow */
    uint8_t chars_normal;
} mode_shape;

static const mode_shape shapes[16] = {
    /* 0,1 are blank/jump: no playfield DMA */
    [2]  = { 1, 2, 32, 40 }, [3]  = { 1, 2, 32, 40 },
    [4]  = { 1, 2, 32, 40 }, [5]  = { 1, 2, 32, 40 },
    [6]  = { 2, 4, 16, 20 }, [7]  = { 2, 4, 16, 20 },
    [8]  = { 8, 0,  8, 10 }, [9]  = { 8, 0,  8, 10 },
    [10] = { 4, 0, 16, 20 }, [11] = { 4, 0, 16, 20 },
    [12] = { 4, 0, 16, 20 },
    [13] = { 2, 0, 32, 40 }, [14] = { 2, 0, 32, 40 },
    [15] = { 2, 0, 32, 40 },
};

static int is_refresh(int c)
{
    return c >= REFRESH_FIRST
        && c <= REFRESH_FIRST + (REFRESH_COUNT - 1) * REFRESH_STEP
        && ((c - REFRESH_FIRST) % REFRESH_STEP) == 0;
}

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
    int stride = first_line ? s->stride_first : s->stride_rest;
    if (!stride) return;

    int chars = (width == ANTIC_NARROW) ? s->chars_narrow : s->chars_normal;
    int start = pf_start(mode, width, first_line);

    /* Bitmap modes fetch `chars` BYTES once per row — no name/data pair, and
     * their stream sits on its own grid rather than the refresh one. */
    if (mode >= 8) {
        for (int i = 0, c = start; i < chars && c < ANTIC_LINE_CYCLES;
             i++, c += stride)
            blocked[c] = 1;
        return;
    }

    int n = first_line ? chars * 2 : chars;       /* name+data, or data only */

    if (stride == 1) {
        /* Dense character modes: one prefetch, a free cycle, then a solid run.
         * The run displaces refresh entirely — 64 fetches plus 9 refresh slots
         * do not fit in the window, so refresh loses.  That is the "preempted
         * refresh is LOST, not re-sought" behaviour this project already knows
         * from the fabric DMA scheduler. */
        blocked[start] = 1;
        for (int i = 0, c = start + 2; i < n && c < ANTIC_LINE_CYCLES; i++, c++)
            blocked[c] = 1;
        return;
    }

    /* Character modes 6-7 on a row's first line: the name and data fetches come
     * in PAIRS on a 4-cycle grid.  A grid point that lands on a refresh slot
     * pushes its whole pair one cycle later (so the refresh cycle plus the pair
     * read as a triple), and the last grid point emits only as many fetches as
     * the budget has left.  Modes 2-5 are the same structure at a 2-cycle grid,
     * where consecutive pairs merge into the solid run handled above. */
    if (first_line) {
        blocked[start] = 1;                       /* the prefetch */
        int nom = (width == ANTIC_NARROW) ? 29 : 21;
        int left = n - 1;                         /* the prefetch was one of them */
        for (int p = nom; left > 0 && p < ANTIC_LINE_CYCLES; p += 4) {
            int c = is_refresh(p) ? p + 1 : p;
            for (int k = 0; k < 2 && left > 0 && c + k < ANTIC_LINE_CYCLES; k++, left--)
                blocked[c + k] = 1;
        }
        return;
    }

    /* Sparse streams: the nominal fetch slots run at `stride` from cycle 29,
     * and a fetch landing on a REFRESH slot is DEFERRED BY ONE CYCLE — refresh
     * has priority and the fetch slips.  That is what produces the 30,31 /
     * 34,35 pairing in the table rather than an even stride, and it is the same
     * fetch-versus-consumed-cycle distinction antic_hscrolbug's map draws. */
    /* The nominal grid starts where the playfield does, which is earlier for a
     * normal-width line than a narrow one. */
    int nominal = (width == ANTIC_NARROW) ? 29 : 21;
    for (int i = 0, p = nominal; i < n && p < ANTIC_LINE_CYCLES; i++, p += stride) {
        int c = is_refresh(p) ? p + 1 : p;
        if (c < ANTIC_LINE_CYCLES) blocked[c] = 1;
    }
}
