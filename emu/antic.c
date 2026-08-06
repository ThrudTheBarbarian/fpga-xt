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
/* Whether a wide row's last playfield slot is VIRTUAL — see line_start. */
#ifndef VIRT_DMA
#define VIRT_DMA 1
#endif

/* Latch the playfield window's edges independently as the line passes them,
 * the way ANTIC does, instead of pinning the whole window at one commit point. */
#ifndef PF_LATCH_EDGES
#define PF_LATCH_EDGES 1
#endif

/* Derive the DISPLAY window from its own geometry rather than from the fetch
 * window's nominal. */
#ifndef LB_ORIGIN_DISPLAY
#define LB_ORIGIN_DISPLAY 0
#endif

#ifndef PF_DISPLAY_SPEC
#define PF_DISPLAY_SPEC 0
#endif

/* Which way HSCROL moves the PICTURE.  The fetch window is delayed by it, so
 * the byte that lands at the left of the display was read later -- and
 * antic_hscrolbug's two unstopped cases pin the answer from the same setup at
 * two HSCROL values: it restores 0 and wants its marker byte at $78, then
 * restores 2 and wants the same byte at $7a.  Two colour clocks LATER for
 * HSCROL=2, so the term is added. */
#ifndef HSCROL_DISPLAY_SIGN
#define HSCROL_DISPLAY_SIGN (+1)
#endif

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
/* An RMW write to WSYNC (INC WSYNC writes twice) pushes the release out by one,
 * so the CPU resumes at 105 rather than ANTIC_CYC_WSYNC's 104.
 *
 * MEASURED AGAINST gtia_pmresize AND IT IS A REAL TRADE, not a free fix.  That
 * test opens each pass with `inc wsync` and annotates its own cycles, and with
 * this at 0 our whole store sequence matches those annotations EXACTLY -- HITCLR
 * 107, HPOSP0 111, SIZEP0 1, the resize 46 -- which lands the resize at colour
 * clock $62, where tools/pmresize-check.py pins it.  With SIZEP_DELAY=1 as well,
 * gtia_pmresize gets through FIVE of its seven transitions and runs 32057 ->
 * 73895 cycles before failing in 2x-to-1xalt.
 *
 * And it costs FIVE TESTS: 48 pass against 53, with antic_wsync the direct
 * victim.  antic_wsync is anchored ON the release, so moving the release moves
 * what it measures -- exactly the compensation shape where a provably-wrong
 * constant cannot simply be corrected.  Left at 1 until the pair can be
 * satisfied together; the numbers are here so this is not re-run blind.
 *
 * AND THE PAIR CANNOT BE SATISFIED BY MOVING pmresize's MODEL EITHER, which was
 * the remaining hope.  With a release of 105 its SIZEP store lands at colour
 * clock $64 instead of $62, and no positive SIZEP_DELAY reaches backwards:
 * tools/pmresize-check.py scores carry_lock 112/112 at $62 and 54/28/19/14 at
 * $63/$64/$65/$66.  So gtia_pmresize REQUIRES 104 and antic_wsync's RANDOM
 * assertion REQUIRES 105, both after `inc wsync`, and neither can bend.
 *
 * The only structural difference found: antic_wsync's INC STRADDLES the line
 * boundary -- annotated 111, 112, 113, 0, 1, 2, so its writes land on cycles 1
 * and 2 of the NEXT line -- while gtia_pmresize's sits mid-line.  Test that
 * first if this is picked up again. */
#ifndef DMA_SPARES_WRITE
#define DMA_SPARES_WRITE 0
#endif

#ifndef WSYNC_RMW_EXTRA
#define WSYNC_RMW_EXTRA 1
#endif
/* Whether a READ of WSYNC arms the halt — see antic_read. */
/* Whether a mid-line rebuild keeps the RUNNING fetch phase (see rebuild_line)
 * or re-derives it from the new window's nominal. */
#ifndef PF_KEEP_PHASE
#define PF_KEEP_PHASE 1
#endif

/* Whether the display honours the line buffer's read origin (see antic.h). */
#ifndef LB_READ_ORIGIN
#define LB_READ_ORIGIN 1
#endif

#ifndef WSYNC_READ_ARMS
#define WSYNC_READ_ARMS 0
#endif
/* ...and whether that only applies when the two writes are ADJACENT.  An RMW's
 * writes are on consecutive CPU cycles, but a DMA cycle can fall between them:
 * antic_wsync's INC lands its pair at scanline cycles 1 and 2, gtia_pmresize's
 * at 32 and 34 with a memory refresh at 33.  That is the only structural
 * difference between the two, and they want different releases. */
/* ...but ONLY when the RMW's two writes are ADJACENT cycles.
 *
 * antic_wsync pins the extra and pmresize pins its absence, and both are `inc
 * wsync`, so for a while they looked like a straight contradiction.  They are
 * not: antic_wsync annotates its own cycles and the two forms differ inside ONE
 * test, in one DMA environment --
 *     sta wsync ... lda random   ;*, 105, 106, 107   -> released 104, 104 stolen
 *     inc wsync ... lda random   ;105, 106, 107, 108 -> released 105
 * -- so the second write really does re-arm.  Its INC writes on cycles 1 and 2,
 * back to back.  gtia_pmresize's INC has a refresh slot BETWEEN its two writes
 * (probed: they land two cycles apart), and there the release is 104, which is
 * what its `sta hitclr ;104,105,106,107` annotation requires.
 *
 * So the re-arm needs the second write to follow the first immediately.  With
 * this at 1 both tests hold: antic_wsync passes and pmresize's release moves to
 * 104, its first case going green.  53 pass either way -- no regression, and the
 * release is now right where two independent tests say it should be. */
#ifndef WSYNC_RMW_ADJACENT
#define WSYNC_RMW_ADJACENT 1
#endif
/* ...and in WHOSE frame "adjacent" is judged.  In CPU ACCESSES the two writes
 * of an RMW are always consecutive, so WSYNC_RMW_ADJACENT is a no-op there and
 * both tests get the extra.  ANTIC's OWN cycles do separate them --
 *     antic_wsync   sl 253 cyc 2,3   and  sl 260 cyc 104,105  -- adjacent
 *     gtia_pmresize sl  16 cyc 33,35 -- a refresh slot BETWEEN them
 * -- but DISPROVED as the discriminator, and by pmresize itself: the SAME `inc
 * wsync` at $233B lands (33,35) on one iteration and (31,32) on the next, purely
 * from where the previous iteration left the CPU, while runtest's annotation
 * wants 104 on EVERY iteration.  Kept at 0; scores 56/63 either way, and
 * pmresize fails at 4x-to-1x under both.
 *
 * What DOES move pmresize is dropping the extra outright: WSYNC_RMW_EXTRA=0
 * carries it from its FIRST section to 2x-to-1xalt, 32k cycles to 74k.  So the
 * release of 104 that runtest annotates is right for pmresize and the several
 * sections in between were failing on it.  It costs antic_wsync's d2, which is
 * an ASSERTION on RANDOM and outranks an annotation -- so the two want different
 * releases from the same instruction and the discriminator is still open.  Both
 * tests run with the screen off, so it is not DMA; the one structural difference
 * left is that antic_wsync's INC straddles the line boundary (opcode fetch at
 * 111-113, read and both writes at 0,1,2) while pmresize's sits mid-line. */
#ifndef WSYNC_RMW_ADJ_CYCLE
#define WSYNC_RMW_ADJ_CYCLE 0
#endif

/* WHERE IN THE LINE the RMW's second write lands.  Only ONE of the three cases
 * that bracket this needs the extra, and it is the one whose RMW straddles the
 * line boundary:
 *
 *   antic_wsync $2033  `inc wsync ;111,112,113,0,1,2`  writes at 1 and 2
 *       -> `lda random ;105,106,107,108`, d2 = $0D.  NEEDS the extra.
 *   antic_wsync $206D  `inc wsync ;99-104`             writes at 103 and 104
 *       -> d5 = $34.  INSENSITIVE -- measured $34 with the extra and without,
 *          so it constrains nothing (its second write lands ON the release).
 *   gtia_pmresize $233B                                writes at 30-55
 *       -> `sta hitclr ;104,105,106,107`.  Must NOT take the extra.
 *
 * So the discriminator is the line boundary, not adjacency and not DMA.  Held
 * as a cycle threshold because that is what is measured; the mechanism behind
 * it is NOT established -- a write this soon after the previous line's release
 * behaving differently is a plausible story and no more than that.
 *
 * Swept 2..31 against those three: it fails at 2 and holds from 3 upward, and
 * at 3 BOTH antic_wsync and pmresize's release are right for the first time.
 *
 * DISPROVED ANYWAY, by the rest of the suite: 51/63, costing antic_dlitiming,
 * antic_dmapattern, gtia_phantomdma, gtia_psuedomodee and pokey_noise.  They
 * need the extra for an `inc wsync` at the OTHER end of the line -- the
 * profileDelay ladder in antic_dmapattern ($2347 on) is `sta wsync` then `inc
 * wsync`, writing around 109-110.  So the extra is wanted at cycles 1-2 AND at
 * 109-110 and unwanted at 30-55, which no threshold expresses: position in the
 * line is the wrong variable.  Kept at 0.
 *
 * That lead is CLOSED: measured with ACID_COLPROBE=1 (the probe prints the CPU
 * PC), every extra antic_dmapattern takes comes from ONE instruction, the `inc
 * wsync` at $2359, and consecutive `sta wsync` writes never reach this branch
 * at all -- the halt is already released by the time the second one lands.
 *
 * ALTIRRA SAYS BOTH ANNOTATIONS ARE RIGHT.  tools/altirra-wsync.py drives the
 * bridge and reads Altirra's cycle-accurate history; calibrated against the
 * beam and against the WSYNC-resume anchor (a halted instruction's post-fetch
 * cycles resume at line 105):
 *
 *   antic_wsync $2033   inc at line 111, writes at 1 and 2  -> next instruction
 *                       starts at line 105.  The extra is REAL.
 *   gtia_pmresize $233B inc at line 26, writes at 30 and 31 -> next instruction
 *                       starts at line 104.  No extra.
 *
 * So this is not a modelling error to be argued away -- the hardware really
 * does both, and the annotations in the two tests are each correct.
 *
 * antic_dmapattern's $2359 is now traced on Altirra too, and it CONFIRMS the
 * one structural difference.  Calibrated inside its own run (offset +22, cross-
 * checked against three independent instructions), profileDelay1 runs:
 *
 *   $2347 sta wsync   line  20, not halted, writes at 23 -> arms
 *   $234A ldx random  line  24, HALTED at its fetch, resumes 105/106/107
 *   $234D sta wsync   line 108, not halted, writes at 111 -> arms
 *   $2350 ldy random  line 112, HALTED, resumes 105/106/107
 *   $2353 sta wsync   line 108, writes at 111 -> arms
 *   $2356 sta wsync   line 112, HALTED, resumes 105/106/107, writes at 107 --
 *                     AFTER the release, so this one arms a FRESH halt
 *   $2359 inc wsync   line 108, HALTED AT ITS OWN FETCH
 *
 * That is the difference: antic_wsync's inc ran unhalted from line 111, and
 * pmresize's ran unhalted from line 26.  Only dmapattern's is itself waiting on
 * /RDY when it starts.  So the candidate rule is "an RMW that came out of a
 * WSYNC release re-arms; one that did not, does not" -- a mechanism rather than
 * a position in the line, and the first predicate here that is not curve-fitted.
 *
 * NOT YET PROVEN, and the gap is worth stating precisely: $235C is recorded 225
 * cycles after $2359.  111 (halt to line 105) + 5 (the inc's remaining cycles)
 * + 109 (a second halt, released at 105) accounts for it EXACTLY, which reads as
 * the extra -- but only if Altirra timestamps a halted instruction at its
 * RESUMED cycle, whereas $234A above is plainly timestamped at its ATTEMPTED
 * fetch.  One of those two readings is wrong.  Settle it by tracing an
 * instruction that is definitely NOT halted immediately after the jmp lands. */
#ifndef WSYNC_RMW_EARLY
#define WSYNC_RMW_EARLY 0
#endif

/* HOW FAR THE RMW SITS FROM THE LAST WSYNC RELEASE, in CPU accesses.  Altirra
 * says the three cases differ in exactly this: dmapattern's $2359 is HALTED at
 * its own fetch (distance 0), antic_wsync's $2033 is two instructions past a
 * release, and pmresize's $233B is a long way past one.  The first two take the
 * extra and the third does not, so unlike every position-in-the-line rule this
 * is at least measuring the machine's state.
 *
 * MEASURED DISTANCES (ACID_COLPROBE=1 prints `since`), count x distance, for
 * every test that reaches this branch at all:
 *
 *   antic_wsync        1x12                      NEEDS
 *   antic_dmapattern  50x5                       NEEDS
 *   gtia_phantomdma    1x20   1x4744             NEEDS BOTH
 *   pokey_noise        2x9    1x13   1x22        NEEDS
 *   gtia_psuedomodee   4x5    1x14   1x30  1x31  NEEDS (plus insensitive ones)
 *   antic_dlitiming    7x5    then 96/97/98/119  NEEDS only the 5s; the rest are
 *                                                insensitive (it passes at 14)
 *   gtia_pmresize      1x56   1x3086             MUST NOT TAKE EITHER
 *
 * Scored: SINCE=14 gives 54/63 (loses gtia_phantomdma and pokey_noise);
 * SINCE=40 gives 55/63, losing only gtia_phantomdma.  DISPROVED as a plain
 * threshold, and by one pair: phantomdma needs the extra at 4744 while pmresize
 * must be denied it at 3086.  Nothing monotonic in this variable separates
 * those, so distance-since-release is closer than position in the line but is
 * still not the discriminator on its own.  Default 0.
 *
 * What the table does say, and it is worth keeping: every case that NEEDS the
 * extra at a short distance is short (5..31), pmresize's shortest is 56, and the
 * only overlap is phantomdma's single long one.  Whatever the real rule is, it
 * has to explain that one entry. */
#ifndef WSYNC_RMW_SINCE
#define WSYNC_RMW_SINCE 0
#endif

/* THE REFRESH WINDOW.  Tabulating the whole population by LINE CYCLE (real, not
 * the probe's +1) separates it exactly, and along a boundary the hardware
 * already has:
 *
 *   NEEDS the extra:  2 (antic_wsync), 0/3/12 (pokey_noise), 12 (phantomdma),
 *                     5/21/68/110 (psuedomodee), 6/7/96/97 (dlitiming),
 *                     109 (dmapattern)
 *   MUST NOT:         34 and 55 (gtia_pmresize)
 *
 * Every case that needs it is OUTSIDE cycles 25..57; both that forbid it are
 * INSIDE.  That range is not fitted -- it is ANTIC's memory-refresh window,
 * REFRESH_FIRST 25 through REFRESH_FIRST + 8*REFRESH_STEP = 57, already in
 * antic_dma.c and already pinned by `make dma` at 50/50.
 *
 * The reading: an RMW whose second write lands in the refresh window does not
 * re-arm, because that write is contending with a refresh cycle for the bus.
 * MARKED AS AN INFERENCE -- the separation is measured, the causal story is not.
 * Also resolves the direct clash between two annotations by the same author:
 * gtia_phantomdma $208F/$209C both write `inc wsync ... sta hitclr ;105,106,
 * 107,108` (the extra) at cycle 12, while gtia_pmresize $233B writes the same
 * instruction pair `;104,105,106,107` (no extra) at cycles 34 and 55.
 *
 * DEFAULT ON.  Full suite 56/63 with NO regressions, and gtia_pmresize carries
 * from its FIRST section (4x-to-1x, 32058 cycles) to 2x-to-1xalt at 73895 --
 * same score, strictly more correct behaviour, and what remains of pmresize is
 * now a GTIA question rather than a WSYNC one. */
#ifndef WSYNC_RMW_REFRESH
#define WSYNC_RMW_REFRESH 1
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
    a->pf_carry = -1;                     /* no stream running across the reset */
    a->pf_lat_start = a->pf_lat_vend = -1;
    a->pf_last_check = 0;
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

/* A row is SCROLLED when the display-list instruction says so, whatever HSCROL
 * happens to hold — a scrolled row at HSCROL=0 still runs the next width up.
 * The DMA map is told by carrying bit 4 through in the mode byte. */
static int scrolled_of(const antic *a)
{
    return (a->dl_insn & 0x10) != 0;
}

/* PLAYFIELD DMA is enabled by DMACTL's WIDTH bits (0-1), not by bit 5, which
 * is the DISPLAY LIST DMA enable.  Clearing bit 5 stops ANTIC fetching new
 * display-list INSTRUCTIONS -- the current one is reused -- but the playfield
 * keeps being fetched at the programmed width.  antic_hscrolbug's second test
 * is built on exactly that: it writes DMACTL = $01 mid-line "so that the $5e
 * byte is reused", and with the two conflated the row fetches nothing at all
 * and no collision registers anywhere.
 *
 * DMACTL = 0 turns both off, so the case the rest of the suite exercises is
 * unaffected. */
/* Whether a row whose instruction is REUSED (DL DMA off at its start) still
 * fetches its playfield. */
#ifndef DL_REUSE_KEEPS_PF
#define DL_REUSE_KEEPS_PF 1
#endif

#ifndef PF_DMA_WIDTH_GATE
#define PF_DMA_WIDTH_GATE 1
#endif

static int pf_dma_on(const antic *a)
{
    return PF_DMA_WIDTH_GATE ? (a->dmactl & 0x03) != 0
                             : (a->dmactl & 0x20) != 0;
}

static uint8_t dma_mode(const antic *a, int mode)
{
    /* bit 4 = horizontal scroll, bit 6 = LMS/jump (the operand fetches), and
     * bit 5 = display-list DMA is enabled at all (DMACTL bit 5) -- with it off
     * ANTIC re-uses the instruction it has and fetches nothing. */
    return (uint8_t)(mode | (a->dl_insn & 0x50) | (a->dmactl & 0x20));
}

/* Where the DISPLAY window opens, in colour clocks.
 *
 * A DIFFERENT QUANTITY from the fetch window, and deriving it from the fetch
 * nominal is what tied the two together.  It opens at machine cycle 32/24/22
 * for narrow/normal/wide -- and unlike the fetch window it is NOT stepped up
 * when the row is scrolled: a scrolled row fetches wider so it has something to
 * scroll in, but it shows the same rectangle.  Narrow and normal happened to
 * come out right from the old derivation; wide was four machine cycles early,
 * and antic_virtdma had absorbed that into the HSCROL term's sign. */
static int pf_display_start(const antic *a, antic_width w)
{
    if (PF_DISPLAY_SPEC) {
        int ds = (w == ANTIC_NARROW) ? 32 : (w == ANTIC_WIDE) ? 22 : 24;
        return 2 * ds + HSCROL_DISPLAY_SIGN
             * (HSCROL_CC_DISPLAY ? hscrol_of(a) : 2 * (hscrol_of(a) >> 1));
    }
    return 2 * (antic_pf_nominal_s(w, 0, scrolled_of(a)) + PF_DISPLAY_LEAD)
         + HSCROL_DISPLAY_SIGN
           * (HSCROL_CC_DISPLAY ? hscrol_of(a) : 2 * (hscrol_of(a) >> 1));
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
    /* The PREVIOUS line's map, as the hardware finished it -- after every
     * mid-line rebuild, not as it was first built.  Diffing the line_start map
     * against a reference compares two different things. */
    /* Window widened from 31..40: the END map is the reference the RTL is
     * diffed against, and a fixed window silently excludes the very row a
     * test is about (antic_vscroldli's $F0 row starts at scanline 40). */
    if (antic_glyph_probe == 9 && a->scanline >= 28 && a->scanline <= 52) {
        fprintf(stderr, "  END sl %3d insn $%02X clk $%02X org %2u len %2u next %3d ", a->scanline - 1, a->dl_insn, a->pf_clock, a->lb_origin, a->lb_len, a->pf_next);
        for (int k = 0; k < ANTIC_LINE_CYCLES; k++)
            fputc(a->blocked[k] ? '#' : '.', stderr);
        fputc('\n', stderr);
        /* ...and what actually LANDED in the buffer.  The map, lb_origin and
         * the read index can all agree with an RTL port while the CONTENTS
         * differ, and until this print existed the only reference for the
         * contents was a prose comment in the test -- which on this very test
         * describes a compiled-out branch.  Forty-eight entries is the whole
         * of a wide row plus room for a run-on. */
        fprintf(stderr, "  LBUF sl %3d insn $%02X org %2u:", a->scanline - 1,
                a->dl_insn, a->lb_origin);
        for (int k = 0; k < 48; k++)
            fprintf(stderr, " %02x", a->linebuf[k]);
        fputc('\n', stderr);
        /* ...and the SOURCE the display actually paints, per colour clock.
         * The buffer being right does not make the picture right: the display
         * window sits PF_DISPLAY_LEAD cycles after the nominal one, and an RTL
         * port that conflates the two paints every pixel in the wrong place
         * while every fetch-side comparison still agrees.  -1 is background. */
        fprintf(stderr, "  PFSRC sl %3d insn $%02X:", a->scanline - 1, a->dl_insn);
        for (int cc = 0; cc < 228; cc++) {
            int hl = 0, src = antic_pf_at(a, cc, &hl);
            fprintf(stderr, "%c", src < 0 ? '.' : (char)('0' + src));
        }
        fputc('\n', stderr);
    }

    a->hscrol_line = a->hscrol;           /* the clamp is per-line */
    a->virt_cyc = -1;                     /* no virtual slot unless one is built */
    a->virt_idx = 0;
    memset(a->blocked, 0, sizeof a->blocked);
    memset(a->pf_at, -1, sizeof a->pf_at);
    a->pf_next = 0;
    a->lb_origin = 0;
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
        if (a->scanline < ANTIC_DISPLAY_TOP || a->scanline >= ANTIC_DISPLAY_BOTTOM)
            return;
        if (a->dmactl & 0x20)
            antic_dl_exec(a);
        /* With DL DMA off there is no new instruction, so the CURRENT one is
         * REUSED and the row runs again — the playfield goes on being fetched
         * from it.  Returning here skipped the playfield build below along with
         * the instruction fetch, and the two are independent (the same
         * distinction as pf_dma_on's).  antic_hscrolbug's second test arranges
         * exactly this, writing DMACTL = $01 mid-line "so that the $5e byte is
         * reused"; with the return in place its row fetched nothing at all and
         * no collision registered anywhere. */
        else if (!DL_REUSE_KEEPS_PF)
            return;
    }

    /* The DLI belongs to the LAST scanline of the row — including a BLANK-LINE
     * row, which is the case antic_dlitiming is built out of and the fabric
     * dl_parser gets wrong. */
    /* the DLI's own row-end compare is made live at NMIST time, not here — see
     * antic_tick */

    int mode = a->dl_insn & 0x0F;
    /* A stream whose stop was never matched on the PREVIOUS scanline is still
     * running when this one starts, and takes its next fetch on the carried
     * phase — cycle 0 in antic_hscrolbug's case.  Consumed here, so a line that
     * fetches nothing drops it. */
    int carry_in = a->pf_carry;
    a->pf_carry = -1;
    /* Both window edges are live again at the top of every scanline.  The DMA
     * CLOCK is not: whatever was still flying round it when the last line ended
     * is still flying now, which is how abnormal DMA crosses the line boundary
     * (antic_hscrolbug's next line starts fetching at cycle 0). */
    a->pf_lat_start = a->pf_lat_vend = -1;
    a->pf_last_check = 0;
    a->pf_clock_in = a->pf_clock;
    if (mode >= 2 && pf_dma_on(a)) {
        if (PF_LATCH_EDGES) {
            int s0 = 0, e0 = 0;
            uint8_t ck = a->pf_clock_in;
            antic_pf_window(dma_mode(a, mode), width_of(a->dmactl),
                            hscrol_of(a), &s0, &e0);
            antic_dma_line_edges(dma_mode(a, mode), a->row_first, s0, e0,
                                 a->blocked, a->pf_at, &ck);
            a->pf_clock = ck;
            if (antic_glyph_probe == 9 && a->scanline >= 30 && a->scanline <= 34) {
                fprintf(stderr, "  CLK sl %3d win %3d..%3d in $%02X out $%02X\n  MAP ",
                        a->scanline, s0, e0, a->pf_clock_in, ck);
                for (int k = 0; k < ANTIC_LINE_CYCLES; k++)
                    fputc(a->blocked[k] ? '#' : '.', stderr);
                fputc('\n', stderr);
            }
        } else
        antic_dma_line_map_carry(dma_mode(a, mode), width_of(a->dmactl),
                                 a->row_first, hscrol_of(a), carry_in,
                                 a->blocked, a->pf_at, &a->pf_carry);

        /* Bytes fetched before the display window opens are NOT displayed —
         * they push the write pointer ahead of the read pointer.  On a normal
         * line there are none; on one whose stream ran on from the previous
         * scanline there are as many as the run-on produced, and the display
         * has to skip them.  That is antic_hscrolbug's "shifted left by 17
         * bytes": the bytes go into the buffer, the window shows the ones
         * after them. */
        /* From the SAME window the schedule was built from -- deriving it a
         * second time here is how the two came to disagree. */
        int wstart = antic_pf_start(dma_mode(a, mode), width_of(a->dmactl),
                                    a->row_first, hscrol_of(a));
        /* ...measured against the DISPLAY window, not the fetch one.  A
         * scrolled row fetches from a wider window than it shows, so bytes are
         * consumed before the picture opens even with no abnormal DMA at all --
         * six of them on a scrolled narrow row, which is exactly the "line
         * buffer advanced by six additional locations" antic_hscrolbug states. */
        if (LB_ORIGIN_DISPLAY)
            wstart = pf_display_start(a, width_of(a->dmactl)) / 2 - PF_DISPLAY_LEAD;
        int skipped = 0;
        for (int c = 0; c < wstart && c < ANTIC_LINE_CYCLES; c++)
            if (a->pf_at[c] >= 0) skipped++;
        a->lb_origin = (uint8_t)skipped;

        /* The LAST playfield slot of a scrolled row is VIRTUAL.  antic_virtdma
         * documents the pattern for mode 7 wide with HSCROL 2 and marks its
         * final slot `V` where the real fetches are `C`: ANTIC accounts for it
         * and clocks the line buffer, but drives neither address nor data — so
         * it does NOT steal the cycle (the test's own trace shows the CPU
         * keeping 104, 105 and 106) and what the buffer takes is whatever the
         * CPU's access left on the bus.  That is the same rule as the phantom
         * P/M latch's, one slot further on. */
        /* WIDE only.  antic_dmapattern tabulates narrow and normal and says
         * their last playfield cycle IS blocked, so un-blocking one everywhere
         * costs that test and antic_linebuffering.  The virtual slot exists
         * because a wide scrolled row asks for one more byte than the row has
         * — the geometry antic_virtdma runs. */
        if (VIRT_DMA && width_of(a->dmactl) == ANTIC_WIDE) {
            int vi = -1;
            int vc = antic_pf_last(dma_mode(a, mode), width_of(a->dmactl),
                                   a->row_first, hscrol_of(a), &vi);
            if (vc >= 0 && vi >= 0) { a->virt_cyc = vc; a->virt_idx = (uint8_t)vi; }
            if (antic_glyph_probe == 8)
                fprintf(stderr, "  VIRT sl %3d insn $%02X w %d hs %d -> cyc %d idx %d\n",
                        a->scanline, a->dl_insn, width_of(a->dmactl),
                        hscrol_of(a), a->virt_cyc, a->virt_idx);
            /* A row's LATER lines have no name fetches at all — the map's `b`
             * variant is glyph slots only — so the virtual slot has to be found
             * from those instead.  Refresh is long finished by then, so the
             * last blocked cycle of the line IS the last glyph slot.  This is
             * the case antic_virtdma actually measures: its display list is
             * `$57`, a sixteen-line mode 7 row, and it reads scanlines 33..37. */
            if (a->virt_cyc < 0)
                for (int c = ANTIC_LINE_CYCLES - 1; c >= 0; c--)
                    if (a->blocked[c]) {
                        a->virt_cyc = c;
                        a->virt_idx = (uint8_t)(a->lb_len ? a->lb_len - 1 : 0);
                        break;
                    }
            if (a->virt_cyc >= 0) a->blocked[a->virt_cyc] = 0;
        }

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
    return antic_pf_nominal_s(width_of(a->dmactl), hscrol_of(a), scrolled_of(a));
}

static int pf_span(const antic *a)
{
    switch (width_of(a->dmactl)) {
    case ANTIC_NARROW: return 64;
    case ANTIC_WIDE:   return 96;
    default:           return 80;
    }
}

/* Freeze any window edge the line has already gone past.
 *
 * Re-implemented from Altirra's LatchPlayfieldEdges.  Each edge is a comparison
 * against the horizontal counter, and once that comparison has been made it
 * cannot be un-made -- so a mid-line DMACTL or HSCROL write moves only the
 * edges still ahead of the beam, and a row can end up running the OLD start
 * against the NEW stop.  Its byte count then belongs to neither width, which is
 * what antic_pfstarttiming and antic_pfstoptiming measure from opposite sides.
 *
 * The test is a RANGE over the cycles elapsed since the last check, not a test
 * against the current cycle: several cycles can pass between two writes and the
 * edge in between must still be caught.  The decision sits one cycle before the
 * window for the character modes and three before it for the bitmap ones --
 * which is the SAME absolute cycle for both, since their starts differ by two
 * (26-1 == 28-3 == 25 on a narrow line).
 *
 * Called BEFORE the register takes its new value, because the edge that latches
 * is the one the line has been running. */
static void latch_edges(antic *a)
{
    if (!PF_LATCH_EDGES) return;
    int mode = a->dl_insn & 0x0F;
    if (mode < 2 || !pf_dma_on(a)) return;

    int s = 0, e = 0;
    antic_pf_window(dma_mode(a, mode), width_of(a->dmactl), hscrol_of(a), &s, &e);

    int off   = (mode < 8) ? 1 : 3;
    /* a->cycle is ALREADY ADVANCED past the cycle the CPU is executing --
     * antic_tick increments it before the access for the cycle it just ticked,
     * deliberately, so NMIST still stands when that access is made.  The window
     * constants are in ANTIC's own frame, so the comparison has to be too.
     *
     * One cycle, and it decides antic_pfstarttiming: its DLI writes DMACTL on
     * cycle 16 and a normal character row latches its start at 18 - 1 = 17.
     * Comparing the inflated 17 against 17 froze the old width and fetched two
     * bytes too many. */
    int x     = a->cycle - 1;
    int last  = a->pf_last_check;
    if (x >= last) {
        if ((s - off) >= last && (s - off) <= x) a->pf_lat_start = s;
        if ((e - off) >= last && (e - off) <= x) a->pf_lat_vend  = e;
    }
    a->pf_last_check = x;
}

/* The window this line is actually running: live where the beam has not reached
 * the edge yet, latched where it has. */
static void pf_edges(const antic *a, int *s, int *e)
{
    int mode = a->dl_insn & 0x0F;
    antic_pf_window(dma_mode(a, mode), width_of(a->dmactl), hscrol_of(a), s, e);
    if (PF_LATCH_EDGES) {
        if (a->pf_lat_start >= 0) *s = a->pf_lat_start;
        if (a->pf_lat_vend  >= 0) *e = a->pf_lat_vend;
    }
}

static void rebuild_line(antic *a, int old_nom, int old_span, int lead)
{
    if (PF_LATCH_EDGES) {
        int from = a->cycle;
        if (from < 0 || from >= ANTIC_LINE_CYCLES) return;
        int mode = a->dl_insn & 0x0F;
        int on   = mode >= 2 && pf_dma_on(a);
        (void)old_nom; (void)old_span; (void)lead;

        uint8_t blk[ANTIC_LINE_CYCLES];
        int8_t  map[ANTIC_LINE_CYCLES];
        int s = 0, e = 0;
        if (on) pf_edges(a, &s, &e);

        /* Playfield DMA runs at all only if the start is either already latched
         * or still ahead of the beam -- a width that opens behind the beam has
         * missed its own start and fetches nothing. */
        int commit = s - ((mode < 8) ? 2 : 4);
        if (commit < 10) commit = 10;
        if (on && a->pf_lat_start < 0 && from > commit) s = e = 0;

        /* A rebuild restarts from the clock this line BEGAN with, not from
         * whatever the previous build left, or the abnormal bits would be
         * injected twice. */
        uint8_t ck = a->pf_clock_in;
        antic_dma_line_edges(on ? dma_mode(a, mode) : 0, a->row_first, s, e,
                             blk, map, &ck);
        a->pf_clock = ck;

        int keep_map = !on || antic_pf_bytes(a->dmactl, (uint8_t)mode) == 0;
        for (int c = from; c < ANTIC_LINE_CYCLES; c++) {
            a->blocked[c] = blk[c];
            if (!keep_map) a->pf_at[c] = map[c];
        }
        return;
    }

    int from = a->cycle;                    /* the next cycle to run */
    if (from < 0 || from >= ANTIC_LINE_CYCLES) return;

    uint8_t blk[ANTIC_LINE_CYCLES];
    int8_t  map[ANTIC_LINE_CYCLES];
    int mode = a->dl_insn & 0x0F;
    int on   = mode >= 2 && pf_dma_on(a);

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

    /* A rebuild must NOT RE-PHASE a stream that is already running.  ANTIC's
     * playfield fetch clock free-runs; a register write moves the COMPARATOR,
     * not the phase.  Rebuilding from the new window's nominal instead flips the
     * grid's parity whenever HSCROL moves by an odd number of colour clocks, and
     * antic_hscrolbug catches it exactly: its first write (HSCROL 0 -> 2 at
     * cycle 78) already produced the test's own map — 47 fetches, last at 112 —
     * and its second (restoring HSCROL at 107) then shifted the grid by one and
     * carried into cycle 1 instead of 0.  So the running phase is handed back in
     * as carry_in: the next cycle at or after `from` that the CURRENT map
     * already fetches on.
     *
     * A rebuild can also leave the stream running past the end of the line —
     * that IS the mechanism — so the carry replaces whatever the line's original
     * build reported. */
    int phase = -1;
    if (PF_KEEP_PHASE)
        for (int c = from; c < ANTIC_LINE_CYCLES; c++)
            if (a->pf_at[c] >= 0) { phase = c; break; }

    antic_dma_line_map_at(on ? dma_mode(a, mode) : 0, width_of(a->dmactl),
                          a->row_first, hscrol_of(a), pin, phase, blk, map,
                          &a->pf_carry);

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
            a->linebuf[i] = (c == a->virt_cyc) ? a->bus_byte
                          : a->fetch ? a->fetch(a->ctx, a->pf_addr) : 0xFF;
            a->pf_addr = antic_pf_next(a->pf_addr);
            int m = a->dl_insn & 0x0F;
            /* On the virtual slot BOTH accesses are virtual, and it is the
             * GLYPH that is displayed: antic_virtdma's missiles sit over four
             * PIXELS of that character, which in mode 7 is four bits of its
             * glyph byte — the top four, giving the high nibble the test
             * asserts. */
            if (c == a->virt_cyc) {
                a->glyphbuf[i] = a->bus_byte;
                if (antic_glyph_probe == 7)
                    fprintf(stderr, "  VIRT sl %3d cyc %3d idx %2d <- $%02X\n",
                            a->scanline, c, i, a->bus_byte);
            }
            else if (m >= 2 && m <= 7 && a->fetch) fetch_glyph(a, m, i);
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
    /* ACID_GLYPHPROBE=8: the cycle /NMI is actually asserted, which is the one
     * thing the RTL comparison needs and no existing probe reports. */
    if (antic_glyph_probe == 8 && a->nmi)
        fprintf(stderr, "  NMIASSERT sl %3d cyc %3d\n", a->scanline, c);

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
            a->wsync_rel_acc = a->cpu_acc;
        } else if (!a->cpu_writing) {
            took = 1;
        }
    }

    /* EXPERIMENT (DMA_SPARES_WRITE): /RDY does not stop a WRITE cycle, so a DMA
     * slot cannot take one either -- which matters because an RMW's two writes
     * are consecutive on hardware and our steal was splitting them.  That split
     * is what makes gtia_pmresize's WSYNC release alternate 104/104/105/105
     * across its iterations, since the adjacency of `inc wsync`'s write pair
     * drifts with where the instruction falls in the line.
     *
     * DISPROVED, kept with its result.  Sparing EVERY blocked cycle breaks
     * antic_dmapattern, and narrowing it to REFRESH ONLY -- the slippable,
     * lowest-priority DMA, and the only kind present in gtia_pmresize, which
     * runs with the screen off -- breaks antic_dmapattern just the same.  So the
     * emulator's steal really can split an RMW's write pair and no version of
     * "DMA yields to a write" fixes it without costing the DMA pattern.
     * antic_wsync stays green throughout, so it is not the constraint here.
     *
     * The alternating release is REAL and MEASURED: pmresize's iterations
     * release at 104, 104, 105, 105, ... as the INC drifts through the line.
     * Whatever the right account is, it is not this one. */
    if (DMA_SPARES_WRITE && !a->refresh_known) {
        antic_dma_refresh(a->refresh_at);
        a->refresh_known = 1;
    }
    if (!took && c < ANTIC_LINE_CYCLES && a->blocked[c]
        && !(DMA_SPARES_WRITE && a->cpu_writing && a->refresh_at[c]))
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
/* Colour clocks per pixel, as a SHIFT rather than a divisor: the values are
 * { modes 8..15 } = 4,2,2,1,1,1,1,1, all powers of two. The A9 has NO integer
 * divide, so `off / pf_ccpp[mode]` with a runtime divisor compiled to an
 * __aeabi_idiv CALL -- twice per emulated cycle, on the hottest path in the
 * emulator. `off` is already proven non-negative by the window check above, so
 * the shift is exact. */
static const uint8_t pf_ccsh[16] = { 0,0,0,0,0,0,0,0, 2,1,1,0,0,0,0,0 };
static const uint8_t pf_bpp [16] = { 0,0,0,0,0,0,0,0, 2,1,2,1,1,2,2,1 };

/* The line buffer's read index: the display skips the bytes fetched before the
 * window opened (see antic.h's lb_origin). */
static int lb(const antic *a, int i)
{
    if (LB_READ_ORIGIN) i += a->lb_origin;
    return i % (int)sizeof a->linebuf;
}

int antic_pf_at(const antic *a, int cc, int *hires_lit)
{
    *hires_lit = 0;
    int mode = a->dl_insn & 0x0F;
    if (mode < 2 || !pf_dma_on(a))
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
    int start = pf_display_start(a, w);
    int span  = (w == ANTIC_NARROW) ? 128 : (w == ANTIC_WIDE) ? 192 : 160;

    int off = cc - start;
    if (off < 0 || off >= span)
        return -1;

    if (mode <= 7) {                      /* character modes */
        /* 40 characters of 4 colour clocks in modes 2..5, 20 of 8 in 6..7. */
        /* 4 or 8 -> shift 2 or 3; same reason as pf_ccsh above. */
        int csh = (mode <= 5) ? 2 : 3;
        int ci = off >> csh;
        if (ci >= a->lb_len || ci >= (int)sizeof a->glyphbuf)
            return -1;
        uint8_t name  = a->linebuf[lb(a, ci)];
        uint8_t glyph = a->glyphbuf[lb(a, ci)];
        int within = off & ((1 << csh) - 1);

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
        int i0 = lb(a, p >> 3);
        int i1 = lb(a, (p + 1) >> 3);
        int b0 = (a->linebuf[i0] >> (7 - (p & 7))) & 1;
        int b1 = (a->linebuf[i1] >> (7 - ((p + 1) & 7))) & 1;
        *hires_lit = b0 | b1;
        return (b0 | b1) ? 2 : -1;        /* GTIA is shown hi-res as PF2 */
    }

    int px     = off >> pf_ccsh[mode];
    int bits   = pf_bpp[mode];
    int bitpos = px * bits;
    uint8_t byte = a->linebuf[lb(a, bitpos >> 3)];

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
    if (!pf_dma_on(a) || (a->dl_insn & 0x0F) != 0x0F)
        return -1;
    antic_width w = width_of(a->dmactl);
    /* HSCROL moves the DISPLAY a full colour clock per unit, but the FETCH grid
     * only half a machine cycle — antic_pf_nominal's `hscrol >> 1` is right for
     * the grid and throws the odd clock away here.  Losing it makes odd HSCROL
     * values indistinguishable from the even one below, which is why
     * antic_pfstarttiming's stride quantised in steps of four where the test
     * resolves single units. */
    int start = pf_display_start(a, w);
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
    if (!pf_dma_on(a) || (a->dl_insn & 0x0F) != 0x0F)
        return -1;
    antic_width w = width_of(a->dmactl);
    /* HSCROL moves the DISPLAY a full colour clock per unit, but the FETCH grid
     * only half a machine cycle — antic_pf_nominal's `hscrol >> 1` is right for
     * the grid and throws the odd clock away here.  Losing it makes odd HSCROL
     * values indistinguishable from the even one below, which is why
     * antic_pfstarttiming's stride quantised in steps of four where the test
     * resolves single units. */
    int start = pf_display_start(a, w);
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
    case 0x0A:
        /* WSYNC is write-only, but a READ-MODIFY-WRITE reads it before it
         * writes it — `inc wsync` is read, write-old, write-new — and the two
         * tests that disagree about the release both use INC, so the read's
         * timing is the one thing that differs between them (cycle 0 for
         * antic_wsync, ~31 for gtia_pmresize).  WSYNC_READ_ARMS tests whether
         * the read arms the halt in its own right. */
        if (WSYNC_READ_ARMS && !a->wsync_halt) a->wsync_halt = 1;
        return 0xFF;
    case 0x0B: return (uint8_t)a->vcount;         /* VCOUNT */
    case 0x0F: return a->nmist;                   /* NMIST  */
    default:   return 0xFF;                       /* antic_default: unused
                                                   * ANTIC reads are $FF, unlike
                                                   * GTIA's $0F */
    }
}

/* The VIRTUAL slot's latch, called from the bus path rather than from the tick.
 * It has to see the byte from ITS OWN cycle, and the cycle is one the CPU gets
 * (the slot does not steal it) — so at tick time the access has not happened
 * yet and the bus still holds the previous cycle's byte.  Exactly the rule the
 * phantom P/M latch needed: run AFTER the access, not before it. */
void antic_virt_latch(antic *a, int cyc, uint8_t v)
{
    if (!VIRT_DMA || cyc != a->virt_cyc) return;
    a->glyphbuf[a->virt_idx] = v;
    if (antic_glyph_probe == 7)
        fprintf(stderr, "  VIRT sl %3d cyc %3d idx %2d <- $%02X\n",
                a->scanline, cyc, a->virt_idx, v);
}

void antic_write(antic *a, uint16_t addr, uint8_t val)
{
    switch (addr & 0x0F) {
    case 0x00: {
        if (antic_glyph_probe == 9 && a->scanline >= 32 && a->scanline <= 34)
            fprintf(stderr, "  DMACTL $%02X at sl %d cyc %d\n",
                    val, a->scanline, a->cycle);
        int old_nom = pf_window(a);           /* the window BEFORE the write */
        int old_span = pf_span(a);
        latch_edges(a);                       /* ...and freeze what it passed */
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
        latch_edges(a);
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
        else if (WSYNC_RMW_REFRESH
                     ? !antic_dma_in_refresh(a->cycle - 1)
               : WSYNC_RMW_SINCE
                     ? a->cpu_acc - a->wsync_rel_acc <= WSYNC_RMW_SINCE
               : WSYNC_RMW_EARLY  ? a->cycle <= WSYNC_RMW_EARLY
               : WSYNC_RMW_ADJ_CYCLE
                     ? (a->wsync_wr_sl == a->scanline
                        && a->wsync_wr_cyc + 1 == a->cycle)
                     : (!WSYNC_RMW_ADJACENT || a->wsync_wr_at + 1 == a->cpu_acc))
            a->wsync_extra = WSYNC_RMW_EXTRA;
        a->wsync_wr_at  = a->cpu_acc;
        a->wsync_wr_cyc = a->cycle;
        a->wsync_wr_sl  = a->scanline;
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
