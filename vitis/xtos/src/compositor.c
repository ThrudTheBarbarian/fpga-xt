/*
 * compositor.c — drag-overlay control.  See compositor.h.
 *
 * Each overlay register is a single 32-bit word now (the old byte-at-a-time
 * pokes are gone), so a position is two word writes + the commit.  OVL_EN is
 * written LAST and COMMITS the whole {x,y,w,h,en} set atomically.
 */

#include "compositor.h"
#include "xil_io.h"

void xt_overlay_enable(uint32_t base, uint16_t x, uint16_t y, uint16_t w, uint16_t h)
{
    Xil_Out32(XT_OVL_BASE, base);
    Xil_Out32(XT_OVL_W,    (uint32_t)(w & 0x0FFFu));
    Xil_Out32(XT_OVL_H,    (uint32_t)(h & 0x0FFFu));
    Xil_Out32(XT_OVL_X,    (uint32_t)(x & 0x0FFFu));
    Xil_Out32(XT_OVL_Y,    (uint32_t)(y & 0x0FFFu));
    Xil_Out32(XT_OVL_EN,   1u);            /* enable + commit (atomic at vblank) */
}

void xt_overlay_move(uint16_t x, uint16_t y)
{
    Xil_Out32(XT_OVL_X,  (uint32_t)(x & 0x0FFFu));
    Xil_Out32(XT_OVL_Y,  (uint32_t)(y & 0x0FFFu));
    Xil_Out32(XT_OVL_EN, 1u);              /* keep enabled + commit */
}

void xt_overlay_disable(void)
{
    Xil_Out32(XT_OVL_EN, 0u);              /* disable + commit */
}
