/*
 * xtctl.h — miscellaneous PL control over the GP0 CONTROL block:
 * XT register-unlock, SALLY turbo speed, and A9 keyboard injection.
 * (gp0_ctrl and the diagnostic-word reads are simple enough that callers poke
 * the xt_gp0_map.h addresses directly.)
 */
#ifndef XTCTL_H_
#define XTCTL_H_

#include <stdint.h>
#include "xt_gp0_map.h"

/* --- XT register-unlock: the A9 sets the stock-vs-XT personality. Each bit
 *     ungates the NATIVE (6502/ANTIC-side) decode of one feature group; the
 *     A9/bridge path itself is never gated.  Reset (PL) -> 0x00 (stock).
 *     Read back the EFFECTIVE value (incl. any 6502 self-unlock at $D1DF). --- */
#define XT_UNLOCK_ANTIC          (1u << 0)  /* $D480-$D49F ANTIC chiplet */
#define XT_UNLOCK_SPRITE         (1u << 1)  /* sprite engine $D4Ax/$D4Dx */
#define XT_UNLOCK_BLITTER        (1u << 2)  /* blitter native $D4Bx/$D4Cx + $D4CA turbo */
#define XT_UNLOCK_BANK           (1u << 3)  /* $D5C0/$D5C1 code/data bank select */
#define XT_UNLOCK_GEM            (1u << 4)  /* $D5D0-$D5D4 GEM doorbell (reserved) */
#define XT_UNLOCK_KBD            (1u << 5)  /* reserved (kbd inject is bridge-only) */

void    xt_unlock_set(uint8_t mask);
uint8_t xt_unlock_get(void);

/* --- SALLY turbo: clock multiplier (1 = real Atari speed). Read-back is the
 *     EFFECTIVE multiplier the PL latched. --- */
void    xtctl_speed_set(uint8_t mult);
uint8_t xtctl_speed_get(void);

/* --- A9 keyboard injection (host-driven KBCODE -> POKEY). --- */
void xtctl_kbd_inject(uint8_t kbcode);   /* press: KBCODE + POKEY IRQ */
void xtctl_kbd_release(void);            /* all-keys-up (SKSTAT clear) */
void xtctl_kbd_break(void);              /* Atari BREAK (POKEY IRQ b7) */

#endif /* XTCTL_H_ */
