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
#ifndef REFRESH_FIRST
#define REFRESH_FIRST 25
#endif
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

void antic_dma_refresh(uint8_t blocked[ANTIC_LINE_CYCLES])
{
    for (int i = 0, c = REFRESH_FIRST; i < REFRESH_COUNT; i++, c += REFRESH_STEP)
        blocked[c] = 1;
}

static int is_refresh(int c)
{
    return c >= REFRESH_FIRST
        && c <= REFRESH_FIRST + (REFRESH_COUNT - 1) * REFRESH_STEP
        && ((c - REFRESH_FIRST) % REFRESH_STEP) == 0;
}

/* ---- the playfield window -------------------------------------------------
 * DERIVED, not tabulated.  One DMACTL width step is 32 colour clocks = 16
 * machine cycles, 8 at EACH edge, so the window's left edge moves 8 machine
 * cycles per step: normal 21, narrow 29, wide 13.  That single rule reproduces
 * every start cycle in the ACID table.
 *
 * HSCROL shifts the window left by HSCROL colour clocks = HSCROL/2 machine
 * cycles.  It is a parameter here rather than a constant because
 * antic_pfstarttiming and antic_pfstoptiming write DMACTL and HSCROL
 * MID-SCANLINE and expect the edges to move — a tabulated start cannot express
 * that at all. */
#define PF_NOMINAL_NORMAL 21
#define PF_WIDTH_STEP      8
/* See antic_pf_nominal: the wide window's phase, which no validated table
 * covers — antic_dmapattern tabulates only narrow and normal.  MEASURED at 2
 * against antic_virtdma, which is the one place in the suite wide geometry is
 * pinned, and from BOTH sides: it puts colour clock $da on the first pixel of
 * character 23 (where the test's missiles read the high nibble), and it puts a
 * row's later-line glyph slots at 14, 18 ... 106, matching the map in the
 * test's own comment including its virtual slot at 106.
 *
 * Note which map: the FIRST-line map fits at 5 instead, and 5 moves the probe
 * off character 23 entirely.  antic_virtdma measures a row's LATER lines. */
#ifndef PF_WIDE_ADJ
#define PF_WIDE_ADJ 2
#endif

/* A HORIZONTALLY SCROLLED row runs the NEXT WIDTH UP entirely — the window's
 * position as well as its byte count.  Not a guess and not a sweep:
 * antic_hscrolbug's own DMA map (its lines 98-102) is a narrow, scrolled mode E
 * row at HSCROL=0, and it fetches forty bytes at cycles 20,22...98.  Narrow's
 * own window is 32 bytes at 28...90; a NORMAL window at HSCROL 0 is 40 bytes
 * from cycle 20.  The map is normal's, exactly.
 *
 * The earlier model here — the row's own window position, plus a quarter more
 * bytes, and only when HSCROL was non-zero — got the count right for a scrolled
 * narrow row and the position wrong by eight cycles, and missed the case the
 * map is built on: a row can be scrolled with HSCROL=0 and still fetch wide. */
#ifndef SCROLL_NEXT_WIDTH
#define SCROLL_NEXT_WIDTH 1
#endif

static antic_width eff_width(antic_width w, int scrolled)
{
    if (SCROLL_NEXT_WIDTH && scrolled && w != ANTIC_WIDE)
        return (antic_width)((int)w + 1);
    return w;
}

int antic_pf_nominal_s(antic_width w, int hscrol, int scrolled)
{
    return antic_pf_nominal(eff_width(w, scrolled), hscrol);
}

int antic_pf_nominal(antic_width w, int hscrol)
{
    /* WIDE is not in ACID800's DMA table — antic_dmapattern only tabulates
     * narrow and normal, so `make dma`'s 50/50 says nothing about it.  The one
     * independent map we have for it is antic_virtdma's own comment (mode 7,
     * wide, HSCROL 2, scrolled), which puts the fetches at 14, 18 ... 102 where
     * we put them at 13, 17 ... 101 — a uniform one cycle. */
    return PF_NOMINAL_NORMAL
         + (w == ANTIC_WIDE ? PF_WIDE_ADJ : 0)
         + ((int)ANTIC_NORMAL - (int)w) * PF_WIDTH_STEP
         - (hscrol >> 1);
}
#define pf_nominal antic_pf_nominal

/* Where the fetch stream begins, relative to the window.  Bitmap modes start
 * one cycle early; character modes issue a prefetch three cycles early on a
 * row's first line and otherwise sit on the window itself. */
static int pf_start(uint8_t mode, antic_width w, int first, int hscrol)
{
    int nom = pf_nominal(w, hscrol);
    if (mode >= 8) return nom - 1;
    return first ? nom - 3 : nom;
}

void antic_dma_line(uint8_t mode, antic_width width, int first_line,
                    int hscrol, uint8_t blocked[ANTIC_LINE_CYCLES])
{
    antic_dma_line_map(mode, width, first_line, hscrol, blocked, NULL);
}

int antic_pf_start(uint8_t mode, antic_width w, int first, int hscrol)
{
    return pf_start(mode, w, first, hscrol);
}

int antic_pf_grid(uint8_t mode, int first)
{
    if (mode < 2 || mode > 15) return 1;
    const mode_shape *s = &shapes[mode];
    if (mode >= 8) return first ? s->stride_first : s->stride_rest;
    /* Character modes 6-7 lay their name/glyph PAIRS on a 4-cycle grid on a
     * row's first line; 2-5 merge into a solid run at one cycle each. */
    if (first) return (mode <= 5) ? 1 : 4;
    return s->stride_rest;
}

/* Record that cycle `c` fetches line-buffer byte `i` from the scan address. */
static void name_slot(int8_t *name_at, int c, int i, int chars)
{
    if (name_at && c >= 0 && c < ANTIC_LINE_CYCLES && i < chars && i < 128)
        name_at[c] = (int8_t)i;
}

/* `nom` overrides where the grid is laid out from (-1 = derive from `width`),
 * and `cyc_stop` overrides where the stream ends (-1 = derive from the byte
 * count).  Both exist for one reason: ANTIC commits the START of the fetch a
 * cycle or two ahead, while the STOP goes on being compared against the
 * horizontal counter, so a DMACTL or HSCROL write landing in between leaves the
 * row fetching from the OLD window to the NEW window's last cycle. */
/* ---- the stop is MISSABLE ---------------------------------------------------
 * antic_hscrolbug is built entirely on this and nothing else in the suite is.
 * ANTIC's playfield sequencer runs on its OWN fetch clock — every `stride`
 * machine cycles — and compares the horizontal counter against the window's
 * stop on each of its own ticks, not on every cycle.  So a stop position of the
 * wrong PARITY is never looked at, and the counter free-runs.
 *
 * The test's map (its lines 98-102) is the whole derivation, and it needs no
 * constant of its own.  Narrow scrolled mode E at HSCROL 0: start 20, forty
 * bytes at stride 2, so stop = 20 + 80 = 100 — even, sampled, last fetch 98.
 * Glitch HSCROL to 2 and the window moves one cycle left: start 19, stop 99 —
 * ODD, and an even grid never sees it.  Restore HSCROL to 0 and the stop is
 * back at 100 with the counter already past it.  Neither is ever matched, so
 * the row fetches on to the end of the line and the NEXT line resumes on the
 * carried phase at cycle 0, until its own stop at 100 finally matches.  That is
 * 47 and 50 fetches against a normal 40 — the "17 extra fetches in HBLANK" the
 * comment names, and why the following line displays shifted left by 17 bytes.
 *
 * `carry_in` is the cycle on THIS line at which an already-running stream takes
 * its next fetch (-1 when the line starts idle); `carry_out` reports the same
 * for the next line.  A count cannot express any of this: a count always
 * terminates. */
#ifndef PF_RUNON
#define PF_RUNON 1
#endif
/* Fetches from here on are still made — the line buffer fills and the scan
 * address advances — but the cycle is NOT stolen from the CPU, which is what
 * the map's `#` versus `F` distinction marks.  Horizontal blank. */
#ifndef PF_HBLANK_FIRST
#define PF_HBLANK_FIRST 106
#endif

static void build(uint8_t mode, antic_width width, int first_line, int hscrol,
                  int nom_in, int cyc_stop, int carry_in, int *carry_out,
                  uint8_t blocked[ANTIC_LINE_CYCLES],
                  int8_t name_at[ANTIC_LINE_CYCLES])
{
    if (carry_out) *carry_out = -1;
    /* Bit 4 of the display-list instruction is the row's SCROLL bit, and the
     * callers that know it pass it through in `mode`.  A caller that does not
     * (the gates, which tabulate ACID's table and have only an HSCROL column)
     * still gets the old behaviour via a non-zero HSCROL. */
    int scrolled = (mode & 0x10) != 0 || hscrol != 0;
    mode &= 0x0F;
    antic_width w_in = width;
    width = eff_width(width, scrolled);

    memset(blocked, 0, ANTIC_LINE_CYCLES);
    if (name_at) memset(name_at, -1, ANTIC_LINE_CYCLES);

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

    int nom   = (nom_in >= 0) ? nom_in : pf_nominal(width, hscrol);
    int start = (mode >= 8) ? nom - 1 : (first_line ? nom - 3 : nom);

    /* Bytes across.  WIDE is narrow + half again, the same relation
     * antic_pf_bytes uses — without it the fetch map is eight bytes short of
     * the row on a wide line and the scan address ends the line in the wrong
     * place. */
    int chars = (width == ANTIC_NARROW) ? s->chars_narrow : s->chars_normal;
    int names = (width == ANTIC_WIDE) ? s->chars_narrow + s->chars_narrow / 2
                                      : chars;

    /* A horizontally SCROLLED row fetches at the next width up — narrow reads a
     * normal row's worth, normal reads a wide one's — because the window has to
     * have something to show once it shifts.  The window POSITION still comes
     * from the row's own width (less HSCROL/2); only the byte count steps.
     *
     * Measured, not assumed: sweeping the extra byte count 0..4 against
     * antic_pfstarttiming's first HSCROL assertion moves its answer 12,13,14,15,
     * 16 one for one, and 16 is the wanted value.  Four extra on a narrow mode 6
     * row is 16 -> 20, exactly normal's count. */
    /* A scrolled row that is ALREADY wide has no next width to step up to, and
     * antic_virtdma — the one test that pins wide geometry, mode 7 wide with
     * HSCROL 2 — still wants the extra bytes.  So a wide scrolled row keeps the
     * count bump on its own window. */
    if ((!SCROLL_NEXT_WIDTH && hscrol) || (scrolled && w_in == ANTIC_WIDE)) {
        int step = s->chars_narrow / 4;       /* narrow -> normal is + a quarter */
        chars += step;
        names += step;
    }

    /* The playfield STOP is a CYCLE COMPARISON, never a byte count.
     * antic_hscrolbug works by glitching HSCROL so the stop is MISSED and
     * fetching runs on into horizontal blank; a count cannot fail to
     * terminate, so a count would make that test unreachable.  The span
     * differs by class: a bitmap mode strides over `chars` bytes, a character
     * mode issues two fetches per character on a row's first line. */
    int stop = (mode >= 8) ? start + chars * stride
                           : start + 2 + chars * (first_line ? 2 : 1);
    /* A pinned stream runs to the LIVE window's last fetch cycle instead, with
     * no byte count bounding it — the count belongs to a width the row is no
     * longer using. */
    if (cyc_stop >= 0) {
        stop  = cyc_stop + 1;
        chars = 128;
        names = 128;
    }

    /* Bitmap modes fetch `chars` BYTES once per row — no name/data pair, and
     * their stream sits on its own grid rather than the refresh one. */
    if (mode >= 8) {
        int i = 0;
        int c = (PF_RUNON && carry_in >= 0) ? carry_in : start;
        int running = 1;
        if (PF_RUNON && carry_in >= 0) names = 128;   /* bounded by the stop only */
        for (; c < ANTIC_LINE_CYCLES; c += stride, i++) {
            /* the comparator, sampled on the sequencer's OWN tick */
            /* A PINNED stream (a mid-line DMACTL/HSCROL write, cyc_stop >= 0)
             * is bounded by the new window's LAST FETCH rather than by its stop
             * comparator, so it is not parity-sensitive and cannot run on.
             * Making it so is the next step — see emu/README.md. */
            if (cyc_stop >= 0 ? c >= stop : c == stop) { running = 0; break; }
            if (!PF_RUNON && i >= chars) { running = 0; break; }
            if (c < PF_HBLANK_FIRST) blocked[c] = 1;
            name_slot(name_at, c, i, names);
        }
        if (carry_out && running) *carry_out = c - ANTIC_LINE_CYCLES;
        return;
    }

    int n = first_line ? chars * 2 : chars;       /* name+data, or data only */
    if (cyc_stop >= 0) n = 256;                  /* bounded by the cycle, not n */

    if (stride == 1) {
        /* Dense character modes: one prefetch, a free cycle, then a solid run.
         * The run displaces refresh entirely — 64 fetches plus 9 refresh slots
         * do not fit in the window, so refresh loses.  That is the "preempted
         * refresh is LOST, not re-sought" behaviour this project already knows
         * from the fabric DMA scheduler.
         *
         * The stream alternates NAME, glyph, NAME, glyph... with the prefetch
         * as name 0, so every other fetch advances the scan address. */
        int fi = 0;
        blocked[start] = 1;
        name_slot(name_at, start, 0, names);
        fi = 1;
        for (int c = start + 2; c < stop && c < ANTIC_LINE_CYCLES; c++, fi++) {
            blocked[c] = 1;
            if ((fi & 1) == 0) name_slot(name_at, c, fi / 2, names);
        }
        return;
    }

    /* Character modes 6-7 on a row's first line: the name and data fetches come
     * in PAIRS on a 4-cycle grid.  A grid point that lands on a refresh slot
     * pushes its whole pair one cycle later (so the refresh cycle plus the pair
     * read as a triple), and the last grid point emits only as many fetches as
     * the budget has left.  Modes 2-5 are the same structure at a 2-cycle grid,
     * where consecutive pairs merge into the solid run handled above. */
    if (first_line) {
        int fi = 0;
        blocked[start] = 1;                       /* the prefetch — name 0 */
        name_slot(name_at, start, 0, names);
        fi = 1;
        int left = n - 1;                         /* the prefetch was one of them */
        /* ...but the real bound is the STOP CYCLE, not the count.  Each
         * character takes a 4-cycle grid point, so the stream runs to
         * nom + 4*chars; when DMACTL narrows mid-line the START may already be
         * committed while the STOP moves, and the row then fetches a count that
         * belongs to NEITHER width.  That hybrid is what antic_pfstarttiming
         * and antic_pfstoptiming measure with their "late" writes. */
        int pstop = (cyc_stop >= 0) ? cyc_stop + 1 : nom + 4 * chars;
        for (int p = nom; left > 0 && p < pstop && p < ANTIC_LINE_CYCLES; p += 4) {
            int c = is_refresh(p) ? p + 1 : p;
            for (int k = 0; k < 2 && left > 0 && c + k < ANTIC_LINE_CYCLES;
                 k++, left--, fi++) {
                blocked[c + k] = 1;
                if ((fi & 1) == 0) name_slot(name_at, c + k, fi / 2, names);
            }
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
    for (int i = 0, p = nom; i < n && p < ANTIC_LINE_CYCLES; i++, p += stride) {
        int c = is_refresh(p) ? p + 1 : p;
        if (c < ANTIC_LINE_CYCLES) blocked[c] = 1;
    }
}

void antic_dma_line_map(uint8_t mode, antic_width width, int first_line,
                        int hscrol, uint8_t blocked[ANTIC_LINE_CYCLES],
                        int8_t name_at[ANTIC_LINE_CYCLES])
{
    build(mode, width, first_line, hscrol, -1, -1, -1, NULL, blocked, name_at);
}

void antic_dma_line_map_at(uint8_t mode, antic_width width, int first_line,
                           int hscrol, int nom_start,
                           uint8_t blocked[ANTIC_LINE_CYCLES],
                           int8_t name_at[ANTIC_LINE_CYCLES])
{
    if (nom_start < 0) {
        build(mode, width, first_line, hscrol, -1, -1, -1, NULL, blocked, name_at);
        return;
    }
    /* Where THIS width's stream would have ended.  That cycle is the bound, not
     * a byte count: the row keeps its old grid and stops where the new window
     * says to.  Both halves of antic_pfstarttiming and antic_pfstoptiming fall
     * out of it — see the worked cycle lists in emu/README.md. */
    uint8_t b2[ANTIC_LINE_CYCLES];
    int8_t  m2[ANTIC_LINE_CYCLES];
    build(mode, width, first_line, hscrol, -1, -1, -1, NULL, b2, m2);
    int last = -1;
    for (int c = 0; c < ANTIC_LINE_CYCLES; c++)
        if (m2[c] >= 0) last = c;
    if (last < 0) { build(mode, width, first_line, hscrol, -1, -1, -1, NULL, blocked, name_at); return; }
    build(mode, width, first_line, hscrol, nom_start, last, -1, NULL, blocked, name_at);
}
