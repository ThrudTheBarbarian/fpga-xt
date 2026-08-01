#include "pia.h"

void pia_reset(pia *p)
{
    for (int i = 0; i < 2; i++) {
        p->out[i] = 0;
        p->ddr[i] = 0;         /* all inputs after reset */
        p->ctl[i] = 0;
        p->in[i]  = 0xFF;      /* nothing plugged in: lines idle high */
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
    default:
        /* Bits 7 and 6 are the interrupt FLAGS and are not writable. */
        p->ctl[i] = (uint8_t)((p->ctl[i] & 0xC0) | (val & 0x3F));
        break;
    }
}
