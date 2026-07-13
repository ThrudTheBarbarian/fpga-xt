/* ============================================================================
 * ⚠ REFERENCE ONLY — THIS FILE IS NOT BUILT, NOT LINKED, NOT RUN.
 *
 * This is the RETIRED bare-metal XTOS. The live operating system is in loader/.
 * Do not "fix" this file; do not assume it reflects the running system.
 * See reference/vitis-baremetal/README.md.
 * ============================================================================ */
/*
 * xtctl.c — XT register-unlock, SALLY speed, and keyboard injection.  See xtctl.h.
 */

#include "xtctl.h"
#include "xil_io.h"

void xt_unlock_set(uint8_t mask)
{
    Xil_Out8(XT_CTRL_UNLOCK, mask);
}

uint8_t xt_unlock_get(void)
{
    return (uint8_t)(Xil_In32(XT_CTRL_UNLOCK) & 0xFFu);
}

void xtctl_speed_set(uint8_t mult)
{
    Xil_Out8(XT_CTRL_SPEED, mult);
}

uint8_t xtctl_speed_get(void)
{
    return (uint8_t)(Xil_In32(XT_CTRL_SPEED) & 0xFFu);
}

void xtctl_kbd_inject(uint8_t kbcode)
{
    Xil_Out8(XT_CTRL_KBD_INJECT, kbcode);
}

void xtctl_kbd_release(void)
{
    Xil_Out8(XT_CTRL_KBD_RELEASE, 0);
}

void xtctl_kbd_break(void)
{
    Xil_Out8(XT_CTRL_KBD_BREAK, 0);
}
