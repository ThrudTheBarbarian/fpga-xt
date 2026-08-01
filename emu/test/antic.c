/*
 * antic.c — directed tests for the ANTIC timing core.
 *
 * The landmarks these check are ACID800 results, each named with the test that
 * established it (docs/Acid800/).  Checking them here means a regression shows
 * up as a one-line failure rather than as a mystery in the full suite.
 */
#include <stdio.h>
#include "../antic.h"

static uint8_t nofetch(void *ctx, uint16_t a) { (void)ctx; (void)a; return 0; }
static uint8_t mem_fetch(void *ctx, uint16_t a) { return ((const uint8_t *)ctx)[a]; }

static int fails;
static void expect(const char *what, long got, long want)
{
    if (got == want) return;
    printf("  FAIL %s: got %ld, want %ld\n", what, got, want);
    fails++;
}

/* run to (scanline, cycle) from wherever we are */
static void run_to(antic *a, int line, int cyc)
{
    for (long i = 0; i < 400000; i++) {
        if (a->scanline == line && a->cycle == cyc) return;
        antic_tick(a);
    }
    printf("  FAIL run_to(%d,%d): never reached\n", line, cyc);
    fails++;
}

int main(void)
{
    antic a;

    /* ---- VCOUNT advances at 111, and is scanline>>1 ---------------------- */
    antic_init(&a, nofetch, NULL, ANTIC_LINES_NTSC);
    run_to(&a, 4, 110);
    expect("VCOUNT on line 4 (= 4>>1)", antic_read(&a, 0xD40B), 2);
    run_to(&a, 5, ANTIC_CYC_VCOUNT);      /* AT 111, not yet processed */
    expect("VCOUNT on line 5, before 111", antic_read(&a, 0xD40B), 2);
    antic_tick(&a);                       /* processes 111 of an ODD line */
    expect("VCOUNT on line 5, after 111", antic_read(&a, 0xD40B), 3);
    run_to(&a, 6, 50);
    expect("VCOUNT on line 6 (= 6>>1)", antic_read(&a, 0xD40B), 3);

    /* ---- the single-cycle rollover --------------------------------------
     * VCOUNT advances at 111 on the LAST scanline too, so it momentarily reads
     * lines/2 = 131 before the frame wrap clears it.  Roughly three cycles a
     * frame, which is why antic_vcount calls it "the nasty one". */
    antic_init(&a, nofetch, NULL, ANTIC_LINES_NTSC);
    run_to(&a, ANTIC_LINES_NTSC - 1, ANTIC_CYC_VCOUNT);
    expect("VCOUNT last line, pre-111", antic_read(&a, 0xD40B), 130);
    antic_tick(&a);
    expect("VCOUNT last line, post-111", antic_read(&a, 0xD40B), 131);
    run_to(&a, 0, 0);
    expect("VCOUNT after frame wrap", antic_read(&a, 0xD40B), 0);

    /* PAL reaches 156 the same way */
    antic_init(&a, nofetch, NULL, ANTIC_LINES_PAL);
    run_to(&a, ANTIC_LINES_PAL - 1, ANTIC_CYC_VCOUNT);
    antic_tick(&a);
    expect("VCOUNT last line PAL", antic_read(&a, 0xD40B), 156);

    /* ---- WSYNC releases /RDY at 104 -------------------------------------- */
    antic_init(&a, nofetch, NULL, ANTIC_LINES_NTSC);
    run_to(&a, 10, 50);
    antic_write(&a, 0xD40A, 0);           /* STA WSYNC */
    {
        int held = 0, released_at = -1;
        for (int i = 0; i < ANTIC_LINE_CYCLES * 2; i++) {
            int c = a.cycle;
            if (antic_tick(&a)) held++;
            else if (released_at < 0 && held) released_at = c;
        }
        /* ANTIC_CYC_WSYNC is the first cycle the CPU gets BACK, not the last
         * one ANTIC keeps.  antic_wsync cannot settle this — its probes are
         * anchored to the release, so shifting it moves them with it — but
         * gtia_pmretrigger can: with memory refresh correctly present on every
         * scanline, giving the CPU 104 takes that test from failing its first
         * case to failing its fourth, i.e. three more sub-tests pass. */
        expect("first CPU cycle after WSYNC", released_at, ANTIC_CYC_WSYNC);
    }

    /* ---- unused ANTIC reads are $FF (antic_default) ---------------------- */
    expect("unused ANTIC read", antic_read(&a, 0xD406), 0xFF);

    /* ---- NMIST: VBI sets bit 6 at cycle 6, NMIRES clears status ---------- */
    antic_init(&a, nofetch, NULL, ANTIC_LINES_NTSC);
    a.nmien = ANTIC_NMI_VBI;
    run_to(&a, 248, ANTIC_CYC_NMIST);
    expect("NMIST before cycle 6", antic_read(&a, 0xD40F) & ANTIC_NMI_VBI, 0);
    antic_tick(&a);
    expect("NMIST VBI set at cycle 6", antic_read(&a, 0xD40F) & ANTIC_NMI_VBI, ANTIC_NMI_VBI);
    expect("NMI raised", a.nmi, 1);
    antic_write(&a, 0xD40F, 0);           /* NMIRES */
    expect("NMIRES clears status", antic_read(&a, 0xD40F) & ANTIC_NMI_VBI, 0);
    expect("NMIRES does NOT retract the request", a.nmi, 1);

    /* ---- the two address counters ----------------------------------------
     * Both are narrower than 16 bits and both wrap MID-INSTRUCTION.  Written as
     * plain 16-bit adders they pass casual testing and fail antic_addresswrap
     * immediately, which is why they are checked explicitly. */
    expect("DL counter wraps within its 1KB page",
           antic_dl_next(0x27FF), 0x2400);
    expect("DL counter otherwise increments",
           antic_dl_next(0x27FB), 0x27FC);
    expect("playfield counter wraps at 4KB",
           antic_pf_next(0x2FFF), 0x2000);
    expect("playfield counter otherwise increments",
           antic_pf_next(0x2FF0), 0x2FF1);

    /* ---- display-list decode --------------------------------------------
     * The list antic_addresswrap uses: an LMS whose operand straddles the 1 KB
     * boundary, so the high byte comes from AFTER the wrap. */
    {
        static uint8_t mem[65536];
        mem[0x27FB] = 0x4F;          /* LMS + mode F */
        mem[0x27FC] = 0xF0;          /* operand low  */
        mem[0x27FD] = 0x3F;          /* operand high */
        mem[0x2400] = 0x2F;          /* what a WRAPPED fetch would read */

        antic b;
        antic_init(&b, mem_fetch, mem, ANTIC_LINES_NTSC);
        b.dl_addr = 0x27FB;
        antic_dl_exec(&b);
        expect("LMS mode", b.dl_insn & 0x0F, 0x0F);
        expect("LMS operand assembled", b.pf_addr, 0x3FF0);
        expect("mode F row height", b.row_height, 1);

        /* now the straddling case: operand high byte lands after the wrap */
        mem[0x27FE] = 0x4F;
        mem[0x27FF] = 0xF0;
        antic_init(&b, mem_fetch, mem, ANTIC_LINES_NTSC);
        b.dl_addr = 0x27FE;
        antic_dl_exec(&b);
        expect("LMS operand straddling the 1KB wrap", b.pf_addr, 0x2FF0);
    }

    /* blank-line instruction: bits 6-4 plus one */
    {
        static uint8_t mem2[65536];
        mem2[0x2000] = 0x70;         /* 8 blank lines */
        antic c;
        antic_init(&c, mem_fetch, mem2, ANTIC_LINES_NTSC);
        c.dl_addr = 0x2000;
        antic_dl_exec(&c);
        expect("blank-line count", c.row_height, 8);
    }

    /* ---- the blank-line DLI ---------------------------------------------
     * antic_dlitiming's display list is $70 (8 blank) then four $90.  A blank
     * instruction's line count is bits 6-4 PLUS ONE, so $90 is TWO blank lines
     * with the DLI bit — not eight.  The DLI belongs to the LAST scanline of
     * each block, which is the case the fabric dl_parser gets wrong, so the
     * DLIs land on 17 and 19 — exactly the scanlines that test's own comments
     * name. */
    {
        static uint8_t dm[65536];
        dm[0x2C00] = 0x70;                    /* 8 blank -> scanlines 8..15   */
        dm[0x2C01] = 0x90;                    /* 2 blank + DLI -> 16,17       */
        dm[0x2C02] = 0x90;                    /* 2 blank + DLI -> 18,19       */
        dm[0x2C03] = 0x41; dm[0x2C04] = 0x00; dm[0x2C05] = 0x2C;   /* JVB */

        antic d;
        antic_init(&d, mem_fetch, dm, ANTIC_LINES_NTSC);
        d.dl_addr = 0x2C00;
        d.dmactl = 0x22;                      /* DL DMA on, normal width */
        d.nmien  = ANTIC_NMI_DLI;
        d.row_line = d.row_height = 0;

        int dli_lines[8], n = 0;
        for (int i = 0; i < ANTIC_LINE_CYCLES * 40; i++) {
            int before = d.nmi;
            antic_tick(&d);
            if (!before && d.nmi && n < 8) { dli_lines[n++] = d.scanline; d.nmi = 0; }
        }
        expect("blank-line DLI count", n, 2);
        if (n >= 2) {
            expect("first blank-line DLI on the block's LAST scanline", dli_lines[0], 17);
            expect("second blank-line DLI",                              dli_lines[1], 19);
        }
    }

    /* ---- the line buffer -------------------------------------------------
     * Fetch happens at one moment, display at another.  antic_linebuffering
     * checks that separation three ways; these are the same three. */
    {
        static uint8_t lm[65536];
        for (int i = 0; i < 64; i++) lm[0x3000 + i] = (uint8_t)(0xA0 + i);
        lm[0x2C00] = 0x4F; lm[0x2C01] = 0x00; lm[0x2C02] = 0x30;  /* LMS mode F @ $3000 */
        lm[0x2C03] = 0x0F;                                        /* mode F */
        lm[0x2C04] = 0x41; lm[0x2C05] = 0x00; lm[0x2C06] = 0x2C;  /* JVB */

        antic e;
        antic_init(&e, mem_fetch, lm, ANTIC_LINES_NTSC);
        e.dl_addr = 0x2C00;
        e.dmactl = 0x22;                       /* DL on, NORMAL width */
        e.row_line = e.row_height = 0;
        run_to(&e, ANTIC_DISPLAY_TOP + 1, 0);
        expect("fetched at normal width", e.lb_len, 40);
        expect("line buffer holds the fetched bytes", antic_display_byte(&e, 0), 0xA0);

        /* 1. ALIASING: narrow the playfield AFTER the fetch.  The buffer still
         *    holds what was fetched under the old width. */
        e.dmactl = 0x21;                       /* now narrow */
        expect("buffer unchanged by a later DMACTL write", antic_display_byte(&e, 39), 0xA0 + 39);

        /* 2. MID-LINE INTERRUPTION: kill playfield DMA entirely.  The rest of
         *    the line is not blanked — the buffer still holds it. */
        e.dmactl = 0x20;                       /* DL DMA only, no playfield */
        run_to(&e, ANTIC_DISPLAY_TOP + 3, 0);
        expect("buffer survives playfield DMA being turned off",
               antic_display_byte(&e, 10), 0xA0 + 10);

        /* 3. RE-DISPLAYABLE: still there several lines later. */
        run_to(&e, ANTIC_DISPLAY_TOP + 6, 0);
        expect("buffer is re-displayable", antic_display_byte(&e, 20), 0xA0 + 20);
    }

    printf("antic: %s\n", fails ? "FAIL" : "all timing-core tests pass");
    return fails ? 1 : 0;
}
