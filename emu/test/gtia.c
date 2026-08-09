/*
 * gtia.c — directed tests for GTIA collisions and registers.
 *
 * Each check names the ACID800 test that established the rule
 * (docs/Acid800/gtia_*.md).  Collisions come first because three ANTIC tests
 * read their answers out through these registers, so until collisions are right
 * those give ambiguous failures.
 */
#include <stdio.h>
#include <string.h>
#include "../gtia.h"

static int fails;
static void expect(const char *what, long got, long want)
{
    if (got == want) return;
    printf("  FAIL %s: got $%02lX, want $%02lX\n", what, got, want);
    fails++;
}

/* Put player 0 and player 1 on top of each other at `pos`, full pattern. */
static void two_players(gtia *g, int pos)
{
    gtia_init(g);
    gtia_write(g, 0xD00D, 0xFF);          /* GRAFP0 */
    gtia_write(g, 0xD00E, 0xFF);          /* GRAFP1 */
    gtia_write(g, 0xD000, (uint8_t)pos);  /* HPOSP0 */
    gtia_write(g, 0xD001, (uint8_t)pos);  /* HPOSP1 */
}

/* Sweep a whole scanline, background playfield unless `pf` says otherwise. */
static void sweep(gtia *g, int pf)
{
    for (int h = 0; h < GTIA_CLOCKS; h++) gtia_clock(g, h, pf, 0);
}

int main(void)
{
    gtia g;

    /* ---- no collisions of ANY kind in VBLANK (gtia_collision) ------------ */
    two_players(&g, 0x80);
    gtia_write(&g, 0xD011, 0xFF);          /* GRAFM  */
    gtia_write(&g, 0xD004, 0x80);          /* HPOSM0 */
    g.vblank = 1;
    sweep(&g, 2);
    expect("VBLANK: P/P", gtia_read(&g, 0xD00C), 0x00);
    expect("VBLANK: M/P", gtia_read(&g, 0xD008), 0x00);
    expect("VBLANK: P/PF", gtia_read(&g, 0xD004), 0x00);
    expect("VBLANK: M/PF", gtia_read(&g, 0xD000), 0x00);

    /* ---- overlapping players in the visible region DO collide ------------ */
    two_players(&g, 0x80);
    sweep(&g, -1);
    expect("visible: P0 hits P1", gtia_read(&g, 0xD00C) & 0x02, 0x02);

    /* ---- HBLANK is asymmetric between classes (gtia_collision) -----------
     * Park the objects left of the visible region: missile/player still
     * registers there, player/player does not. */
    two_players(&g, 0x08);
    gtia_write(&g, 0xD011, 0xFF);          /* GRAFM  */
    gtia_write(&g, 0xD004, 0x08);          /* HPOSM0 over player 0 */
    sweep(&g, -1);
    expect("HBLANK: M/P still registers", gtia_read(&g, 0xD008) & 0x01, 0x01);
    expect("HBLANK: P/P does NOT",        gtia_read(&g, 0xD00C) & 0x02, 0x00);

    /* ---- a sprite STRADDLING the left edge collides on its visible clocks
     * only.  $22 is the edge, so a player at $1E spans $1E..$25. */
    {
        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xFF);
        gtia_write(&g, 0xD000, 0x1E);
        gtia_write(&g, 0xD00E, 0xFF);
        gtia_write(&g, 0xD001, 0x1E);
        sweep(&g, -1);
        expect("straddling the left edge still collides",
               gtia_read(&g, 0xD00C) & 0x02, 0x02);
    }

    /* ---- hi-res collides as PF2 for ANY set pixel (gtia_collision2) ------
     * This single rule is the mechanism behind antic_hiresbug. */
    {
        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xFF);
        gtia_write(&g, 0xD000, 0x80);
        g.hires = 1;
        for (int h = 0; h < GTIA_CLOCKS; h++) gtia_clock(&g, h, 0, h >= 0x80 && h < 0x88);
        expect("hi-res collides as PF2", gtia_read(&g, 0xD004), 0x04);
    }

    /* ---- mode 9 produces NO playfield collisions (gtia_collision2) ------- */
    {
        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xFF);
        gtia_write(&g, 0xD000, 0x80);
        gtia_write(&g, 0xD01B, 0x40);      /* PRIOR = mode 9 */
        sweep(&g, 2);
        expect("mode 9: no playfield collisions", gtia_read(&g, 0xD004), 0x00);
    }

    /* ---- HPOS is compared LIVE, so a mid-line write retriggers ----------
     * Sweep once, move the player behind the beam, and it is drawn again. */
    {
        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xFF);
        gtia_write(&g, 0xD00E, 0xFF);
        gtia_write(&g, 0xD001, 0xA0);      /* player 1 parked at $A0 */
        gtia_write(&g, 0xD000, 0x40);      /* player 0 starts at $40 */
        for (int h = 0; h < 0x90; h++) gtia_clock(&g, h, -1, 0);
        expect("no collision before the move", gtia_read(&g, 0xD00C) & 0x02, 0x00);
        gtia_write(&g, 0xD000, 0xA0);      /* move player 0 ahead of the beam */
        for (int h = 0x90; h < GTIA_CLOCKS; h++) gtia_clock(&g, h, -1, 0);
        expect("retriggered after a mid-line HPOS write",
               gtia_read(&g, 0xD00C) & 0x02, 0x02);
    }

    /* ---- the player width is a LIVE DIVIDER, and its PHASE matters --------
     * gtia_pmresize's two "alt" cases reach the same size by different routes
     * and expect DIFFERENT results.  That is only possible if the outcome
     * depends on the counter's phase when SIZEP changed.  Here: a player that
     * is 2x throughout versus one switched from 1x to 2x part-way through must
     * NOT produce the same pixel run. */
    {
        char always2x[64], switched[64];
        int n1 = 0, n2 = 0;

        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xB4);          /* GRAFP0, an asymmetric pattern */
        gtia_write(&g, 0xD000, 0x40);          /* HPOSP0 */
        gtia_write(&g, 0xD008, 0x01);          /* SIZEP0 = 2x from the start */
        for (int h = 0x3E; h < 0x70; h++) {
            gtia_clock(&g, h, -1, 0);
            always2x[n1++] = (char)('0' + gtia_player_lit(&g, 0));
        }

        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xB4);
        gtia_write(&g, 0xD000, 0x40);
        gtia_write(&g, 0xD008, 0x00);          /* start 1x */
        for (int h = 0x3E; h < 0x70; h++) {
            if (h == 0x43) gtia_write(&g, 0xD008, 0x01);   /* -> 2x mid-object */
            gtia_clock(&g, h, -1, 0);
            switched[n2++] = (char)('0' + gtia_player_lit(&g, 0));
        }

        if (n1 == n2 && !memcmp(always2x, switched, (size_t)n1)) {
            printf("  FAIL SIZEP phase: 1x->2x mid-object matched always-2x, so the\n"
                   "       width is being recomputed rather than divided\n");
            fails++;
        }
    }

    /* ---- HPOS retrigger still works through the divider ------------------- */
    {
        gtia_init(&g);
        gtia_write(&g, 0xD00D, 0xFF);
        gtia_write(&g, 0xD000, 0x40);
        int lit_early = 0, lit_late = 0;
        for (int h = 0x40; h < 0x50; h++) { gtia_clock(&g, h, -1, 0); lit_early += gtia_player_lit(&g, 0); }
        gtia_write(&g, 0xD000, 0x60);          /* move it ahead of the beam */
        for (int h = 0x50; h < 0x70; h++) { gtia_clock(&g, h, -1, 0); lit_late += gtia_player_lit(&g, 0); }
        expect("player emitted before the move", lit_early > 0, 1);
        expect("player emitted AGAIN after the move", lit_late > 0, 1);
    }

    /* ---- HITCLR clears every class --------------------------------------- */
    gtia_write(&g, 0xD01E, 0);
    expect("HITCLR clears P/P", gtia_read(&g, 0xD00C), 0x00);

    /* ---- CONSOL reads back the COMPLEMENT (gtia_consol) ------------------ */
    gtia_write(&g, 0xD01F, 0x0C); expect("CONSOL $0C", gtia_read(&g, 0xD01F), 0x03);
    gtia_write(&g, 0xD01F, 0x0A); expect("CONSOL $0A", gtia_read(&g, 0xD01F), 0x05);
    gtia_write(&g, 0xD01F, 0x09); expect("CONSOL $09", gtia_read(&g, 0xD01F), 0x06);

    /* ---- unused GTIA reads are $0F, NOT ANTIC's $FF (gtia_default) ------- */
    expect("unused GTIA read", gtia_read(&g, 0xD015), 0x0F);

    printf("gtia: %s\n", fails ? "FAIL" : "all collision + register tests pass");
    return fails ? 1 : 0;
}
