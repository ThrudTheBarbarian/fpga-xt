// aes/aes_internal.h — shared internals between the AES translation units.

#ifndef AES_INTERNAL_H
#define AES_INTERNAL_H

#include "aes/aes.h"

int          aes_handle(void);     // the VDI workstation AES draws through
const theme *aes_theme(void);      // the active theme

// Called by evnt_multi on a button-down: if it lands in the active menu bar,
// run the pull-down and post MN_SELECTED; returns 1 if the click was consumed.
int  menu_handle_click(int mx, int my);
// Draw a dropdown open with one item highlighted (item_ord<0 = none) — for
// demos / screenshots; the live pull-down is driven by menu_handle_click.
void menu_render_open(int title_ord, int item_ord);
// Draw a popup menu open with row `hov` highlighted at a laid-out geometry —
// for demos / screenshots / headless tests (the live popup is menu_popup).
void menu_popup_render_demo(const menu_item *items, int n, int hov, const popup_geom *g);
void menu_redraw(void);            // repaint the active menu bar (always on top)
void aes_reserve_top(int h);       // reserve a top strip from the work area (the menu bar)

// Called by evnt_multi on a button-down outside the menu bar: handle a window
// frame interaction (raise / drag / resize / close box).  Returns 1 if the
// click hit a window frame (consumed), 0 if it fell in a work area / desktop.
int  wind_handle_click(int mx, int my);

// Idle-aware wait: aes_wait chunked by the aes_set_idle period, calling the
// idle hook on each expiry.  Every modal AES loop waits through this.
int  aes_wait_idle(aes_event *ev, int timeout_ms);

// wind_redraw generation counter — modal loops compare it around the idle
// hook to notice a full repaint (which wipes anything drawn outside
// wind_redraw, e.g. a modal dialog) and repaint their own pixels.
int  aes_redraw_gen(void);

// The HW drag-overlay hooks (window.c holds the registration): begin returns
// 0 when no hook / refused -> the caller falls back to redraw-per-motion.
int  aes_ovl_lift(int x, int y, int w, int h);
void aes_ovl_move(int x, int y);
void aes_ovl_drop(void);

// Edit focus (edit.c): returns 1 + the caret index when `obj` of `tree` is
// the focused edit field — object.c draws the caret during tree draws.
int  objc_edit_state(OBJECT *tree, int obj, int *caret);
// Build the display string for a TEDINFO (template merged with text) into
// out[cap]; returns the display index of input position `pos` via *dpos
// (pos < 0 -> ignored).  Shared by the renderer (object.c) and edit.c.
int  ted_display(const TEDINFO *ted, char *out, int cap, int pos, int *dpos);

#endif // AES_INTERNAL_H
