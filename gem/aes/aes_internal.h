// aes/aes_internal.h — shared internals between the AES translation units.

#ifndef AES_INTERNAL_H
#define AES_INTERNAL_H

#include "aes/aes.h"

// aes_handle() is declared in aes.h — a wind_content callback needs it (under gemd it is the
// app's ONLY workstation), so it is public.
const theme *aes_theme(void);      // the active theme

// One library, two modes (RESPONSIBILITIES.md §5). appl_init() calls attach: if the "gem"
// service is up the app becomes a CLIENT and every wind_* call becomes a message; if it is not,
// the app stays LOCAL and nothing changes. gemd declares itself SERVER (aes_server_mode).
void wind_client_attach(void);
void wind_client_detach(void);

// SERVER-side seam (gemd only). gemd owns the window list but reaches it through these rather
// than poking the struct, so the window layer keeps exactly one owner.
void     wind_attach_surface(int hd,int surf_id,uint32_t gen,uint32_t*px,
                             int w,int h,int stride,int client);
void     wind_work_size(int hd,int*w,int*h);       // only the AES knows: chrome is its business
void     wind_work_origin(int hd,int*x,int*y);     // work-area origin ON SCREEN
void     wind_rect_of(int hd,int*x,int*y,int*w,int*h);
int      wind_surface_of(int hd);
uint32_t wind_gen_of(int hd);
int      wind_client_of(int hd);
int      wind_drag_sizing(void);   // 1 while a sizer drag is live (server mode) — gemd's
                                   // surface policy allocates ONCE (generous) during it and
                                   // shrink-fits on release, instead of per quantum crossing
int      wind_bottom_client(void);             // §10: the desktop's client (menu owner default)
int      wind_resize_zone_at(int mx,int my);   // RZ_ mask under the pointer on the TOP window
                                   // (0 = none): gemd's hover cursor swap
enum { WIND_RZ_L=1, WIND_RZ_R=2, WIND_RZ_T=4, WIND_RZ_B=8 };
void     aes_set_menu_redraw(void (*fn)(void));   // gemd's strip-composite hook (§10)
int      wind_next_of_client(int client,int from); // walk a dead client's windows (§9)
int      wind_vsb_col(int hd,int*x,int*y,int*w,int*h,int*thy,int*thh);
                                                   // scrollbar column + thumb (screen px);
                                                   // 0 = no bar. So gemd repaints THE BAR
                                                   // when only the bar changed (M5).

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

// The smallest window the sizer will drag to — and therefore the smallest rect a
// client may ask for: gemd clamps a WF_CURRXYWH request with the SAME numbers.
// One rule, two doors; a request must not reach a size a drag could not.
#define WIND_MIN_W 120
#define WIND_MIN_H 80

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
