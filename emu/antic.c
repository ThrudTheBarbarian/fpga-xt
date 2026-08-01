/*
 * antic.c — the ANTIC timing core.  See antic.h.
 */
#include "antic.h"
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
    uint8_t insn = dl_fetch(a);
    a->dl_insn   = insn;
    a->row_line  = 0;

    int mode = insn & 0x0F;

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

    /* VSCROL shortens the first row of a scrolled region and lengthens the
     * last.  Sampled live (by cycle 3), never precomputed. */
    if (insn & 0x20)
        a->row_height -= (a->vscrol & 0x0F);
    if (a->row_height < 1) a->row_height = 1;
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
    a->nmi = 0;
    a->nmist = 0;
    a->nmien = 0;
}

static antic_width width_of(uint8_t dmactl)
{
    switch (dmactl & 0x03) {
    case 1:  return ANTIC_NARROW;
    case 3:  return ANTIC_WIDE;
    default: return ANTIC_NORMAL;
    }
}

/* Start of a scanline: advance the display list if the current row has
 * finished, work out whether a DLI is due, and rebuild this line's DMA
 * schedule from the LIVE state.  Nothing here is precomputed for the frame —
 * VSCROL can change a row's height while it is running, which moves the next
 * row's DLI with it (antic_vscroldli). */
static void line_start(antic *a)
{
    memset(a->blocked, 0, sizeof a->blocked);
    a->dli_line = 0;

    int visible = a->scanline >= ANTIC_DISPLAY_TOP
               && a->scanline <  ANTIC_DISPLAY_BOTTOM;
    if (!visible || !(a->dmactl & 0x20) || a->dl_done)
        return;

    if (a->row_line >= a->row_height)
        antic_dl_exec(a);

    /* The DLI belongs to the LAST scanline of the row — including a BLANK-LINE
     * row, which is the case antic_dlitiming is built out of and the fabric
     * dl_parser gets wrong. */
    a->dli_line = (a->dl_insn & 0x80) && (a->row_line == a->row_height - 1);

    int mode = a->dl_insn & 0x0F;
    if (mode >= 2) {
        antic_dma_line((uint8_t)mode, width_of(a->dmactl),
                       a->row_line == 0, a->hscrol, a->blocked);

        /* FETCH into the line buffer.  The playfield counter wraps at 4 KB
         * during the fetch, so a row crossing that boundary reads from the
         * bottom of the same 4 KB page (antic_addresswrap).
         *
         * Note what is NOT done here: the buffer is not cleared first.  If
         * playfield DMA is off this line, the previous contents stay and are
         * displayed again — which is what antic_linebuffering's
         * "mid-interrupted" and "replayed" cases check. */
        int n = antic_pf_bytes(a->dmactl, (uint8_t)mode);
        for (int i = 0; i < n && i < (int)sizeof a->linebuf; i++) {
            a->linebuf[i] = a->fetch ? a->fetch(a->ctx, a->pf_addr) : 0xFF;
            a->pf_addr = antic_pf_next(a->pf_addr);
        }
        a->lb_len = n;
    }

    a->row_line++;
}

int antic_tick(antic *a)
{
    int c = a->cycle;
    int took = 0;

    if (c == 0) line_start(a);

    /* ---- status and interrupt timing, all at fixed cycles ------------------
     * NMIST bits set at cycle 6 REGARDLESS of NMIEN — NMIEN gates the
     * interrupt, not the status — and NMIEN is sampled at the same cycle to
     * decide whether the interrupt is raised (antic_nmist). */
    if (c == ANTIC_CYC_NMIST) {
        if (a->dli_line) {
            a->nmist = (uint8_t)((a->nmist & ~ANTIC_NMI_VBI) | ANTIC_NMI_DLI);
            if (a->nmien & ANTIC_NMI_DLI) a->nmi = 1;
        }
        int vbi = (a->scanline == ANTIC_DISPLAY_BOTTOM);
        if (vbi) {
            /* the DLI and VBI status bits clear each other on arrival */
            a->nmist = (uint8_t)((a->nmist & ~ANTIC_NMI_DLI) | ANTIC_NMI_VBI);
            if (a->nmien & ANTIC_NMI_VBI) a->nmi = 1;
        }
    }

    /* VCOUNT is scanline>>1, so it advances at cycle 111 of every ODD scanline.
     * Because that advance happens on the LAST scanline too (261 is odd), it
     * momentarily reads lines/2 = 131 for cycles 111-113 before the frame wrap
     * clears it — antic_vcount's "nasty one, single cycle rollover". */
    if (c == ANTIC_CYC_VCOUNT && (a->scanline & 1))
        a->vcount++;

    /* WSYNC releases /RDY at 104: the first CPU cycle after a halt is 105. */
    if (a->wsync_halt) {
        /* Cycle 104 is where /RDY is RELEASED, and it is still ANTIC's — the
         * first cycle the CPU gets is 105.  Letting the CPU have 104 makes
         * every WSYNC-anchored measurement one machine cycle early, which is
         * what antic_wsync's d0 caught. */
        took = 1;
        if (c == ANTIC_CYC_WSYNC) a->wsync_halt = 0;
    }

    if (!took && c < ANTIC_LINE_CYCLES && a->blocked[c])
        took = 1;

    /* ---- advance ---------------------------------------------------------- */
    if (++a->cycle >= ANTIC_LINE_CYCLES) {
        a->cycle = 0;
        if (++a->scanline >= a->lines) {
            a->scanline = 0;
            a->vcount   = 0;     /* the wrap is at the END of the last line */
            /* A new frame restarts the display list, but a DL that ran past
             * the bottom simply continues — and a DLI already raised survives
             * the boundary (antic_dlistwrap). */
            a->dl_addr   = a->dlist;
            a->row_line  = a->row_height;   /* force a fetch on the first line */
            a->dl_done   = 0;
        }
    }
    return took;
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
    case 0x00: a->dmactl = val; break;
    case 0x01: a->chactl = val; break;
    case 0x02: a->dlist  = (uint16_t)((a->dlist & 0xFF00) | val); break;
    case 0x03: a->dlist  = (uint16_t)((a->dlist & 0x00FF) | (val << 8)); break;
    case 0x04: a->hscrol = val; break;
    case 0x05: a->vscrol = val; break;
    case 0x07: a->pmbase = val; break;
    case 0x09: a->chbase = val; break;
    case 0x0A:
        /* WSYNC.  Arms on the FIRST write — an RMW writes it twice and the
         * halt must not re-arm on the second (antic_wsync, d5). */
        if (!a->wsync_halt) a->wsync_halt = 1;
        break;
    case 0x0E: a->nmien = val; break;
    case 0x0F:
        /* NMIRES clears the STATUS but must not retract an interrupt already
         * raised — "VBI was blocked by NMIRES" is a failure (antic_nmist). */
        a->nmist = 0;
        break;
    default: break;
    }
}
