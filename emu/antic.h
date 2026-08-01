/*
 * antic.h — the ANTIC timing core.
 *
 * ANTIC owns the bus and hands the CPU its cycles.  The system's read/write
 * callbacks call antic_tick() until it yields, so a halted CPU is simply a
 * callback that takes longer to return.  There is no CDC, no second raster with
 * its own phase, and no /RDY sampling window — see emu/antic-design.md.
 *
 * Every timing landmark below is a measured ACID800 result, with the test that
 * establishes it named.  None of them are guesses.
 */
#ifndef ANTIC_H
#define ANTIC_H

#include <stdint.h>
#include "antic_dma.h"

/* Scanline cycle landmarks (docs/Acid800/). */
#define ANTIC_CYC_NMIST   6     /* NMIST bits set; NMIEN sampled  (antic_nmist) */
#define ANTIC_CYC_NMIRES  7     /* NMIRES takes effect from here  (antic_nmist) */
#define ANTIC_CYC_WSYNC 103     /* first cycle the CPU gets BACK  (see below) */
/* Where this boundary sits cannot be read off antic_wsync — its probes are
 * anchored to the release, so moving it moves them too and the reading cancels.
 * Two other tests annotate it directly and they agree on 103: antic_nmist's
 * "pha:pla ;*, 104..109" is seven cycles, so the * is 103, and antic_vscroldli
 * passes only at this value.  gtia_pmretrigger's "sta hitclr ;*, 105, 106, 107"
 * reads as 104, but that annotation is one slot short for a four-cycle STA. */
#define ANTIC_CYC_VCOUNT 111    /* VCOUNT advances                (antic_vcount) */

#define ANTIC_LINES_NTSC 262
#define ANTIC_LINES_PAL  312

/* NMIST/NMIEN bits */
#define ANTIC_NMI_DLI 0x80
#define ANTIC_NMI_VBI 0x40

typedef uint8_t (*antic_fetch_fn)(void *ctx, uint16_t addr);

/* Scanlines per row, by ANTIC mode.  Modes 0 (blank) and 1 (jump) are not
 * display modes and are handled separately. */
#define ANTIC_CYC_ROWEND 4   /* VSCROL is sampled for the row-end compare here */
extern const uint8_t antic_row_height[16];
extern int antic_glyph_probe;   /* debug: trace glyph-row selection */

/* ---- the two address counters ---------------------------------------------
 * Both are narrower than 16 bits and BOTH wrap mid-instruction, which is what
 * antic_addresswrap checks by putting the 1 KB break in the middle of an LMS
 * operand.  Written as plain 16-bit adders they pass casual testing and fail
 * that test immediately. */

/* The display-list counter is 10 bits within its 1 KB page. */
static inline uint16_t antic_dl_next(uint16_t a)
{
    return (uint16_t)((a & 0xFC00u) | ((a + 1u) & 0x03FFu));
}

/* The playfield/LMS counter wraps at 4 KB. */
static inline uint16_t antic_pf_next(uint16_t a)
{
    return (uint16_t)((a & 0xF000u) | ((a + 1u) & 0x0FFFu));
}

typedef struct {
    /* registers */
    uint8_t  dmactl, chactl, hscrol, vscrol, pmbase, chbase;
    uint8_t  nmien, nmist;

    /* timing */
    int cycle;        /* 0..113 within the scanline */
    int scanline;     /* 0..lines-1 */
    int lines;        /* ANTIC_LINES_NTSC or _PAL */
    int vcount;       /* the register's own counter — see antic_vcount.md */

    /* WSYNC: the CPU is held until cycle ANTIC_CYC_WSYNC.  Arms on the FIRST
     * $D40A write of a read-modify-write, which writes it twice. */
    int wsync_halt;

    int nmi;          /* NMI line to the CPU */

    antic_fetch_fn fetch;
    void          *ctx;

    /* ---- display-list execution ---------------------------------------- */
    uint16_t dl_addr;     /* display-list program counter */
    uint16_t pf_addr;     /* playfield memory scan address (LMS target) */
    uint8_t  dl_insn;
    uint8_t  vscrol_prev;  /* did the PREVIOUS instruction have the VSCROL bit? */
    uint8_t  dli_fired;    /* this instruction's DLI has already been raised */
    uint8_t  row_ends;     /* latched at ANTIC_CYC_ROWEND: does the row finish
                            * with THIS scanline?  Sampling VSCROL here rather
                            * than at line_start is what separates a write on
                            * cycle 3 from one on cycle 4 (antic_vscroldli). */
    int      row_end;      /* row ends when row_line passes this.  -1 means "use
                            * VSCROL, compared LIVE" — the row after a scrolled
                            * region ends when the row counter reaches VSCROL, so
                            * a write lands or misses to the cycle
                            * (antic_vscroldli). */

    /* ---- player/missile DMA -------------------------------------------------
     * ANTIC FETCHES this data; whether GTIA latches it is GRACTL's business, and
     * GRACTL lives in GTIA — so the bytes are exposed here and system.c applies
     * the gate.  antic_pmdma checks the two are separate. */
    uint8_t  pm_p[4], pm_m;
    uint8_t  pm_fetched;     /* the instruction driving the current row */
    int      row_line;    /* scanline within the current row */
    int      row_height;  /* DYNAMIC — VSCROL can extend it mid-row, so the
                           * next row's DLI moves with it and DLI scanlines
                           * must never be precomputed (antic_vscroldli) */
    int      dl_done;     /* JVB seen: wait for vertical blank */
    int      dli_line;    /* this scanline is the row's LAST and the row's
                           * instruction has bit 7 — so a DLI is due at cycle 6.
                           * Recomputed per line, never precomputed for the
                           * frame (antic_vscroldli). */

    /* ---- the line buffer -------------------------------------------------
     * ANTIC fetches into this and displays FROM it, so fetch time and display
     * time are different instants.  antic_linebuffering proves the separation:
     * change DMACTL between the two and the buffer still holds what was fetched
     * under the OLD width; interrupt playfield DMA mid-line and the rest of the
     * line is NOT blanked, because the buffer still holds it; and the contents
     * can be displayed again.
     *
     * So it is deliberately NOT cleared per line — persistence is the observable
     * behaviour, not an accident. */
    uint8_t linebuf[64];   /* wide playfield is 48 bytes; 64 is room to spare */
    uint8_t glyphbuf[64];  /* character modes fetch a GLYPH per name byte — two
                            * fetches per character, so the decode has both */
    int     lb_len;        /* bytes fetched on the last line that fetched any */

    /* the DMA schedule for the scanline in progress */
    uint8_t blocked[ANTIC_LINE_CYCLES];
} antic;

void    antic_init(antic *a, antic_fetch_fn fetch, void *ctx, int lines);
void    antic_reset(antic *a);

/* Advance one machine cycle.  Returns 1 if ANTIC (or a WSYNC halt) took the
 * bus, meaning the CPU did NOT get this cycle. */
int     antic_tick(antic *a);

/* Execute one display-list instruction: fetch it, apply its option bits, set
 * up the row.  Called when the previous row completes. */
void    antic_dl_exec(antic *a);

/* Visible display region.  ANTIC starts the display list at scanline 8 and the
 * VBI arrives at 248. */
#define ANTIC_DISPLAY_TOP     8
#define ANTIC_DISPLAY_BOTTOM 248

/* Bytes across the playfield at a given DMACTL width. */
int     antic_pf_bytes(uint8_t dmactl, uint8_t mode);

/* Read the line buffer as the DISPLAY side sees it now.  Deliberately separate
 * from the fetch: the width used here is the CURRENT one, which is what makes
 * a mid-line DMACTL change alias. */
uint8_t antic_display_byte(const antic *a, int i);

/* The playfield colour class at colour clock `cc` (0..227): -1 for background,
 * else 0..3 for PF0..PF3.  Computed LIVE rather than tabulated per line —
 * antic_pfstarttiming and antic_pfstoptiming write DMACTL and HSCROL
 * mid-scanline and expect the edges to move, which a per-line table cannot
 * express.  `hires_lit` reports whether either half-clock pixel is set, which
 * is all GTIA is shown of a hi-res mode. */
int antic_pf_at(const antic *a, int cc, int *hires_lit);

/* The raw 4-bit playfield value at colour clock `cc`, or -1 outside the window.
 * The GTIA modes reinterpret ANTIC mode F's 320 hi-res bits as 80 nibbles of two
 * colour clocks each, so they need the DATA, not a colour class. */
int antic_pf_nibble(const antic *a, int cc, int shift);

uint8_t antic_read(antic *a, uint16_t addr);
void    antic_write(antic *a, uint16_t addr, uint8_t val);

#endif /* ANTIC_H */
