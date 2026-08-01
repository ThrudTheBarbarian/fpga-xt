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

    /* ---- CA2/CB2 and the IRQ flag in bit 6.  Four rules, each of which
     * pia_irq's vector tables isolate deliberately. ---------------------- */

    /* the selected edge SETS it while already an output */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x34);            /* enter output, drive low */
    pia_write(&p, 0xD302, 0x3C);            /* drive high: rising, bit 4 selects */
    expect("a selected edge sets IRQA2", pia_read(&p, 0xD302) & 0x40, 0x40);

    /* the OPPOSITE edge clears it — "high-low-high does not work" */
    pia_write(&p, 0xD302, 0x34);
    expect("the opposite edge clears it", pia_read(&p, 0xD302) & 0x40, 0x00);

    /* ENTERING an output mode clears it, but staying in one does not */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x34);
    pia_write(&p, 0xD302, 0x3C);            /* set */
    pia_write(&p, 0xD302, 0x3C);            /* still output: must survive */
    expect("a repeat write in output mode keeps it",
           pia_read(&p, 0xD302) & 0x40, 0x40);
    pia_write(&p, 0xD302, 0x04);            /* to input, line was high: no edge */
    pia_write(&p, 0xD302, 0x24);            /* ENTER output: clears */
    expect("entering an output mode clears it",
           pia_read(&p, 0xD302) & 0x40, 0x00);

    /* releasing a line that was driven LOW is a real rising edge */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x3C);            /* output high */
    pia_write(&p, 0xD302, 0x34);            /* output low */
    pia_write(&p, 0xD302, 0x14);            /* to input, rising select */
    expect("releasing a driven-low line is a rising edge",
           pia_read(&p, 0xD302) & 0x40, 0x40);

    /* never lowered, so nothing to release */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x3C);
    pia_write(&p, 0xD302, 0x3C);
    pia_write(&p, 0xD302, 0x14);
    expect("a line never lowered raises nothing",
           pia_read(&p, 0xD302) & 0x40, 0x00);

    /* the flag only reaches /IRQ when its own enable bit is set */
    pia_reset(&p);
    pia_write(&p, 0xD302, 0x3C);
    pia_write(&p, 0xD302, 0x34);
    pia_write(&p, 0xD302, 0x14);            /* flag set, bit 3 clear: masked */
    expect("a masked flag does not assert IRQ", p.irq, 0);
    pia_write(&p, 0xD302, 0x1C);            /* bit 3 set: enabled */
    expect("an enabled flag asserts IRQ", p.irq, 1);
    pia_write(&p, 0xD302, 0x3C);            /* reading the port clears */
    pia_reset(&p);

    printf("pia: %s\n", fails ? "FAIL" : "all PIA tests pass");
    return fails ? 1 : 0;
}
