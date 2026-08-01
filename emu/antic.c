/*
 * antic.c — the ANTIC timing core.  See antic.h.
 */
#include "antic.h"

/* ---- two HSCROL experiments, both OFF ------------------------------------
 * Neither is confirmed by any assertion, so neither runs by default; the code
 * and the reasoning are kept because the analysis behind them is sound and the
 * next attempt should not start from scratch.  See emu/README.md.
 *
 * HSCROL_CC_DISPLAY — antic_pf_nominal folds HSCROL into the fetch grid as
 *   `hscrol >> 1`, which is right for the grid (half a machine cycle per unit)
 *   and throws the odd colour clock away for the DISPLAY, where a unit is a
 *   whole colour clock.  Correct-looking on its own; changes no test.
 * HSCROL_CLAMP / HSCROL_REACH — a mid-line HSCROL write claiming only
 *   REACH - cycle units of scroll, the rate-based rule antic_pfstarttiming's
 *   one-unit delta seems to call for.  It does clamp (8 early, 7 late) and the
 *   measured stride does not move, because the stride quantises in fours. */
#ifndef HSCROL_CC_DISPLAY
#define HSCROL_CC_DISPLAY 0
#endif
#ifndef HSCROL_CLAMP
#define HSCROL_CLAMP 0
#endif
#ifndef HSCROL_REACH
#define HSCROL_REACH 25
#endif
/* HSCROL's own commit lead, separate from DMACTL's PF_COMMIT_LEAD. */
#ifndef HSCROL_COMMIT_LEAD
#define HSCROL_COMMIT_LEAD PF_COMMIT_LEAD
#endif

/* An RMW writes WSYNC twice; the second write arriving while the halt is
 * already armed pushes the release out by this many cycles.  Overridable so it
 * can be A/B'd — gtia_pmresize's whole cycle chain sits one late with it. */
#ifndef WSYNC_RMW_EXTRA
#define WSYNC_RMW_EXTRA 1
#endif
/* ...and whether that only applies when the two writes are ADJACENT.  An RMW's
 * writes are on consecutive CPU cycles, but a DMA cycle can fall between them:
 * antic_wsync's INC lands its pair at scanline cycles 1 and 2, gtia_pmresize's
 * at 32 and 34 with a memory refresh at 33.  That is the only structural
 * difference between the two, and they want different releases. */
#ifndef WSYNC_RMW_ADJACENT
#define WSYNC_RMW_ADJACENT 0
#endif
#include <stdio.h>
int antic_glyph_probe;
#include <string.h>

/* Scanlines per row.  Mode 3 is ten rather than eight — its last two carry the
 * descenders for characters $60-$7F (antic_charcontrol). */
const uint8_t antic_row_height[16] = {
    [2] = 8,  [3] = 10, [4] = 8,  [5] = 16,
    [6] = 8,  [7] = 16, [8] = 8,  [9] = 4,
    [10] = 4, [11] = 2, [12] = 1, [13] = 2,
    [14] = 1, [15] = 1,
};

/* Playfield bytes across, by width and mode.  Character modes 6-7 and the
 * coarser bitmap modes cover the same width in fewer bytes. */
int antic_pf_bytes(uint8_t dmactl, uint8_t mode)
{
    static const uint8_t narrow[16] = {
        [2]=32,[3]=32,[4]=32,[5]=32,[6]=16,[7]=16,
        [8]=8,[9]=8,[10]=16,[11]=16,[12]=16,[13]=32,[14]=32,[15]=32,
    };
    if (mode > 15) return 0;
    int n = narrow[mode];
    switch (dmactl & 0x03) {
    case 0:  return 0;
    case 1:  return n;                    /* narrow */
    case 3:  return n + n / 2;            /* wide   */
    default: return n + n / 4;            /* normal */
    }
}

uint8_t antic_display_byte(const antic *a, int i)
{
    if (i < 0 || i >= (int)sizeof a->linebuf) return 0;
    return a->linebuf[i];
}

/* Fetch a display-list byte and advance the DL counter within its 1 KB page. */
static uint8_t dl_fetch(antic *a)
{
    uint8_t v = a->fetch ? a->fetch(a->ctx, a->dl_addr) : 0xFF;
    a->dl_addr = antic_dl_next(a->dl_addr);
    return v;
}

void antic_dl_exec(antic *a)
{
    uint16_t at = a->dl_addr;
    uint8_t insn = dl_fetch(a);
    if (antic_glyph_probe > 1)
        fprintf(stderr, "  DLEXEC sl %3d $%04X insn $%02X dmactl $%02X\n",
                a->scanline, at, insn, a->dmactl);
    a->dl_insn   = insn;
    a->row_line  = 0;
    a->dli_fired = 0;

    int mode = insn & 0x0F;

    /* Vertical scrolling is a ROW-COUNTER trick, not a height adjustment:
     *   entering a scrolled region — the counter STARTS at VSCROL, so the first
     *     row is short by that much;
     *   leaving one — the next row starts at 0 and ends when the counter
     *     reaches VSCROL, compared LIVE every scanline.
     * That live compare is the whole of antic_vscroldli: a VSCROL write one
     * cycle either side of the comparison moves the row's end, and with it the
     * following DLI.  Deriving a fixed height at fetch time cannot express it.
     * The blank-line instruction takes part too — the $F0 after the scrolled
     * mode 8 row is what the test actually measures. */
    int vs = (mode >= 2) && (insn & 0x20);
    int leaving = a->vscrol_prev && !vs;
    int entering = vs && !a->vscrol_prev;
    a->vscrol_prev = (uint8_t)vs;

    if (mode == 0x01) {                       /* jump */
        uint8_t lo = dl_fetch(a);
        uint8_t hi = dl_fetch(a);
        a->dl_addr = (uint16_t)(lo | (hi << 8));
        a->dl_done = (insn & 0x40) != 0;      /* JVB: wait for vertical blank */
        a->row_height = 1;
        return;
    }

    if (mode == 0x00) {
        /* A BLANK-LINE instruction has no option bits except the DLI: bits 6-4
         * are its LINE COUNT, plus one.  Reading bit 6 as LMS here — as the
         * obvious "decode the option bits first" ordering does — makes $70 look
         * like an LMS and eats two bytes of the display list, which derails
         * everything after it. */
        a->row_height = ((insn >> 4) & 0x07) + 1;
        a->row_end = leaving ? -1 : a->row_height - 1;
        return;
    }

    if (insn & 0x40) {                        /* LMS: reload the playfield scan
                                               * address.  The operand fetches
                                               * go through the same 1 KB-wrapping
                                               * counter, which is what
                                               * antic_addresswrap exploits. */
        uint8_t lo = dl_fetch(a);
        uint8_t hi = dl_fetch(a);
        a->pf_addr = (uint16_t)(lo | (hi << 8));
    }

    a->row_height = antic_row_height[mode];
    a->row_end    = a->row_height - 1;
    a->row_first  = 1;
    if (entering)
        a->row_line = a->vscrol & 0x0F;       /* start high: short first row */
    if (leaving)
        a->row_end = -1;                      /* end on the LIVE VSCROL compare */
}

/* The row's last scanline, resolved NOW.  -1 in row_end means the comparison is
 * against VSCROL as it stands at this instant. */
static int row_last(const antic *a)
{
    return a->row_end < 0 ? (a->vscrol & 0x0F) : a->row_end;
}

void antic_init(antic *a, antic_fetch_fn fetch, void *ctx, int lines)
{
    memset(a, 0, sizeof *a);
    a->fetch = fetch;
    a->ctx   = ctx;
    a->lines = lines ? lines : ANTIC_LINES_NTSC;
    antic_reset(a);
}

void antic_reset(antic *a)
{
    a->cycle = a->scanline = a->vcount = 0;
    a->wsync_halt = 0;
    /* Start PARKED, as if a JVB had just executed: a well-formed display list
     * only ever begins after vertical blank ends, and the release at scanline 8
     * is what puts it there.  Starting unparked runs the list from scanline 0
     * and shifts every DLI eight lines early. */
    a->dl_done  = 1;
    a->row_ends = 1;      /* armed, so the first line after the release fetches */
    a->nmi = 0;
    a->nmist = 0;
    a->nmien = 0;
}

/* HSCROL only applies to a row whose display-list instruction ASKS for
 * horizontal scrolling (bit 4).  Applying it to every row shifts unscrolled
 * playfields by up to fifteen colour clocks whenever the register happens to be
 * non-zero, which the register's leftover value from an earlier row makes easy
 * to hit. */
static int hscrol_of(const antic *a)
{
    return (a->dl_insn & 0x10) ? (a->hscrol_line & 0x0F) : 0;
}

static antic_width width_of(uint8_t dmactl)
{
    switch (dmactl & 0x03) {
    case 1:  return ANTIC_NARROW;
    case 3:  return ANTIC_WIDE;
    default: return ANTIC_NORMAL;
    }
}

/* Fetch the glyph row that goes with line-buffer entry `i`.
 *
 * Split out of line_start because the NAME is read PROGRESSIVELY across the
 * scanline now, so the glyph belonging to it has to be read at that same
 * moment.  The later scanlines of a character row still rebuild the whole array
 * up front: they re-read only the glyph, and the names are already in the
 * buffer.
 *
 * CHACTL's vertical reflect picks a different row of the SAME character, so it
 * belongs here with the fetch, not in the pixel decode. */
static void fetch_glyph(antic *a, int mode, int i)
{
    if (i < 0 || i >= (int)sizeof a->glyphbuf) return;

    int row = a->glyph_row;
    uint16_t cbase = (mode <= 5) ? (uint16_t)((a->chbase & 0xFC) << 8)
                                 : (uint16_t)((a->chbase & 0xFE) << 8);
    uint8_t  cmask = (mode <= 5) ? 0x7F : 0x3F;
    uint8_t  name  = a->linebuf[i];
    int grow = row;

    /* Modes 5 and 7 are 16 scanlines tall over an 8-row glyph, so each glyph
     * row is shown twice. */
    if (mode == 5 || mode == 7)
        grow >>= 1;

    /* Mode 3 is TEN scanlines over an eight-row glyph.  The row counter runs
     * 0..9 and the glyph is indexed by its LOW THREE BITS, so rows 8 and 9 come
     * back round to glyph rows 0 and 1; which two rows are blanked is what the
     * character selects.  $60..$7F — the lowercase descenders — blank rows 0..1,
     * everything else blanks 8..9.
     *
     * It is NOT a downward shift.  antic_charcontrol's descender table expects
     * rows 2..7 to show glyph rows 2..7 and rows 8..9 to show glyph rows 0..1;
     * subtracting two puts every row one object to the left of where the test
     * looks for it. */
    if (mode == 3) {
        int blank = ((name & 0x60) == 0x60) ? (grow < 2) : (grow >= 8);
        if (blank) { a->glyphbuf[i] = 0; return; }
        grow &= 7;
    }

    /* CHACTL's vertical reflect mirrors the GLYPH's eight rows, not the row
     * counter.  In mode 3 that matters: the counter runs to ten, and reflecting
     * it would move the two blank rows from 8..9 up to 0..1 — antic_charcontrol's
     * reflect table keeps them at 8..9 and reverses only the eight rows that
     * carry the glyph. */
    if (a->chactl & 0x04)
        grow = 7 - grow;

    a->glyphbuf[i] = a->fetch(a->ctx,
        (uint16_t)(cbase + (name & cmask) * 8 + grow));
    if (i == 0 && antic_glyph_probe)
        fprintf(stderr, "  sl %3d mode %d chactl $%02X chbase $%02X row_line %d "
                "row_height %d row %d grow %d name $%02X glyph $%02X\n",
                a->scanline, mode, a->chactl, a->chbase, a->row_line,
                a->row_height, row, grow, name, a->glyphbuf[i]);
}

/* Start of a scanline: advance the display list if the current row has
 * finished, work out whether a DLI is due, and rebuild this line's DMA
 * schedule from the LIVE state.  Nothing here is precomputed for the frame —
 * VSCROL can change a row's height while it is running, which moves the next
 * row's DLI with it (antic_vscroldli). */
/* Player/missile DMA.  Three things here are each their own ACID800 assertion:
 *
 *  - DMACTL's player-DMA bit IMPLIES missile DMA.  They are not the two
 *    independent gates the bit names suggest.
 *  - PMBASE bit 2 is masked at ADDRESS-GENERATION time by the current
 *    resolution, not filtered when the register is written: one-line resolution
 *    needs a 2 KB-aligned region so the bit is dormant, two-line needs only 1 KB
 *    so it is live.  antic_pmdma sets it in one resolution and switches to the
 *    other without rewriting PMBASE.
 *  - the row index is the SCANLINE in one-line resolution and scanline>>1 in
 *    two-line, which is the whole difference in fetch cadence. */
static void pm_dma(antic *a)
{
    int player  = (a->dmactl & 0x08) != 0;
    int missile = (a->dmactl & 0x04) != 0 || player;
    if (!player && !missile)
        return;

    if (a->dmactl & 0x10) {                 /* one-line resolution, 2 KB region */
        uint16_t base = (uint16_t)((a->pmbase & 0xF8) << 8);
        uint16_t idx  = (uint16_t)(a->scanline & 0xFF);
        if (missile) a->pm_m = a->fetch(a->ctx, (uint16_t)(base + 0x300 + idx));
        if (player)
            for (int i = 0; i < 4; i++)
                a->pm_p[i] = a->fetch(a->ctx,
                             (uint16_t)(base + 0x400 + i * 0x100 + idx));
    } else {                                /* two-line resolution, 1 KB region */
        uint16_t base = (uint16_t)((a->pmbase & 0xFC) << 8);
        uint16_t idx  = (uint16_t)((a->scanline >> 1) & 0x7F);
        if (missile) a->pm_m = a->fetch(a->ctx, (uint16_t)(base + 0x180 + idx));
        if (player)
            for (int i = 0; i < 4; i++)
                a->pm_p[i] = a->fetch(a->ctx,
                             (uint16_t)(base + 0x200 + i * 0x80 + idx));
    }
    a->pm_fetched = 1;
}

static void line_start(antic *a)
{
    a->hscrol_line = a->hscrol;           /* the clamp is per-line */
    memset(a->blocked, 0, sizeof a->blocked);
    memset(a->pf_at, -1, sizeof a->pf_at);
    a->pf_next = 0;
    a->dli_line = 0;

    /* Memory refresh is taken on EVERY scanline, whatever DMACTL says — nine
     * cycles the CPU does not get even with the screen off.  Building it only
     * along the playfield path let the CPU run nine cycles a line too fast
     * whenever DMA was off, which is exactly the gap gtia_pmretrigger's fourth
     * case shows: its "sta hposp0" landed on cycle 81 against an annotated 90. */
    antic_dma_refresh(a->blocked);

    if (a->fetch)
        pm_dma(a);

    /* Display-list EXECUTION has no bottom cutoff — the list runs until it
     * executes a JVB, so a list longer than the visible region carries on past
     * the bottom of the frame and into the next one.  antic_dlistwrap builds
     * exactly that case: 248 blank lines then a DLI, which lands around
     * scanline 256 and must still fire.  Bounding this by the display window is
     * the intuitive reading and silently drops that DLI. */
    if (a->dl_done)
        return;

    /* Only FETCHING a new instruction needs display-list DMA.  A row already in
     * progress keeps running — and keeps its DLI — when DMACTL is cleared out
     * from under it. */
    if (a->row_ends) {
        a->row_ends = 0;
        if (!(a->dmactl & 0x20) ||
            a->scanline < ANTIC_DISPLAY_TOP || a->scanline >= ANTIC_DISPLAY_BOTTOM)
            return;
        antic_dl_exec(a);
    }

    /* The DLI belongs to the LAST scanline of the row — including a BLANK-LINE
     * row, which is the case antic_dlitiming is built out of and the fabric
     * dl_parser gets wrong. */
    /* the DLI's own row-end compare is made live at NMIST time, not here — see
     * antic_tick */

    int mode = a->dl_insn & 0x0F;
    if (mode >= 2 && (a->dmactl & 0x20)) {
        antic_dma_line_map((uint8_t)mode, width_of(a->dmactl),
                           a->row_first, hscrol_of(a), a->blocked, a->pf_at);

        /* FETCH into the line buffer.  The playfield counter wraps at 4 KB
         * during the fetch, so a row crossing that boundary reads from the
         * bottom of the same 4 KB page (antic_addresswrap).
         *
         * Note what is NOT done here: the buffer is not cleared first.  If
         * playfield DMA is off this line, the previous contents stay and are
         * displayed again — which is what antic_linebuffering's
         * "mid-interrupted" and "replayed" cases check. */
        int n = antic_pf_bytes(a->dmactl, (uint8_t)mode);

        /* Playfield data is fetched ONCE, on the row's first scanline, and
         * re-displayed from the buffer for the rest of the row — for BITMAP
         * modes as much as character ones.  antic_dma.c already says so: every
         * mode from 8 up has stride_rest = 0, i.e. no fetch on later scanlines.
         * Only the character modes re-fetch, and only their glyph row.
         *
         * That is the whole of antic_linebuffering's "aliased" scenarios: it
         * turns playfield DMA off, lets a mode 8 row START under that, then
         * turns DMA back on mid-row and checks the STALE buffer is what gets
         * displayed.  Re-fetching every scanline quietly refills it. */
        /* A DMACTL width of zero means no playfield DMA at all, and then the
         * buffer is left ENTIRELY alone — contents and length both.  Zeroing
         * lb_len here still wipes the stale data as far as the decode is
         * concerned, which is what antic_linebuffering's "aliased mode F"
         * case catches: the row starts with DMA off, so nothing is fetched, and
         * the previous row's 40 bytes must still be there to be re-displayed. */
        /* The bytes themselves arrive one at a time during antic_tick, at the
         * cycles pf_at names.  Only the LENGTH is settled here, because the
         * decode has to know how wide the row is before the first byte lands —
         * and because leaving it alone is what makes a DMA-off line re-display
         * the previous row.  Display lags the fetch by PF_DISPLAY_LEAD cycles,
         * so a position is always filled before it is shown. */
        /* A DMACTL width of ZERO is not a width — it is no playfield DMA at
         * all.  width_of() maps it to NORMAL (which is what the blocked map has
         * always assumed), so the fetch map has to be dropped explicitly or a
         * screen with playfield DMA off would quietly fetch a normal row.  That
         * is exactly what antic_linebuffering's "survives DMA being turned off"
         * and "re-displayable" cases catch. */
        if (n == 0) memset(a->pf_at, -1, sizeof a->pf_at);
        if (n > 0 && a->row_first) a->lb_len = n;

        /* Later scanlines of a character row re-read only the GLYPH — the
         * names are already in the buffer, so the whole array can be rebuilt
         * here.  A row's FIRST line reads each glyph as its name arrives, in
         * the progressive fetch below. */
        a->glyph_row = (uint8_t)a->row_line;
        if (mode >= 2 && mode <= 7 && n > 0 && !a->row_first)
            for (int i = 0; i < n; i++) fetch_glyph(a, mode, i);
    }

    /* The glyph row for THIS scanline, captured before the counter moves on —
     * the progressive fetch runs after line_start has advanced it. */
    a->glyph_row = (uint8_t)a->row_line;
    a->row_line = (a->row_line + 1) & 0x0F;
}

/* Rebuild the rest of this scanline's schedule from the LIVE registers.
 *
 * ANTIC does not latch DMACTL or HSCROL for the line; the window edges are
 * compared against the horizontal counter as it runs, so a write part way down
 * the line moves the edges for whatever is still to come.  Cycles already past
 * keep what they did — the bytes they fetched stay fetched, and the running
 * count carries on — so shortening the window mid-fetch truncates the row and
 * widening it extends it, which is exactly what antic_pfstarttiming,
 * antic_pfstoptiming and antic_hscrolbug measure. */
/* The playfield window as the registers stand right now, in machine cycles:
 * where it opens, and how wide it is (128/160/192 colour clocks). */
static int pf_window(const antic *a)
{
    return antic_pf_nominal(width_of(a->dmactl), hscrol_of(a));
}

static int pf_span(const antic *a)
{
    switch (width_of(a->dmactl)) {
    case ANTIC_NARROW: return 64;
    case ANTIC_WIDE:   return 96;
    default:           return 80;
    }
}

static void rebuild_line(antic *a, int old_nom, int old_span, int lead)
{
    int from = a->cycle;                    /* the next cycle to run */
    if (from < 0 || from >= ANTIC_LINE_CYCLES) return;

    uint8_t blk[ANTIC_LINE_CYCLES];
    int8_t  map[ANTIC_LINE_CYCLES];
    int mode = a->dl_insn & 0x0F;
    int on   = mode >= 2 && (a->dmactl & 0x20);

    /* The window this line was running under: where it opened and where it
     * closes.  The commit point is the window's own earliest fetch — nom - 3,
     * the character prefetch position — for EVERY mode, not the class-specific
     * start: a bitmap row starts at nom - 1 and still ignores a write that
     * lands at nom - 3.  The close is the window's edge, NOT the last actual
     * fetch: antic_pfstoptiming widens after the last narrow fetch has already
     * happened and still expects the stream to extend, so it is the comparator
     * that is still open, not the fetcher that is still running.  The window is
     * `span` machine cycles long measured FROM that same start, which puts the
     * narrow close at 26 + 64 = 90 — after narrow's last fetch at 86, and before
     * the next grid point it would have taken. */
    int old_start = old_nom - lead;
    int old_close = old_nom + old_span
                  - antic_pf_grid((uint8_t)mode, a->row_first);

    /* ANTIC commits the START of the fetch a cycle or two ahead of it, but goes
     * on comparing the STOP against the horizontal counter.  A write landing in
     * between therefore leaves the row running on its OLD grid to the NEW
     * window's last fetch cycle, and its byte count belongs to neither width —
     * which is exactly the 18 that antic_pfstarttiming and antic_pfstoptiming
     * both ask for, from opposite directions. */
    int pin = (from >= old_start) ? old_nom : -1;

    antic_dma_line_map_at(on ? (uint8_t)mode : 0, width_of(a->dmactl),
                          a->row_first, hscrol_of(a), pin, blk, map);

    /* Turning playfield DMA OFF part way down a line does not stall the line
     * buffer — ANTIC keeps clocking it and latches whatever is on the bus, so
     * the buffer position and the scan address both carry on.  Only the CPU
     * gets those cycles back.  antic_linebuffering's test 5 is built on exactly
     * that: it kills DMACTL across the centre of a mode 8 row, does NOT check
     * the bytes in the gap ("from the bus, but we don't test that yet"), and
     * requires the bytes to the RIGHT of it to be unshifted.  Dropping the
     * fetch slots here would slide the rest of the row left.
     *
     * A row that STARTS with DMA off is a different case, handled in
     * line_start: nothing is fetched at all and the previous row is redisplayed. */
    int keep_map = !on || antic_pf_bytes(a->dmactl, (uint8_t)mode) == 0
                /* ...and once the stream has ENDED it cannot be restarted:
                 * antic_pfstoptiming's late case widens the playfield after the
                 * row has finished fetching and requires the narrow count. */
                || from > old_close;

    for (int c = from; c < ANTIC_LINE_CYCLES; c++) {
        a->blocked[c] = blk[c];
        if (!keep_map) a->pf_at[c] = map[c];
    }
}

int antic_tick(antic *a)
{
    int c = a->cycle;
    int took = 0;

    /* Cleared here rather than at the end, so it is still standing when the CPU
     * makes its access for the cycle just ticked — see the NMIRES case. */
    a->nmist_set_now = 0;

    if (c == 0) line_start(a);

    /* ---- the playfield fetch, one byte at the cycle that reads it ----------
     * ANTIC reads the playfield ACROSS the scanline, not in one go at its
     * start, and three ACID800 tests are built entirely on that: a DMACTL or
     * HSCROL write part way down the line moves the window under a fetch that
     * is already running (antic_pfstarttiming, antic_pfstoptiming,
     * antic_hscrolbug).  pf_at was built at line_start from the geometry the
     * DMA schedule uses, so the byte and the stolen cycle cannot disagree.
     *
     * The scan address advances per ACTUAL fetch, which is what makes the
     * STRIDE those tests measure fall out rather than being asserted. */
    if (c < ANTIC_LINE_CYCLES && a->pf_at[c] >= 0) {
        /* The index is a RUNNING COUNT, not the map's own number, because the
         * map can be rebuilt mid-line when DMACTL or HSCROL moves the window.
         * Bytes already fetched stay fetched and the sequence carries on, so
         * the row's byte count follows from how many fetch cycles actually
         * happened — which is the "STOP is a cycle comparison, never a count"
         * rule antic_dma.c states and antic_hscrolbug depends on. */
        int i = a->pf_next++;
        if (i < (int)sizeof a->linebuf) {
            a->linebuf[i] = a->fetch ? a->fetch(a->ctx, a->pf_addr) : 0xFF;
            a->pf_addr = antic_pf_next(a->pf_addr);
            int m = a->dl_insn & 0x0F;
            if (m >= 2 && m <= 7 && a->fetch) fetch_glyph(a, m, i);
        }
    }

    /* Whether the row finishes with this scanline is decided PART WAY THROUGH
     * it, not at its start: that is the only way a VSCROL write on cycle 3 can
     * still land while one on cycle 4 is too late.  row_line has already been
     * incremented past this scanline by line_start, hence the -1. */
    if (c == ANTIC_CYC_ROWEND) {
        int last = row_last(a);
        /* The row counter is FOUR BITS and the end test is EQUALITY, so a
         * VSCROL that overshoots the mode's height makes the row run all the
         * way round rather than ending immediately.  antic_linebuffering's
         * $2f is mode F — height ONE — entered with VSCROL = 1, and its display
         * list says that row spans sixteen scanlines: 1,2,..15,0. */
        a->row_ends = (uint8_t)(((a->row_line - 1) & 0x0F) == last);
        /* The DLI's compare is taken from the SAME sample, not re-read at NMIST
         * time: NMIST lands on cycle 6, so re-reading there would let a VSCROL
         * write on cycle 4 count, and antic_vscroldli's second probe requires
         * exactly that write to be too late. */
        /* Once the row's last scanline has passed and the next fetch cannot
         * happen, the row-end condition stays true and the latched instruction
         * keeps its DLI bit — so the DLI would re-fire every scanline.  Whether
         * it does depends on WHY the fetch is stalled, and the suite pins both
         * halves:
         *   DL DMA switched off mid-display — it DOES keep re-firing, which is
         *     how antic_dlistwrap's second test still sees its DLI a frame
         *     later, with DMACTL at zero throughout;
         *   vertical blank — it does NOT.  antic_hiresbug's handler re-entered
         *     every three scanlines, exactly its own length, and read a
         *     collision from a display line it should never have reached.
         * A first firing outside the display region is still allowed: that is
         * antic_dlistwrap's FIRST test, whose DLI lands on scanline 1 of the
         * next frame from a row that overran the bottom. */
        int blanking = a->scanline < ANTIC_DISPLAY_TOP ||
                       a->scanline >= ANTIC_DISPLAY_BOTTOM;
        a->dli_line = (uint8_t)((a->dl_insn & 0x80) && !(blanking && a->dli_fired) &&
                                (((a->row_line - 1) & 0x0F) == last));
        if (a->dli_line) a->dli_fired = 1;
    }

    /* /NMI is a ONE-CYCLE PULSE that follows the status by one cycle, and it is
     * run as a countdown rather than off a fixed cycle because a request armed
     * by a LATE NMIEN WRITE costs one cycle more than one armed by the status
     * set itself.  antic_dlitiming's two delay tests are what separate them:
     * both disable NMIEN across the DLI point and re-enable it at scanline
     * cycle 7, and both must deliver at the same place, which they only do if
     * the write path takes two cycles where the status path takes one.
     *
     * The pulse is not a held line: real DLI handlers do not write NMIRES —
     * they PHA, set a colour, PLA, RTI — yet multi-DLI kernels work, so each
     * event has to produce its own edge.  Holding it high gives the CPU exactly
     * ONE NMI for an entire run.  system.c latches it so a pulse landing inside
     * a DMA burst, where the CPU is not being serviced, is still seen. */
    if (a->nmi) a->nmi = 0;
    if (a->nmi_arm && --a->nmi_arm == 0) a->nmi = 1;

    /* ---- status and interrupt timing, all at fixed cycles ------------------
     * NMIST bits set at cycle 6 REGARDLESS of NMIEN — NMIEN gates the
     * interrupt, not the status — and NMIEN is sampled at the same cycle to
     * decide whether the interrupt is raised (antic_nmist). */
    if (c == ANTIC_CYC_NMIST) {
        if (a->dli_line) {
            a->nmist = (uint8_t)((a->nmist & ~ANTIC_NMI_VBI) | ANTIC_NMI_DLI);
            a->nmist_set_now = 1;
            if (a->nmien & ANTIC_NMI_DLI) a->nmi_arm = 1;
        }
        int vbi = (a->scanline == ANTIC_DISPLAY_BOTTOM);
        if (vbi) {
            /* the DLI and VBI status bits clear each other on arrival */
            a->nmist = (uint8_t)((a->nmist & ~ANTIC_NMI_DLI) | ANTIC_NMI_VBI);
            a->nmist_set_now = 1;
            if (a->nmien & ANTIC_NMI_VBI) a->nmi_arm = 1;
        }
    }


    /* VCOUNT is scanline>>1, so it advances at cycle 111 of every ODD scanline.
     * Because that advance happens on the LAST scanline too (261 is odd), it
     * momentarily reads lines/2 = 131 — and then a comparator clears it ONE
     * CYCLE LATER, not at the end of the line.  That single cycle is the whole
     * of antic_vcount's "nasty one, single cycle rollover": its two rollover
     * probes sit on the SAME scanline and differ only in the read cycle, 111
     * (must read 131) against 112 (must read 0). */
    if (c == ANTIC_CYC_VCOUNT && (a->scanline & 1))
        a->vcount++;
    if (c == ANTIC_CYC_VCOUNT + 1 && a->scanline == a->lines - 1)
        a->vcount = 0;

    /* WSYNC: ANTIC_CYC_WSYNC is the first cycle the CPU gets BACK. */
    if (a->wsync_halt) {
        /* antic_wsync cannot settle where this boundary sits — its probes are
         * anchored to the release, so moving it moves them too.  gtia_pmretrigger
         * can, because it times an HPOS write against the beam: with memory
         * refresh correctly present on every scanline, giving the CPU 104 takes
         * it from failing its first case to failing its fourth. */
        if (c == ANTIC_CYC_WSYNC + a->wsync_extra) {
            a->wsync_halt = 0;
            a->wsync_extra = 0;
        } else if (!a->cpu_writing) {
            took = 1;
        }
    }

    if (!took && c < ANTIC_LINE_CYCLES && a->blocked[c])
        took = 1;

    /* ---- advance ---------------------------------------------------------- */
    a->ticks++;
    if (++a->cycle >= ANTIC_LINE_CYCLES) {
        /* ACID_GLYPHPROBE=9: this line's finished fetch map.  Printed HERE, at
         * the line's end, so it shows the schedule as a mid-line DMACTL or
         * HSCROL write left it — printing it from line_start shows only what
         * was planned at cycle 0, which is what the write is about to change. */
        if (antic_glyph_probe == 9) {
            fprintf(stderr, "  LN %3d insn $%02X dmactl $%02X hscrol $%02X n %d fetch:",
                    a->scanline, a->dl_insn, a->dmactl, a->hscrol, a->pf_next);
            for (int k = 0; k < ANTIC_LINE_CYCLES; k++)
                if (a->pf_at[k] >= 0) fprintf(stderr, " %d", k);
            fprintf(stderr, "\n");
        }
        a->cycle = 0;
        /* row_first has to stay standing for the WHOLE line: rebuild_line needs
         * to know which schedule shape this line has. */
        a->row_first = 0;
        if (++a->scanline >= a->lines) {
            a->scanline = 0;
            /* Nothing reloads the display-list counter here.  A list that ran
             * past the bottom of the frame simply CONTINUES into the next one —
             * a list returns to its start only by executing a JVB, which has
             * already loaded dl_addr with its operand.  Reloading from a DLIST
             * latch each frame is the intuitive model and it fails
             * antic_dlistwrap's first assertion outright.  Nor is row_line
             * reset: an overrunning row carries on across the boundary. */
        }
        /* A JVB parks the list until VERTICAL BLANK ENDS, which is scanline 8 —
         * not until the frame wraps.  That distinction is what lets a list which
         * overran keep executing through scanlines 0..7 of the new frame, where
         * antic_dlistwrap's DLI actually lands. */
        if (a->scanline == ANTIC_DISPLAY_TOP && a->dl_done) {
            a->dl_done  = 0;
            a->row_ends = 1;                /* force a fetch on the first line */
        }
    }
    return took;
}

/* Colour clocks per pixel and bits per pixel, for the BITMAP modes.  The
 * character modes (2..7) need a CHBASE glyph fetch and are not decoded yet. */
static const uint8_t pf_ccpp[16] = { 0,0,0,0,0,0,0,0, 4,2,2,1,1,1,1,1 };
static const uint8_t pf_bpp [16] = { 0,0,0,0,0,0,0,0, 2,1,2,1,1,2,2,1 };

int antic_pf_at(const antic *a, int cc, int *hires_lit)
{
    *hires_lit = 0;
    int mode = a->dl_insn & 0x0F;
    if (mode < 2 || !(a->dmactl & 0x20))
        return -1;

    /* Display starts a fixed THREE machine cycles after the nominal fetch
     * window — ANTIC fetches that far ahead — so the decode is anchored to the
     * very geometry the DMA schedule uses rather than to its own constants.
     * That gives $30 normal, $40 narrow, $20 wide, and antic_pmdma confirms it:
     * it parks player 0 at "$41-8" for a left-edge collision against a NARROW
     * playfield, which only overlaps if narrow begins at $40.  Independent
     * constants put it at $50 and no collision ever registered. */
    antic_width w = width_of(a->dmactl);
    /* HSCROL moves the DISPLAY a full colour clock per unit, but the FETCH grid
     * only half a machine cycle — antic_pf_nominal's `hscrol >> 1` is right for
     * the grid and throws the odd clock away here.  Losing it makes odd HSCROL
     * values indistinguishable from the even one below, which is why
     * antic_pfstarttiming's stride quantised in steps of four where the test
     * resolves single units. */
    int start = 2 * (antic_pf_nominal(w, 0) + PF_DISPLAY_LEAD)
              - (HSCROL_CC_DISPLAY ? hscrol_of(a) : 2 * (hscrol_of(a) >> 1));
    int span  = (w == ANTIC_NARROW) ? 128 : (w == ANTIC_WIDE) ? 192 : 160;

    int off = cc - start;
    if (off < 0 || off >= span)
        return -1;

    if (mode <= 7) {                      /* character modes */
        /* 40 characters of 4 colour clocks in modes 2..5, 20 of 8 in 6..7. */
        int cw = (mode <= 5) ? 4 : 8;
        int ci = off / cw;
        if (ci >= a->lb_len || ci >= (int)sizeof a->glyphbuf)
            return -1;
        uint8_t name  = a->linebuf[ci];
        uint8_t glyph = a->glyphbuf[ci];
        int within = off % cw;

        if (mode <= 3) {                  /* hi-res text, two pixels per clock */
            /* CHACTL blank and inverse act on characters with bit 7 set, and
             * blank wins over inverse. */
            if (name & 0x80) {
                if      (a->chactl & 0x01) glyph = 0x00;
                else if (a->chactl & 0x02) glyph = (uint8_t)~glyph;
            }
            int p  = within * 2;
            int b0 = (glyph >> (7 - p)) & 1;
            int b1 = (glyph >> (6 - p)) & 1;
            *hires_lit = b0 | b1;
            return (b0 | b1) ? 2 : -1;
        }
        if (mode <= 5) {                  /* 4-colour text, bit 7 picks PF3 */
            int v = (glyph >> (6 - within * 2)) & 3;
            if (!v) return -1;
            if (v == 3) return (name & 0x80) ? 3 : 2;
            return v - 1;
        }
        /* modes 6,7: one bit per pixel, the character's top two bits pick the
         * playfield colour */
        return ((glyph >> (7 - within)) & 1) ? (name >> 6) : -1;
    }

    if (mode == 0x0F) {                   /* hi-res: TWO pixels per colour clock */
        int p  = off * 2;
        int i0 = (p >> 3) % (int)sizeof a->linebuf;
        int i1 = ((p + 1) >> 3) % (int)sizeof a->linebuf;
        int b0 = (a->linebuf[i0] >> (7 - (p & 7))) & 1;
        int b1 = (a->linebuf[i1] >> (7 - ((p + 1) & 7))) & 1;
        *hires_lit = b0 | b1;
        return (b0 | b1) ? 2 : -1;        /* GTIA is shown hi-res as PF2 */
    }

    int px     = off / pf_ccpp[mode];
    int bits   = pf_bpp[mode];
    int bitpos = px * bits;
    uint8_t byte = a->linebuf[(bitpos >> 3) % (int)sizeof a->linebuf];

    if (bits == 1)
        return ((byte >> (7 - (bitpos & 7))) & 1) ? 0 : -1;   /* 2-colour: PF0 */

    int v = (byte >> (6 - (bitpos & 7))) & 3;
    return v ? v - 1 : -1;                /* 01->PF0, 10->PF1, 11->PF2 */
}

/* The RAW two-bit pixel pair at colour clock `cc` of an ANTIC mode F line, or
 * -1 outside the playfield window.  Mode F is hi-res — two pixels per colour
 * clock — and GTIA normally reduces that pair to "lit or not".  Pseudo mode E
 * does not: it decodes the pair as a playfield INDEX, which is why the same
 * data gives four colour classes instead of one.  See system.c. */
int antic_pf_pair(const antic *a, int cc)
{
    if (!(a->dmactl & 0x20) || (a->dl_insn & 0x0F) != 0x0F)
        return -1;
    antic_width w = width_of(a->dmactl);
    /* HSCROL moves the DISPLAY a full colour clock per unit, but the FETCH grid
     * only half a machine cycle — antic_pf_nominal's `hscrol >> 1` is right for
     * the grid and throws the odd clock away here.  Losing it makes odd HSCROL
     * values indistinguishable from the even one below, which is why
     * antic_pfstarttiming's stride quantised in steps of four where the test
     * resolves single units. */
    int start = 2 * (antic_pf_nominal(w, 0) + PF_DISPLAY_LEAD)
              - (HSCROL_CC_DISPLAY ? hscrol_of(a) : 2 * (hscrol_of(a) >> 1));
    int span  = (w == ANTIC_NARROW) ? 128 : (w == ANTIC_WIDE) ? 192 : 160;

    int off = cc - start;
    if (off < 0 || off >= span)
        return -1;
    int p  = off * 2;
    int i0 = (p >> 3) % (int)sizeof a->linebuf;
    int i1 = ((p + 1) >> 3) % (int)sizeof a->linebuf;
    int b0 = (a->linebuf[i0] >> (7 - (p & 7))) & 1;
    int b1 = (a->linebuf[i1] >> (7 - ((p + 1) & 7))) & 1;
    return (b0 << 1) | b1;
}

int antic_pf_nibble(const antic *a, int cc, int shift)
{
    if (!(a->dmactl & 0x20) || (a->dl_insn & 0x0F) != 0x0F)
        return -1;
    antic_width w = width_of(a->dmactl);
    /* HSCROL moves the DISPLAY a full colour clock per unit, but the FETCH grid
     * only half a machine cycle — antic_pf_nominal's `hscrol >> 1` is right for
     * the grid and throws the odd clock away here.  Losing it makes odd HSCROL
     * values indistinguishable from the even one below, which is why
     * antic_pfstarttiming's stride quantised in steps of four where the test
     * resolves single units. */
    int start = 2 * (antic_pf_nominal(w, 0) + PF_DISPLAY_LEAD)
              - (HSCROL_CC_DISPLAY ? hscrol_of(a) : 2 * (hscrol_of(a) >> 1));
    int span  = (w == ANTIC_NARROW) ? 128 : (w == ANTIC_WIDE) ? 192 : 160;

    int off = cc - start - shift;
    if (off < 0 || off >= span)
        return -1;
    int nib = off / 2;                    /* two colour clocks per nibble */
    int i   = nib / 2;
    if (i >= a->lb_len || i >= (int)sizeof a->linebuf)
        return -1;
    return (nib & 1) ? (a->linebuf[i] & 0x0F) : (a->linebuf[i] >> 4);
}

uint8_t antic_read(antic *a, uint16_t addr)
{
    switch (addr & 0x0F) {          /* ANTIC decodes 4 bits; $D400-$D40F
                                     * mirrors across the page (antic_addrmirror) */
    case 0x0B: return (uint8_t)a->vcount;         /* VCOUNT */
    case 0x0F: return a->nmist;                   /* NMIST  */
    default:   return 0xFF;                       /* antic_default: unused
                                                   * ANTIC reads are $FF, unlike
                                                   * GTIA's $0F */
    }
}

void antic_write(antic *a, uint16_t addr, uint8_t val)
{
    switch (addr & 0x0F) {
    case 0x00: {
        int old_nom = pf_window(a);           /* the window BEFORE the write */
        int old_span = pf_span(a);
        a->dmactl = val;
        rebuild_line(a, old_nom, old_span, PF_COMMIT_LEAD);
        break;
    }
    case 0x01: a->chactl = val; break;
    /* DLISTL/H IS the display-list counter, not a latch that seeds one: ANTIC
     * increments it in place as it fetches, so a write sets where the list
     * resumes from and there is nothing to reload it from later. */
    case 0x02: a->dl_addr = (uint16_t)((a->dl_addr & 0xFF00) | val); break;
    case 0x03: a->dl_addr = (uint16_t)((a->dl_addr & 0x00FF) | (val << 8)); break;
    case 0x04: {
        int old_nom = pf_window(a);
        int old_span = pf_span(a);
        a->hscrol = val;
        /* HSCROL moves the playfield's left edge by ONE COLOUR CLOCK per unit —
         * the window start is `nominal - hscrol/2` machine cycles, so the edge
         * in colour clocks is `2*nominal - hscrol + 2*lead`.  A mid-line write
         * therefore cannot be all-or-nothing: antic_pfstarttiming writes the
         * same $08 one machine cycle apart and gets edges ONE COLOUR CLOCK
         * apart, which no commit/don't-commit test can express (its DMACTL pair,
         * measured with the same probe, moves TWO clocks for the same one-cycle
         * delay, because a machine cycle is two of them).
         *
         * The beam takes the scroll away a unit at a time: whatever the write
         * asks for, only HSCROL_REACH - cycle units of it are still claimable. */
        int reach = HSCROL_REACH - a->cycle;
        int want  = val & 0x0F;
        a->hscrol_line = (uint8_t)(!HSCROL_CLAMP ? want
                                 : want < reach ? want : (reach < 0 ? 0 : reach));
        /* HSCROL commits its own start EARLIER than DMACTL does.  The fetch
         * count is what antic_pfstarttiming calls the stride, and it changes by
         * exactly one when the write crosses this boundary — so the boundary is
         * what its early/late pair straddles, and DMACTL's own pair (which
         * passes) says the two registers cannot share it. */
        rebuild_line(a, old_nom, old_span, HSCROL_COMMIT_LEAD);
        break;
    }
    case 0x05: a->vscrol = val; break;
    case 0x07: a->pmbase = val; break;
    case 0x09: a->chbase = val; break;
    case 0x0A:
        /* WSYNC.  Arms on the FIRST write — an RMW writes it twice and the
         * halt must not re-arm on the second (antic_wsync, d5). */
        if (!a->wsync_halt) a->wsync_halt = 1;
        else if (!WSYNC_RMW_ADJACENT || a->wsync_wr_at + 1 == a->ticks)
            a->wsync_extra = WSYNC_RMW_EXTRA;
        a->wsync_wr_at = a->ticks;
        break;
    case 0x0E:
        a->nmien = val;
        /* A NMIEN write landing in the SAME cycle as the status set DOES take
         * effect — the mirror of the NMIRES rule below.  antic_nmist requires a
         * write on cycle 6 to activate the DLI that was latched on that cycle. */
        /* A NMIEN write in the SAME cycle as the status set still delivers, but
         * one cycle later than the status path — see the countdown above. */
        if (a->nmist_set_now && (a->nmist & val & (ANTIC_NMI_DLI | ANTIC_NMI_VBI))
            && !a->nmi_arm)
            a->nmi_arm = 2;
        break;
    case 0x0F:
        /* NMIRES clears the STATUS but must not retract an interrupt already
         * raised — "VBI was blocked by NMIRES" is a failure (antic_nmist).
         *
         * It also LOSES to a status set landing in the same cycle: the same
         * test strikes NMIRES on cycle 6, where the VBI bit is set, and
         * requires the bit to still read as set; a strike on cycle 7 clears it
         * normally. */
        if (!a->nmist_set_now)
            a->nmist = 0;
        break;
    default: break;
    }
}
