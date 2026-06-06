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

#endif // AES_INTERNAL_H
