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
        antic_dma_line(row->mode, w, first, got);

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
    printf("dma: %d/%d ACID800 DMA rows match\n", pass, ACID_DMA_NROWS);
    return pass == ACID_DMA_NROWS ? 0 : 1;
}
