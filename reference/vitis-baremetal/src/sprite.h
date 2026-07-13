/* ============================================================================
 * ⚠ REFERENCE ONLY — THIS FILE IS NOT BUILT, NOT LINKED, NOT RUN.
 *
 * This is the RETIRED bare-metal XTOS. The live operating system is in loader/.
 * Do not "fix" this file; do not assume it reflects the running system.
 * See reference/vitis-baremetal/README.md.
 * ============================================================================ */
/*
 * sprite.h — A9-side driver for the hardware sprite engine (desktop compositor).
 *
 * The sprite engine composites hardware sprites over the desktop plane in the
 * scan-out path.  It is owned by the A9 (not the 6502): its register port is
 * driven over GP0 through the xt_gp0_regs SPRITE block —
 *     write reg index  -> XT_SPR_IDX   (GP0 SPRITE block)
 *     write reg data   -> XT_SPR_DATA  (pulses the engine's reg_we)
 * The "$D4Ax / $D4Dx" values below are the engine's internal register indices
 * (reg_addr[7:4] = 0xA per-sprite control, 0xD = descriptor shadow/commit), NOT
 * memory addresses.
 *
 * Sprite image data lives in the DDR3 "arena" at 0x3400_0000.  Format 1 (the
 * only one this driver uses) is 32-bit RGBA-8888, row stride 1<<14, pixel at
 * ARENA_BASE + (arena_row<<14) + (arena_col<<2); the low byte is alpha (0 =
 * transparent).
 */
#ifndef SPRITE_H
#define SPRITE_H

#include <stdint.h>

#define SPR_ARENA_BASE   0x34000000u

/* Set sprite `slot`'s descriptor (commits on the final write).  Coordinates are
 * in the 1080p scan-out space; arena_x/y locate the image in the arena;
 * log2sz selects an NxN sprite (N = 1<<log2sz). */
void sprite_set(int slot, int prio, int log2sz,
                int arena_x, int arena_y, int screen_x, int screen_y);

/* Enable/disable a sprite slot.  format: 0 = 16-bit RGBA-5551, 1 = 32-bit RGBA-8888. */
void sprite_enable(int slot, int format);

/* Master enable for the whole engine. */
void sprite_global_enable(int en);

/* Read sprite `slot`'s collision row (from the last frame): bit N set means slot
 * overlapped sprite N.  Refreshed every VBI; 0 = no current collisions. */
uint16_t sprite_collision(int slot);

/* Write a w×h RGBA-8888 image into the arena at (arena_x, arena_y) (format-1
 * layout), flushing it out to DDR for the fetcher. */
void sprite_load_rgba(int arena_x, int arena_y, int w, int h, const uint32_t *img);

/* Bring-up self-test: paint a 32x32 opaque-white sprite into the arena and show
 * it at screen (100,100) via slot 0.  Proves the fetch+composite path on HW. */
void sprite_test(void);

#endif /* SPRITE_H */
