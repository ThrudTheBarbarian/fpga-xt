// aes.h — GEM AES (Application Environment Services), the layer above the VDI:
// the OBJECT tree (dialogs / forms / windows described as a tree of widgets),
// the event loop, menus and windows.  Built on the VDI + the theme — objc_draw
// renders each OBJECT through theme_draw, so widgets are themed for free and AES
// itself never touches pixels.  The classic GEM ABI (OBJECT layout, types,
// flags, states, call names) is preserved so m68k apps bind to it directly.

#ifndef GEM_AES_H
#define GEM_AES_H

#include "theme.h"
#include "vdi/vdi.h"
#include <stdint.h>

// A node in an object tree.  Children hang off ob_head..ob_tail; the last
// child's ob_next points back to the parent.  Coordinates are relative to the
// parent (the root's are absolute / screen).
typedef struct {
    int16_t  ob_next, ob_head, ob_tail;   // sibling, first child, last child (-1 = none)
    uint16_t ob_type;                      // G_*
    uint16_t ob_flags;                     // OF_*
    uint16_t ob_state;                     // OS_*
    void    *ob_spec;                      // type-specific: G_STRING/G_BUTTON -> char*
    int16_t  ob_x, ob_y, ob_w, ob_h;
} OBJECT;

enum { G_BOX=20, G_TEXT=21, G_BOXTEXT=22, G_IMAGE=23, G_USERDEF=24, G_IBOX=25,
       G_BUTTON=26, G_BOXCHAR=27, G_STRING=28, G_FTEXT=29, G_FBOXTEXT=30,
       G_ICON=31, G_TITLE=32,
       // our themed extensions (checkbox / radio / popup / colour icon), drawn
       // via the theme + the software gfx backend
       G_CHECKBOX=40, G_RADIO=41, G_POPUP=42, G_FIELD=43, G_CICON=44 };

// ob_spec for G_CICON — our colour desktop/file icon: a pre-scaled RGBA bitmap
// blitted src-over, centred at the top of the object rect, with `text` centred
// beneath it.  OS_SELECTED paints a highlight behind both.  (Classic monochrome
// G_ICON / ICONBLK is left for m68k-app compatibility, implemented separately.)
typedef struct { gfx_surface *img; const char *text; } CICON;

enum { OF_NONE=0x00, OF_SELECTABLE=0x01, OF_DEFAULT=0x02, OF_EXIT=0x04,
       OF_EDITABLE=0x08, OF_RBUTTON=0x10, OF_LASTOB=0x20, OF_TOUCHEXIT=0x40,
       OF_HIDETREE=0x80,
       OF_CANCEL=0x200,      // Esc fires this object (see form_keybd)
       OF_MOVEABLE=0x400 };  // on the tree ROOT: dialog is movable (fly corner + grab-inert)

enum { OS_NORMAL=0x00, OS_SELECTED=0x01, OS_CROSSED=0x02, OS_CHECKED=0x04,
       OS_DISABLED=0x08, OS_OUTLINED=0x10, OS_SHADOWED=0x20,
       // The WHITEBAK mnemonic convention (TOS/XaAES): OS_WHITEBAK set means
       // bits 8..14 of ob_state hold the index of the underlined shortcut
       // character in the object's label (bit 15 reserved).
       OS_WHITEBAK=0x40 };
#define WB_INDEX(state)   (((state) >> 8) & 0x7F)
#define WB_MAKE(idx)      ((uint16_t)(OS_WHITEBAK | (((idx) & 0x7F) << 8)))

// ob_type high byte (the "extended" byte the AES ignores): per-corner box
// rounding for the box types (G_BOX/G_IBOX/G_BOXCHAR/G_BOXTEXT).  Cosmetic — a
// plain loader draws square corners.  0xF0 = all four.  These match the shared
// GEM .rsc codec (fpga-gem/src/rsc.h, RSC-FORMAT.md §5), so RSC_OBJECT and our
// OBJECT are byte-identical and the codec's flag/type enums coincide with ours.
enum { BOX_ROUND_TL=0x10, BOX_ROUND_TR=0x20, BOX_ROUND_BR=0x40, BOX_ROUND_BL=0x80 };

// Editable text (G_FTEXT / G_FBOXTEXT ob_spec).  This is the EXACT classic /
// RSC_TEDINFO layout (fpga-gem/src/rsc.h) so a TEDINFO and an RSC_TEDINFO are
// byte-identical and the shared codec's ob_spec can be used directly.  The AES
// only reads te_ptext / te_ptmplt / te_pvalid / te_txtlen / te_just (the theme
// draws the field); te_font / te_fontid / te_color / te_fontsize / te_thickness
// / te_tmplen are the classic font/colour words — carried for byte-identity but
// inert in this AES.
typedef struct {
    char   *te_ptext;    // the editable text (caller's buffer)
    char   *te_ptmplt;   // display template, '_' = input position ("__:__"); NULL = free text
    char   *te_pvalid;   // one validation char per input position (last char extends):
                         //   '9' digits  'A' upper+space  'a' letters+space
                         //   'N' digit+upper+space  'n' alnum+space
                         //   'F'/'f' filename chars  'P'/'p' path chars
                         //   'X' anything  'x' anything, uppercased
    int16_t te_font, te_fontid;                    // classic font words (inert here)
    int16_t te_just;     // TE_LEFT / TE_RIGHT / TE_CNTR
    int16_t te_color, te_fontsize, te_thickness;   // classic colour/size/thickness (inert here)
    int16_t te_txtlen;   // sizeof buffer at te_ptext (incl. NUL)
    int16_t te_tmplen;   // template length incl. NUL (inert here)
} TEDINFO;
enum { TE_LEFT=0, TE_RIGHT=1, TE_CNTR=2 };

#define NIL (-1)

// Bind AES to a VDI workstation + theme (objc_draw/objc_find use them).
void aes_init(int vdi_handle, const theme *th);

// Absolute position of object `obj` in `tree` (walks from the root).
void objc_offset(OBJECT *tree, int obj, int *x, int *y);
// Draw `tree` from `start` down `depth` levels, clipped to (clx,cly,clw,clh).
void objc_draw(OBJECT *tree, int start, int depth, int clx, int cly, int clw, int clh);
// G_CICON label style: 1 = dark backdrop (desktop) -> white text, white-on-black
// selection; 0 = light window -> black text, black-on-white selection.  Set it
// before objc_draw for the container being drawn.
void aes_icon_label_style(int dark_bg);
// A ghosted (alpha-dimmed) copy of an icon surface for uncached network
// entries — pre-bake one per entry; the caller owns (and frees) the copy.
gfx_surface *icon_ghost(const gfx_surface *s);
// Topmost drawable object under (mx,my) within `depth` levels of `start`; -1 none.
int  objc_find(OBJECT *tree, int start, int depth, int mx, int my);

// ---- Events: the host source, the multiplexer, the message pipe ---------
// AES is event-driven by one host source: wait up to timeout_ms (-1 = forever)
// for the next input, fill ev (mx/my/button = the current pointer state), and
// return its type (AES_TIMER on timeout).  On the SDL testbed that's present +
// SDL_WaitEventTimeout; on hardware it's the AES event pump over the VDI input
// layer.  Everything else (form_do, evnt_multi) builds on this.
enum { AES_NONE=0, AES_BTN_DOWN=1, AES_BTN_UP=2, AES_KEY=3, AES_QUIT=4,
       AES_MOTION=5, AES_TIMER=6 };
typedef struct { int type, mx, my, button, key, shift; } aes_event;
typedef int (*aes_event_fn)(aes_event *ev, int timeout_ms);
void aes_set_events(aes_event_fn fn);
int  aes_wait(aes_event *ev, int timeout_ms);     // low level: calls the source

// aes_event.key: low byte = ASCII (0 if none), high byte = scancode for keys
// with no ASCII.  Scancodes use the Atari keyboard table (m68k-app compat):
enum { XK_UP=0x48, XK_DOWN=0x50, XK_LEFT=0x4B, XK_RIGHT=0x4D,
       XK_HOME=0x47, XK_DEL=0x53, XK_INS=0x52, XK_F1=0x3B /* ..F10=0x44 */ };
// aes_event.shift / evnt_multi kstate: classic Kbshift bits:
enum { K_RSHIFT=0x01, K_LSHIFT=0x02, K_CTRL=0x04, K_ALT=0x08, K_CAPS=0x10 };

// Central idle hook: every modal AES loop (form_do, dialog/window drags,
// future menus) waits at most period_ms and calls fn on timeout, so async
// work (the desktops' net_pump) stays alive inside modal interactions.
// NULL fn (or period_ms <= 0) disables it.
void aes_set_idle(void (*fn)(void), int period_ms);

// evnt_multi flags (+ MU_QUIT, our host extension for window close).
enum { MU_KEYBD=0x01, MU_BUTTON=0x02, MU_M1=0x04, MU_M2=0x08,
       MU_MESAG=0x10, MU_TIMER=0x20, MU_QUIT=0x40 };

// Wait on any of the requested event classes at once; returns the MU_* that
// fired.  Outputs (any may be NULL): mouse x/y, button mask, key, shift state,
// click count.  m1/m2 are enter(flag 0)/leave(flag 1) rectangle waits; mepbuf
// (>=8 words) receives a message for MU_MESAG; tlc/thc are the timer ms (lo/hi).
int  evnt_multi(int flags, int bclk, int bmask, int bstate,
                int m1f,int m1x,int m1y,int m1w,int m1h,
                int m2f,int m2x,int m2y,int m2w,int m2h,
                int16_t *mepbuf, int tlc, int thc,
                int *mx,int *my,int *mbut,int *kstate,int *key,int *nclk);
int  evnt_keybd(void);                            // -> key
int  evnt_button(int clicks,int mask,int state,int*mx,int*my,int*mbut,int*kstate);
int  evnt_mouse(int leave,int x,int y,int w,int h,int*mx,int*my,int*mbut,int*kstate);
int  evnt_mesag(int16_t *mepbuf);
int  evnt_timer(int lo_ms,int hi_ms);

// Minimal application / message pipe: appl_write posts, evnt_mesag reads.
int  appl_init(void);                             // -> ap_id
void appl_exit(void);
void appl_write(int dest_id, int len, const void *msg);
int  appl_read(int id, int len, void *buf);

// Run a modal form: push buttons flash while held + trigger on release-inside,
// checkboxes toggle, radio buttons exclude their siblings.  Keyboard: Return
// fires the DEFAULT button; Esc clears the focused edit field, then fires the
// OF_CANCEL object; TAB / Shift-TAB cycle focus over OF_EDITABLE objects;
// mnemonic letters (WHITEBAK, auto-assigned on entry) act as clicks.  A root
// with OF_MOVEABLE is draggable by its fly corner or any inert area.
// `start` = the initial edit object (0 = first editable, -1 = none).
// Returns the EXIT/TOUCHEXIT object clicked (-1 = quit).
int  form_do(OBJECT *tree, int start);

// Centre `tree` on the work area, save what's underneath, run form_do, and
// restore.  The standard way to run a dialog (form_alert uses it too).
int  form_do_dialog(OBJECT *tree, int start);

// The full form key policy (Return / Esc / TAB / mnemonics / ED_CHAR) as one
// call, for bare evnt_multi clients that host editable objects themselves.
// edobj = the focused editable (-1 none); *new_edobj (may be NULL) receives
// the focus after the key.  Returns the exit object fired, or -1 (keep going).
int  form_keybd(OBJECT *tree, int edobj, int key, int kstate, int *new_edobj);

// The edit engine behind OF_EDITABLE (classic entry points): ED_INIT focuses
// the field + shows the caret (idx = caret position, -1 = end), ED_CHAR
// processes one aes_event key (insert / Backspace / Del / arrows / Ctrl-U
// clear; returns 1 if consumed; redraws + flushes the field), ED_END drops
// focus.  idx carries the caret in/out (may be NULL).
enum { ED_START=0, ED_INIT=1, ED_CHAR=2, ED_END=3 };
int  objc_edit(OBJECT *tree, int obj, int key, int *idx, int kind);

// Canned alert: alert = "[icon][message|with|lines][button1|button2|button3]"
// (icon 0 none, 1 note, 2 wait, 3 stop).  Builds + centres + runs the dialog,
// saving/restoring what's underneath; returns the 1-based button clicked.
int  form_alert(int default_button, const char *alert);

// ---- Menus --------------------------------------------------------------
// A menu is a GEM OBJECT tree (bar of G_TITLEs + a dropdown G_BOX of G_STRINGs
// per title).  menu_build assembles one from a simple description; menu_bar
// shows/hides it.  A selection posts an MN_SELECTED message (msg[0]=MN_SELECTED,
// msg[3]=title object, msg[4]=item object) read via evnt_mesag — the bar click
// is intercepted inside evnt_multi, so apps just receive the message.
enum { MN_SELECTED = 10 };

typedef struct { const char *title; const char **items; int nitems; } menu_def;
OBJECT *menu_build(const menu_def *menus, int nmenus, int screen_w);   // malloc'd tree
void    menu_bar(OBJECT *tree, int show);          // show/erase the active menu bar
void    menu_tnormal(OBJECT *tree, int title, int normal);   // (un)highlight a title
void    menu_icheck(OBJECT *tree, int item, int check);      // tick / untick an item
void    menu_ienable(OBJECT *tree, int item, int enable);    // enable / disable an item

// ---- Popup / context menus (menu_popup) ---------------------------------
// A generic run-a-popup: a flat array of menu_item rows drawn as a themed box
// at (x,y), tracked modally (hover highlights, cascades open to the right),
// returning the chosen leaf's id (or -1 on cancel).  Used for the desktop's
// right-click context menu and the browse navigator, and to back G_POPUP combo
// fields in dialogs.  (The classic AES menu_popup(MENU*,...) tree shape is not
// copied — this is the flat-array form; an m68k shim can wrap it.)
typedef struct menu_item {
    const char *label;               // "-" = separator (a divider, non-selectable)
    const char *accel;               // e.g. "^N", drawn right-aligned in grey; NULL = none
    int         id;                  // returned when this leaf is chosen
    const struct menu_item *sub;     // non-NULL = cascading submenu (opens to the right)
    int         nsub;                // submenu item count
    unsigned    flags;               // MI_DISABLED | MI_CHECKED | MI_LAZY (bit flags)
} menu_item;
// MI_LAZY: this row's children are produced on demand (see menu_popup_dyn); the
// row draws a submenu triangle even though `sub` is NULL, and its `id` doubles
// as the opaque key handed to the provider (so a lazy row also carries an id).
enum { MI_DISABLED = 1, MI_CHECKED = 2, MI_LAZY = 4 };

// Run a modal popup at (x,y) (clamped fully on-screen).  Mouse hover highlights
// rows, moving onto a submenu item cascades right (flipping left near the edge),
// click/Enter on a leaf returns its id, click-outside/Esc returns -1.  Keyboard:
// up/down move (skipping separators/disabled), right/left open/close a cascade,
// a first-letter mnemonic jumps/selects.  Waits through aes_wait_idle so the
// desktop's idle hook (net_pump) keeps running.  Restores all pixels on exit.
int menu_popup(const menu_item *items, int n, int x, int y);

// Lazy/dynamic variant of menu_popup: the `root` array is shown immediately, but
// any row flagged MI_LAZY has its children produced ON DEMAND the first time it
// opens (hover / right-arrow / click-with-no-id), by calling
//     expand(ctx, item->id, &children, &nchildren)
// which returns nonzero on success and hands back a submenu the popup then owns:
// the provider malloc's ONE block holding the menu_item[] AND its label strings
// (labels alias into that block), and menu_popup_dyn free()s the block when the
// submenu closes or the popup exits.  Children may themselves be MI_LAZY, so a
// whole tree cascades without being read up front.  Cap each level yourself (a
// trailing disabled "(more…)" row is the convention).  Selection returns the
// chosen leaf's id as usual; an MI_LAZY row with a NONZERO id returns that id
// when clicked (while still cascading on hover), so e.g. a directory row can
// both open-on-click and expand-on-hover.  The `root` array is caller-owned
// (never freed here).  expand may be NULL (then MI_LAZY rows just never open).
typedef int (*menu_provider)(void *ctx, int dynid, menu_item **out_items, int *out_n);
int menu_popup_dyn(const menu_item *root, int n, int x, int y, menu_provider expand, void *ctx);

// Geometry + navigation, factored out so the layout / hit-test / keyboard nav
// are unit-testable without driving the modal loop headlessly.
typedef struct { int x, y, w, h, rowh, seph, pady, labelx, n; } popup_geom;
// Size the box for `items` and clamp its origin on-screen; fills `g`.
void menu_popup_layout(const menu_item *items, int n, int x, int y, popup_geom *g);
// Row index at (mx,my), or -1 (outside, or a separator / disabled row).
int  menu_popup_hit(const popup_geom *g, const menu_item *items, int mx, int my);
// Next selectable row from `cur` in direction dir (+1 down / -1 up), wrapping,
// skipping separators + disabled items; -1 if none.  cur < 0 starts at an edge.
int  menu_popup_nav(const menu_item *items, int n, int cur, int dir);
// Row whose auto-assigned first-letter mnemonic matches `ch` (case-insensitive),
// skipping separators / disabled; -1 if none.
int  menu_popup_mnemonic(const menu_item *items, int n, int ch);

// ---- Windows ------------------------------------------------------------
// Themed windows over the AES.  The frame (9-slice window + titlebar + traffic
// lights) is drawn by the AES; the app draws the work area through a content
// callback (wind_content) and reacts to WM_* messages from evnt_mesag.  Frame
// interaction (drag, resize, close box, raise) is caught inside evnt_multi.
enum { W_NAME=0x01, W_CLOSER=0x02, W_FULLER=0x04, W_MOVER=0x08, W_INFO=0x10,
       W_SIZER=0x20, W_UPARROW=0x40, W_DNARROW=0x80, W_VSLIDE=0x100,
       W_LFARROW=0x200, W_RTARROW=0x400, W_HSLIDE=0x800 };
enum { WM_REDRAW=20, WM_TOPPED=21, WM_CLOSED=22, WM_FULLED=23, WM_ARROWED=24,
       WM_HSLID=25, WM_VSLID=26, WM_SIZED=27, WM_MOVED=28, WM_NEWTOP=29 };

/* ---- XTOS_*: XTOS system-event messages (OS/AES -> apps) ------------------
 * A reserved range for events that classic GEM has no message for — the OS
 * telling apps about hardware/system state. Delivered like any AES message
 * (evnt_multi MU_MESAG -> msg[8]); apps switch(msg[0]) and ignore unknown ones.
 * Named XTOS_ to match the bare classic messages (WM_/AC_/MN_). Kept well clear
 * of classic (10..63) at 0x4000..0x7FFF (positive int16_t), leaving ~16k types.
 * Convention as usual: msg[0]=type, msg[1]=sender ap_id (0 = system),
 * msg[2]=extra bytes, msg[3..]=payload. */
enum {
    XTOS_BASE          = 0x4000,
    /* SD / removable media inserted or removed.
     *   msg[3] = present (1 = inserted/ready, 0 = removed)
     *   msg[4] = volume index (0 = the SD card)
     * Apps may grey out / close windows backed by that volume. */
    XTOS_MEDIA_CHANGE  = XTOS_BASE + 0x000,
    /* 0x4001.. reserved for future XTOS system events */
    XTOS_LAST          = 0x7FFF
};
enum { WF_NAME=2, WF_WORKXYWH=4, WF_CURRXYWH=5, WF_PREVXYWH=6, WF_FULLXYWH=7 };
enum { WC_BORDER=0, WC_WORK=1 };                    // wind_calc direction

typedef void (*wind_draw_fn)(int handle, int wx, int wy, int ww, int wh, void *ud);

#define AES_INFO_H 24     // height of the W_INFO chrome line (under the title bar)

int  wind_create(int kind, int x, int y, int w, int h);   // -> handle (0 = none)
void wind_open(int handle, int x, int y, int w, int h);
void wind_close(int handle);
void wind_delete(int handle);
void wind_set_name(int handle, const char *name);
void wind_get(int handle, int field, int *a, int *b, int *c, int *d);
void wind_set(int handle, int field, int a, int b, int c, int d);
void wind_calc(int dir, int kind, int x,int y,int w,int h, int *ox,int *oy,int *ow,int *oh);
int  wind_find(int x, int y);                       // topmost window at point (0 = desktop)
int  wind_top(void);                                // topmost open window (0 = none)
void wind_raise(int handle);                        // bring an open window to the top
void wind_content(int handle, wind_draw_fn fn, void *ud);
// Optional W_INFO chrome line under the title bar (full inner width, like the
// title): fn draws its contents (count/path/toolbar); the work area shrinks by
// AES_INFO_H.  Only used when the window was created with W_INFO.
void wind_info(int handle, wind_draw_fn fn, void *ud);
void wind_set_desktop(uint32_t rgba);               // desktop background colour
// Optional desktop-content drawer — invoked by wind_redraw after the background
// fill and before any windows, so a wallpaper + desktop icons draw under every
// window.  Called as fn(0, x,y,w,h, ud) over the whole screen.  NULL clears it.
void wind_set_desktop_content(wind_draw_fn fn, void *ud);
void wind_redraw(void);                             // redraw desktop + all windows (AES owns it)
// Optional HW drag-overlay hooks (A9): title-bar drag lifts the window into the
// overlay plane and moves it by register write (no redraw). NULL -> classic drag.
void wind_set_overlay(int(*begin)(int,int,int,int), void(*move)(int,int),
                      void(*end)(void), void(*present)(int,int,int,int));
// Push a just-drawn screen rect through the overlay present hook (visibility
// for modal draws outside wind_redraw); no-op when no hook is registered.
void aes_label_fit(int vh, const char *text, int maxw, char *out, int cap);
void aes_flush_rect(int x, int y, int w, int h);
// The desktop work area windows are clamped to (so a window can't be dragged out
// of reach).  Defaults to the screen minus the menu bar; Desktop.app can reserve
// more (dock/sidebar).  wind_get(0, WF_WORKXYWH, …) reports it.
void aes_set_workarea(int x, int y, int w, int h);

#endif // GEM_AES_H
