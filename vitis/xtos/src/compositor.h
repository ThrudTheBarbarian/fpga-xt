/*
 * compositor.h — drag-overlay control (GP0 COMPOSITOR block).
 *
 * A movable DDR-backed surface composited above the GEM desktop (depth 1) but
 * below the XL/ST windows (depth 2): shows a GEM window WHILE it is being
 * dragged, so moving it is a single register write instead of re-blitting it
 * into the desktop plane each frame (tear-free).
 *
 * Protocol: render the RGBA-8888 surface at the fixed OVL_STRIDE_W row stride
 * into DDR and FLUSH it (the HP2 read is not cache-coherent), then call
 * xt_overlay_enable().  The write to OVL_EN COMMITS the whole {x,y,w,h,en} set,
 * which the PL adopts at the next vblank.  Per drag step, xt_overlay_move();
 * on drop, xt_overlay_disable().
 *
 * The surface row stride is a FIXED PL constant (a variable stride would
 * synthesise a DSP multiply on the HP2 read-address path and bust clk_sys), so
 * render row r of column c at word r*OVL_STRIDE_W + c; only the first W columns
 * are fetched.  See hdl/fpga_xt_top.sv (u_plane_fetch_overlay).
 */
#ifndef COMPOSITOR_H_
#define COMPOSITOR_H_

#include <stdint.h>
#include "xt_gp0_map.h"

#define OVL_STRIDE_W   2048u   /* overlay surface stride in 32-bit words (= 8192 B) */

void xt_overlay_enable(uint32_t base, uint16_t x, uint16_t y, uint16_t w, uint16_t h);
void xt_overlay_move(uint16_t x, uint16_t y);   /* re-position only (keeps enabled) */
void xt_overlay_disable(void);

#endif /* COMPOSITOR_H_ */
