/*
 * dma.c — score the ANTIC DMA schedule against ACID800's own table.
 *
 * antic_dmapattern carries the per-cycle allocation for 50 mode/width/variant
 * combinations as DATA.  This runs our scheduler against all 50 and reports how
 * many match exactly, so progress on the DMA model is a number rather than an
 * impression.
 */
#include <stdio.h>
#include <string.h>
#include "../antic_dma.h"
#include "../acid_dmatable.h"

/* First blocked cycle that is a PLAYFIELD fetch: past the display-list fetch
 * at 1/6/7 and not one of the fixed refresh slots at 25,29,...,57. */
static int first_fetch(const uint8_t *b)
{
    for (int c = 9; c < ANTIC_LINE_CYCLES; c++) {
        int refresh = (c >= 25 && c <= 57 && ((c - 25) % 4) == 0);
        if (b[c] && !refresh) return c;
    }
    return -1;
}

int main(int argc, char **argv)
{
    (void)argv;
    int verbose = (argc > 1);
    int pass = 0;

    for (int r = 0; r < ACID_DMA_NROWS; r++) {
        const acid_dma_row *row = &acid_dma_rows[r];
        uint8_t want[ANTIC_DMA_CHECKED], got[ANTIC_LINE_CYCLES];

        for (int c = 0; c < ANTIC_DMA_CHECKED; c++)
            want[c] = (uint8_t)((row->mask[c >> 3] >> (7 - (c & 7))) & 1);

        antic_width w = strcmp(row->width, "narrow") ? ANTIC_NORMAL : ANTIC_NARROW;
        /* variants a,c are a row's first scanline; b,d are the rest */
        int first = (row->variant == 'a' || row->variant == 'c');
        antic_dma_line(row->mode, w, first, 0, got);

        int bad = -1, ndiff = 0;
        for (int c = 0; c < ANTIC_DMA_CHECKED; c++)
            if (want[c] != got[c]) { if (bad < 0) bad = c; ndiff++; }

        if (bad < 0) { pass++; continue; }
        printf("  %-6s mode %2d %c: %3d cycles differ, first at %d\n",
               row->width, row->mode, row->variant, ndiff, bad);
        if (verbose) {
            printf("    want "); for (int c = 0; c < ANTIC_DMA_CHECKED; c++) putchar(want[c] ? '#' : '.');
            printf("\n    got  "); for (int c = 0; c < ANTIC_DMA_CHECKED; c++) putchar(got[c] ? '#' : '.');
            putchar('\n');
        }
    }
    /* The ACID table only covers narrow and normal, so the WIDE case and the
     * HSCROL shift are checked against the derivation instead: one DMACTL width
     * step moves the window 8 machine cycles, and HSCROL moves it left by half
     * a machine cycle per colour clock.  Without this the derivation could be
     * silently wrong everywhere the table does not reach — which is exactly
     * where antic_pfstarttiming and antic_pfstoptiming operate. */
    int extra = 0;
    {
        uint8_t n[ANTIC_LINE_CYCLES], m[ANTIC_LINE_CYCLES], w[ANTIC_LINE_CYCLES];
        antic_dma_line(8, ANTIC_NARROW, 1, 0, n);
        antic_dma_line(8, ANTIC_NORMAL, 1, 0, m);
        antic_dma_line(8, ANTIC_WIDE,   1, 0, w);
        /* Skip the refresh slots: they sit at 25,29,... regardless of width, so
         * a naive "first blocked cycle" finds refresh rather than the playfield
         * whenever the window starts after 25. */
        int fn = first_fetch(n), fm = first_fetch(m), fw = first_fetch(w);
        /* Both steps are 8, and BOTH windows are involved -- which is what the
         * 6 that used to be asserted here was really about.  The FETCH window
         * starts at 26/18/10 (28/20/12 for the bitmap modes), so each DMACTL
         * width step moves the fetch by 8; the DISPLAY window starts at
         * 32/24/22, so narrow->normal moves the picture by 8 but normal->wide
         * moves it by only 2.  first_fetch() measures the FETCH window, so 8
         * is the right answer on both steps.  antic_virtdma's six came from
         * reading a display-side observation as a fetch-side one. */
        if (fn - fm != 8) { printf("  FAIL width step: narrow-normal = %d, want 8\n", fn - fm); extra++; }
        if (fm - fw != 8) { printf("  FAIL width step: normal-wide  = %d, want 8\n", fm - fw); extra++; }

        /* Both rows SCROLLED (mode bit 4), so this measures HSCROL alone.  A
         * scrolled row runs the next width up, so comparing an unscrolled
         * HSCROL=0 row against a scrolled HSCROL=8 one would fold a whole
         * width step into the answer — see antic_hscrolbug's DMA map. */
        uint8_t h0[ANTIC_LINE_CYCLES], h8[ANTIC_LINE_CYCLES];
        antic_dma_line(8 | 0x10, ANTIC_NORMAL, 1, 0, h0);
        antic_dma_line(8 | 0x10, ANTIC_NORMAL, 1, 8, h8);
        int a = first_fetch(h0), b = first_fetch(h8);
        /* HSCROL DELAYS the fetch: the window start takes += (HSCROL & 14) >> 1,
         * so HSCROL=8 starts FOUR CYCLES LATER and a - b is -4.  The +4 that
         * used to be asserted here had the sign of the derivation backwards --
         * scrolling the picture right is done by fetching later, not earlier. */
        if (a - b != -4) { printf("  FAIL hscrol=8 shift: %d cycles, want -4\n", a - b); extra++; }
    }
    if (!extra) printf("dma: window derivation ok (fetch window steps 8 per DMACTL width, HSCROL delays it half a cycle per colour clock)\n");

    printf("dma: %d/%d ACID800 DMA rows match\n", pass, ACID_DMA_NROWS);
    return (pass == ACID_DMA_NROWS && !extra) ? 0 : 1;
}
