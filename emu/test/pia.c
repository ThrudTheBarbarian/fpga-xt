/*
 * pia.c — directed tests for the 6520 PIA.
 *
 * The rules pia_basic depends on, kept as named properties so a regression is
 * legible rather than showing up as one ACID test flipping.
 */
#include <stdio.h>
#include "../pia.h"

static int fails;

static void expect(const char *what, unsigned got, unsigned want)
{
    if (got == want) return;
    printf("  FAIL %s: got $%02X want $%02X\n", what, got, want);
    fails++;
}

int main(void)
{
    pia p;
    pia_reset(&p);

    /* ---- the direction register SHARES its address with the port, selected
     * by control bit 2.  This is pia_basic's "crosstalk" check: write the
     * direction register, flip to the port, write that, flip back, and the
     * direction register must have kept its own value. -------------------- */
    pia_write(&p, 0xD302, 0x38);           /* PACTL bit 2 clear -> DDRA */
    pia_write(&p, 0xD300, 0xCC);           /* DDRA = $cc */
    pia_write(&p, 0xD302, 0x3C);           /* bit 2 set -> the port itself */
    pia_write(&p, 0xD300, 0x55);           /* output latch = $55 */
    pia_write(&p, 0xD302, 0x38);           /* back to DDRA */
    expect("DDRA survives a write to the port", pia_read(&p, 0xD300), 0xCC);

    /* and the same for port B, which has its own control register */
    pia_write(&p, 0xD303, 0x38);
    pia_write(&p, 0xD301, 0x0F);
    pia_write(&p, 0xD303, 0x3C);
    pia_write(&p, 0xD301, 0xAA);
    pia_write(&p, 0xD303, 0x38);
    expect("DDRB survives a write to the port", pia_read(&p, 0xD301), 0x0F);

    /* ---- a read mixes the output latch (for OUTPUT bits) with the pin (for
     * input bits).  With nothing plugged in the lines idle high, so with
     * DDRA = $cc and the latch $55 the answer is $44 | $33 = $77. ---------- */
    pia_write(&p, 0xD302, 0x3C);
    expect("output bits read back the latch, input bits the pin",
           pia_read(&p, 0xD300), (0x55 & 0xCC) | (0xFF & ~0xCC));

    /* ---- after reset every pin is an INPUT ------------------------------ */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x38);
    expect("reset leaves all pins as inputs", pia_read(&p, 0xD300), 0x00);
    pia_write(&p, 0xD302, 0x3C);
    expect("so a port read is all pins", pia_read(&p, 0xD300), 0xFF);

    /* ---- control bits 7 and 6 are interrupt FLAGS and are not writable --- */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0xFF);
    expect("PACTL bits 7-6 are read-only", pia_read(&p, 0xD302), 0x3F);

    printf("pia: %s\n", fails ? "FAIL" : "all PIA tests pass");
    return fails ? 1 : 0;
}
