#include "pia.h"

/* A side asserts /IRQ when a flag stands and its own enable bit is set.  Bit 0
 * enables CA1 (bit 7's flag); bit 3 enables CA2 (bit 6's) — but only while bit 5
 * has CA2 as an INPUT, since in output mode bit 3 is the output level instead. */
static void update_irq(pia *p)
{
    int on = 0;
    for (int i = 0; i < 2; i++) {
        if ((p->ctl[i] & 0x80) && (p->ctl[i] & 0x01)) on = 1;
        if ((p->ctl[i] & 0x40) && !(p->ctl[i] & 0x20) && (p->ctl[i] & 0x08)) on = 1;
    }
    p->irq = (uint8_t)on;
}

void pia_reset(pia *p)
{
    for (int i = 0; i < 2; i++) {
        p->out[i] = 0;
        p->ddr[i] = 0;         /* all inputs after reset */
        p->ctl[i] = 0;
        p->in[i]  = 0xFF;      /* nothing plugged in: lines idle high */
        p->c2[i]  = 1;         /* and so does CA2/CB2 */
    }
    p->irq = 0;
}

uint8_t pia_read(pia *p, uint16_t addr)
{
    int i = addr & 1;
    switch (addr & 3) {
    case 0: case 1:
        /* Bit 2 of the control register picks the port or its direction
         * register — they share the address. */
        if (!(p->ctl[i] & 0x04))
            return p->ddr[i];
        /* Reading the PORT clears that side's interrupt flags. */
        p->ctl[i] = (uint8_t)(p->ctl[i] & 0x3F);
        update_irq(p);
        /* An output bit reads back its own latch; an input bit reads the pin. */
        return (uint8_t)((p->out[i] & p->ddr[i]) | (p->in[i] & ~p->ddr[i]));
    default:
        return p->ctl[addr & 1];
    }
}

void pia_write(pia *p, uint16_t addr, uint8_t val)
{
    int i = addr & 1;
    switch (addr & 3) {
    case 0: case 1:
        if (p->ctl[i] & 0x04) p->out[i] = val;
        else                  p->ddr[i] = val;
        break;
    default: {
        /* Bits 7 and 6 are the interrupt FLAGS and are not writable. */
        uint8_t old = p->ctl[i];
        p->ctl[i] = (uint8_t)((old & 0xC0) | (val & 0x3F));

        /* CA2/CB2's level comes from control bit 3 while bit 5 selects OUTPUT,
         * and from the external line otherwise — which idles high with nothing
         * plugged in.  A transition in the direction bit 4 selects latches the
         * flag in bit 6.  pia_irq drives exactly that: CA2 out low ($34), out
         * high ($3c) for a rising edge, then back to input ($14), and expects
         * PACTL to read $54 — the flag standing. */
        uint8_t was = p->c2[i];
        /* ENTERING an output mode clears the flag.  Not every write while in
         * one: the vector's first entry writes $3c twice and requires the flag
         * set by the first to survive the second.  An edge in the same write can
         * still set it again, so this has to come BEFORE the edge check. */
        if (!(old & 0x20) && (p->ctl[i] & 0x20))
            p->ctl[i] = (uint8_t)(p->ctl[i] & ~0x40);

        if (p->ctl[i] & 0x20) {                /* OUTPUT: level follows bit 3 */
            uint8_t now = (uint8_t)((p->ctl[i] >> 3) & 1);
            /* An edge counts only while ALREADY an output.  The level change
             * caused by taking control of the line in the first place is not an
             * edge — reading it as one re-sets the flag that entering output
             * mode just cleared. */
            if ((old & 0x20) && now != was) {
                /* The selected edge SETS the flag and the opposite one CLEARS
                 * it.  That is what makes the vector's "high-low-high sequence
                 * does not work" ($34,$3c,$34) leave the flag down while
                 * low-high-low-high ($3c,$34,$3c) leaves it up. */
                if ((now != 0) == ((p->ctl[i] & 0x10) != 0))
                    p->ctl[i] = (uint8_t)(p->ctl[i] | 0x40);
                else
                    p->ctl[i] = (uint8_t)(p->ctl[i] & ~0x40);
            }
            p->c2[i] = now;
        } else {
            /* INPUT: the line returns to the external level, which idles high
             * with nothing plugged in.  RELEASING a line that was being driven
             * LOW is therefore a real rising edge, and port A's vector turns on
             * exactly that: "IRQA2 is set if the line is forced low ($34) and
             * the next input mode is for a negative-to-positive transition". */
            if (was == 0 && (p->ctl[i] & 0x10))
                p->ctl[i] = (uint8_t)(p->ctl[i] | 0x40);
            p->c2[i] = 1;
        }
        update_irq(p);
        break;
    }
    }
}
