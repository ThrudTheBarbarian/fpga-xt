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
void menu_redraw(void);            // repaint the active menu bar (always on top)
void aes_reserve_top(int h);       // reserve a top strip from the work area (the menu bar)

// Called by evnt_multi on a button-down outside the menu bar: handle a window
// frame interaction (raise / drag / resize / close box).  Returns 1 if the
// click hit a window frame (consumed), 0 if it fell in a work area / desktop.
int  wind_handle_click(int mx, int my);

#endif // AES_INTERNAL_H
