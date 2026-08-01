/*
 * gtia.c — GTIA collisions and object rendering.  See gtia.h.
 */
#include "gtia.h"
#include <string.h>

void gtia_init(gtia *g)
{
    memset(g, 0, sizeof *g);
    g->consol = 0;
}

/* SIZEP/SIZEM: 0 and 2 are 1x, 1 is 2x, 3 is 4x. */
static int size_scale(uint8_t s)
{
    switch (s & 3) {
    case 1:  return 2;
    case 3:  return 4;
    default: return 1;
    }
}

/* HPOS is compared against the LIVE colour-clock position, with no once-a-line
 * "already emitted" interlock — which is why moving HPOS mid-line makes the
 * comparator match again and redraws the player (gtia_pmretrigger). */
int gtia_player_lit(const gtia *g, int i, int hpos)
{
    int w = size_scale(g->sizep[i]);
    int d = hpos - g->hposp[i];
    if (d < 0 || d >= 8 * w) return 0;
    return (g->grafp[i] >> (7 - (d / w))) & 1;
}

int gtia_missile_lit(const gtia *g, int i, int hpos)
{
    int w = size_scale((uint8_t)(g->sizem >> (2 * i)));
    int d = hpos - g->hposm[i];
    if (d < 0 || d >= 2 * w) return 0;
    return (g->grafm >> (2 * i + (1 - (d / w)))) & 1;
}

void gtia_clock(gtia *g, int hpos, int pf, int hires_lit)
{
    /* No collisions of ANY kind during vertical blank — four separate
     * assertions in gtia_collision cover this. */
    if (g->vblank) return;

    int visible = hpos >= GTIA_VISIBLE_L && hpos <= GTIA_VISIBLE_R;

    int p[4], m[4];
    for (int i = 0; i < 4; i++) {
        p[i] = gtia_player_lit(g, i, hpos);
        m[i] = gtia_missile_lit(g, i, hpos);
    }

    /* HBLANK is NOT a uniform "collisions off": missile/player still registers
     * there while player/player does not (gtia_collision). */
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            if (m[i] && p[j]) g->mpl[i] |= (uint8_t)(1 << j);

    if (visible) {
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                if (i != j && p[i] && p[j]) g->ppl[i] |= (uint8_t)(1 << j);
    }

    if (!visible) return;

    /* Playfield collisions.
     *
     * In a HI-RES mode GTIA is not shown the two half-clock pixels
     * individually — it is shown "something is lit here", and that collides as
     * PF2 whichever half it was (gtia_collision2).  That single rule is the
     * mechanism behind antic_hiresbug.
     *
     * Mode 9 produces NO playfield collisions at all: its playfield byte is a
     * luminance rather than a colour index, so there is no colour to collide
     * with. */
    int mode = (g->prior >> 6) & 3;
    if (mode == GTIA_MODE_9) return;

    int cls = g->hires ? (hires_lit ? 2 : -1) : pf;
    if (cls < 0) return;

    for (int i = 0; i < 4; i++) {
        if (p[i]) g->ppf[i] |= (uint8_t)(1 << cls);
        if (m[i]) g->mpf[i] |= (uint8_t)(1 << cls);
    }
}

uint8_t gtia_read(gtia *g, uint16_t addr)
{
    switch (addr & 0x1F) {
    case 0x00: case 0x01: case 0x02: case 0x03:
        return (uint8_t)(g->mpf[addr & 3] & 0x0F);
    case 0x04: case 0x05: case 0x06: case 0x07:
        return (uint8_t)(g->ppf[addr & 3] & 0x0F);
    case 0x08: case 0x09: case 0x0A: case 0x0B:
        return (uint8_t)(g->mpl[addr & 3] & 0x0F);
    case 0x0C: case 0x0D: case 0x0E: case 0x0F:
        return (uint8_t)(g->ppl[addr & 3] & 0x0F);
    case 0x1F:
        /* CONSOL drives the switch lines LOW; the read returns the resulting
         * line state, so it is the complement of what was written
         * (gtia_consol). */
        return (uint8_t)(~g->consol & 0x07);
    default:
        /* GTIA only drives the low nibble, so an unused read is $0F — NOT
         * ANTIC's $FF (gtia_default).  One shared open-bus value gets one of
         * the two chips wrong. */
        return 0x0F;
    }
}

void gtia_write(gtia *g, uint16_t addr, uint8_t val)
{
    switch (addr & 0x1F) {
    case 0x00: case 0x01: case 0x02: case 0x03: g->hposp[addr & 3] = val; break;
    case 0x04: case 0x05: case 0x06: case 0x07: g->hposm[addr & 3] = val; break;
    case 0x08: case 0x09: case 0x0A: case 0x0B: g->sizep[addr & 3] = val; break;
    case 0x0C: g->sizem = val; break;
    case 0x0D: case 0x0E: case 0x0F: case 0x10: g->grafp[(addr - 0x0D) & 3] = val; break;
    case 0x11: g->grafm  = val; break;
    case 0x12: case 0x13: case 0x14: case 0x15: g->colpm[(addr - 0x12) & 3] = val; break;
    case 0x16: case 0x17: case 0x18: case 0x19: g->colpf[(addr - 0x16) & 3] = val; break;
    case 0x1A: g->colbk  = val; break;
    case 0x1B: g->prior  = val; break;
    case 0x1C: g->vdelay = val; break;
    case 0x1D: g->gractl = val; break;
    case 0x1E:                                  /* HITCLR */
        memset(g->mpf, 0, sizeof g->mpf); memset(g->ppf, 0, sizeof g->ppf);
        memset(g->mpl, 0, sizeof g->mpl); memset(g->ppl, 0, sizeof g->ppl);
        break;
    case 0x1F: g->consol = val; break;
    default: break;
    }
}
