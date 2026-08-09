/*
 * sys.c — directed tests of the WHOLE machine, the part no other gate reaches.
 *
 * harte/klaus gate the CPU, antic/gtia/ptimer gate a chip in isolation.  Some
 * rules live in neither: they are about how the pieces are wired to each other
 * in system.c — who drives the bus on a given cycle, and when a latch samples
 * it.  Those are exactly the rules a later refactor can revert without any
 * existing gate noticing, so they get one here.
 *
 * Each case is an ACID800 scenario transcribed into a host test, the way irq.c
 * transcribes cpu_clisei.  See docs/Acid800/.
 */
#include <stdio.h>
#include <string.h>
#include "../system.h"

static int fails;

static void check(const char *name, int ok, const char *what,
                  unsigned got, unsigned want)
{
    if (ok) return;
    printf("  FAIL %s: %s got $%02x, want $%02x\n", name, what, got, want);
    fails++;
}

/* ---- gtia_phantomdma: the P/M latch samples the BUS, not ANTIC -------------
 *
 * GRACTL opens GTIA's player latch on a fixed scanline slot whether or not
 * DMACTL asked ANTIC to fetch anything there.  With player DMA OFF, nothing of
 * ANTIC's is on the bus at that slot — the CPU is, mid-instruction — so the
 * byte latched into GRAFP0 is whatever the CPU's own access carried.
 *
 * This is ACID800 gtia_phantomdma's setup: DMACTL $21 (narrow playfield, DL
 * DMA, no P/M DMA), GRACTL $02, and an `lda $0100` positioned so its OPCODE
 * FETCH lands on the player-0 slot.  The byte is therefore $AD, which is not a
 * value ANTIC fetches anywhere on that scanline — the whole point of the test,
 * and the reason "the last byte ANTIC drove" cannot be the model.
 */
static void phantom_dma(void)
{
    static const uint8_t prog[] = {
        0xA9, 0x00, 0x8D, 0x0E, 0xD4,   /* $2000 lda #0    / sta nmien      */
        0x78,                           /* $2005 sei                        */
        0xA9, 0x7C,                     /* $2006 lda #124                   */
        0xCD, 0x0B, 0xD4,               /* $2008 cmp vcount                 */
        0xD0, 0xFB,                     /* $200B bne -5                     */
        0xA9, 0x00, 0x8D, 0x02, 0xD4,   /* $200D lda #<dlist / sta dlistl   */
        0xA9, 0x24, 0x8D, 0x03, 0xD4,   /* $2012 lda #>dlist / sta dlisth   */
        0xA9, 0x21, 0x8D, 0x00, 0xD4,   /* $2017 lda #$21  / sta dmactl     */
        0xA9, 0x81, 0x8D, 0x1B, 0xD0,   /* $201C lda #$81  / sta prior      */
        0xA9, 0x02, 0x8D, 0x1D, 0xD0,   /* $2021 lda #$02  / sta gractl     */
        0xA9, 0xFF, 0x8D, 0x0D, 0xD0,   /* $2026 lda #$ff  / sta grafp0     */
        0xA2, 0x0F,                     /* $202B ldx #15                    */
        0xEC, 0x0B, 0xD4, 0xD0, 0xFB,   /* $202D cpx vcount / bne -5        */
        0xEC, 0x0B, 0xD4, 0xF0, 0xFB,   /* $2032 cpx vcount / beq -5        */
        /* WSYNC resynchronises, so the tail below is aligned to the scanline
         * however long the setup above took: */
        0xEE, 0x0A, 0xD4,               /* $2037 inc wsync   ;ends line 32  */
        0x8D, 0x1E, 0xD0,               /* $203A sta hitclr  ;105..108      */
        0xEA, 0xEA,                     /* $203D nop / nop   ;109..112      */
        0xA5, 0x00,                     /* $203F lda $00     ;113, 0        */
        0xAD, 0x00, 0x01,               /* $2041 lda $0100   ;the $AD fetch */
        0x4C, 0x44, 0x20,               /* $2044 jmp *                      */
    };
    static const uint8_t dlist[] = {
        0x70, 0x70, 0x70,               /* 24 blank lines: 8..31            */
        0x4F, 0x12, 0x24,               /* mode F + LMS framebuf: line 32   */
        0x0F,                           /* mode F:                 line 33  */
        0x41, 0x00, 0x24,               /* jump and wait for vblank         */
    };

    static atari s;
    atari_init(&s);
    memcpy(s.ram + 0x2000, prog, sizeof prog);
    memcpy(s.ram + 0x2400, dlist, sizeof dlist);
    memset(s.ram + 0x2412, 0x88, 64);
    s.cpu.pc = 0x2000;
    s.cpu.s  = 0xFD;

    /* Sample the instant the aligned instruction has run, at the spin: the
     * phantom latch fires on EVERY scanline, so reading it at the end of the
     * run reads some other line's bus — and reading it on the first scanline 33
     * to come past reads a frame from the middle of the VCOUNT wait. */
    int got = -1;
    for (long i = 0; i < 2000000 && got < 0; i++) {
        atari_step(&s);
        if (s.cpu.pc == 0x2044) got = s.gt.grafp[0];
    }
    if (got < 0) { printf("  FAIL phantomdma: never reached the measured line\n");
                   fails++; return; }
    check("phantomdma", got == 0xAD, "GRAFP0 latched", (unsigned)got, 0xAD);
    /* and the negative half: $88 is what ANTIC fetches all over that line, so
     * seeing it means the latch went back to sampling ANTIC's fetch */
    check("phantomdma", got != 0x88, "GRAFP0 latched ANTIC's fetch",
          (unsigned)got, 0xAD);
}

int main(void)
{
    phantom_dma();
    printf("sys: %s\n", fails ? "FAIL" : "all system-wiring tests pass");
    return fails ? 1 : 0;
}
