/*
 * gtia.h — GTIA: player/missile rendering, priority and COLLISIONS.
 *
 * Collisions come off the EMITTED PIXEL STREAM, one colour clock at a time.
 * That is not an implementation preference — gtia_collision requires a sprite
 * straddling the left blanking edge to collide on its visible clocks ONLY, and
 * gtia_pmretrigger requires a mid-line HPOS write to redraw the player on the
 * same line.  Neither is expressible in a renderer that decides sprite
 * positions once per scanline.
 *
 * Every rule below names the ACID800 test that established it
 * (docs/Acid800/gtia_*.md).
 */
#ifndef GTIA_H
#define GTIA_H

#include <stdint.h>

/* A scanline is 228 colour clocks; the visible region runs $22..$DD
 * (gtia_collision names both edges). */
#define GTIA_CLOCKS      228
#define GTIA_VISIBLE_L  0x22
#define GTIA_VISIBLE_R  0xDD

/* PRIOR bits 7-6 select the GTIA special modes. */
#define GTIA_MODE_NORMAL 0
#define GTIA_MODE_9      1   /* PRIOR $40 — no playfield collisions */
#define GTIA_MODE_10     2   /* PRIOR $80 — shifted one colour clock */
#define GTIA_MODE_11     3   /* PRIOR $C0 */

typedef struct {
    /* object registers */
    uint8_t hposp[4], hposm[4];
    uint8_t sizep[4], sizem;
    uint8_t grafp[4], grafm;
    uint8_t colpm[4], colpf[4], colbk;
    uint8_t prior, vdelay, gractl, consol;

    /* collision registers — 4 bits each */
    uint8_t mpf[4], ppf[4], mpl[4], ppl[4];

    /* per-scanline state */
    int hires;      /* the playfield this line is an ANTIC hi-res mode */
    int vblank;
} gtia;

void    gtia_init(gtia *g);

/* Advance one colour clock.  `pf` is the playfield colour class at this clock
 * (0..3 for PF0..PF3, or -1 for background); `hpos` is the colour-clock
 * position.  `hires_lit` says whether EITHER half-clock pixel is set, which is
 * all GTIA is shown in a hi-res mode. */
void    gtia_clock(gtia *g, int hpos, int pf, int hires_lit);

uint8_t gtia_read(gtia *g, uint16_t addr);
void    gtia_write(gtia *g, uint16_t addr, uint8_t val);

/* Exposed for the tests: is player/missile `i` lit at this colour clock? */
int     gtia_player_lit(const gtia *g, int i, int hpos);
int     gtia_missile_lit(const gtia *g, int i, int hpos);

#endif /* GTIA_H */
