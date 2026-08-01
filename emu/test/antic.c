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
        expect("WSYNC releases at", released_at, ANTIC_CYC_WSYNC);
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

    printf("antic: %s\n", fails ? "FAIL" : "all timing-core tests pass");
    return fails ? 1 : 0;
}
