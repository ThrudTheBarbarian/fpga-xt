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
       G_CHECKBOX=40, G_RADIO=41, G_POPUP=42, G_FIELD=43, G_CICON=44,
       G_SCROLL=45, G_SLIDER=46 };

// ob_spec for G_SCROLL — a themed scrollbar (track + sized thumb + arrows), and for
// G_SLIDER — a themed value slider (track + knob).  They are different widgets: a
// scrollbar's thumb has a SIZE (how much of the content is visible), a slider's knob
// does not.  The theme carries art for both (vscroll./hscroll. vs slider.).
//
// value/page are PERMILLE (0..1000), so an object is resolution-independent and the
// AES needs no floating point.  The AES only DRAWS these; dragging the thumb is the
// caller's job (objc_find gives it the hit, and it writes back value).
typedef struct {
    int16_t vert;     // 1 = vertical, 0 = horizontal
    int16_t value;    // 0..1000 — thumb position within the track
    int16_t page;     // 1..1000 — G_SCROLL only: thumb size as a fraction of the track
    int16_t arrows;   // 1 = draw the end arrows (G_SCROLL only)
} SCROLLBAR;

// Map a pixel position inside a G_SCROLL / G_SLIDER object to a value (0..1000),
// centring the thumb on the cursor.  The AES already knows the track geometry (arrow
// caps, thumb size); without this every caller would re-derive it and get it subtly
// wrong.  The caller writes the result back into the SCROLLBAR and redraws — the AES
// draws, the toolkit interacts.
int16_t objc_scroll_value(OBJECT *t, int obj, int mx, int my);

// The SCROLLBAR behind a G_SCROLL / G_SLIDER object (NULL for any other type).  Saves
// callers casting ob_spec by hand, and — because it names the type in an exported
// signature — it is what lets a DWARF-importing language (xtc) SEE the type at all.
SCROLLBAR *objc_scrollbar(OBJECT *t, int obj);

// ob_spec for G_CICON — our colour desktop/file icon: a pre-scaled RGBA bitmap
// blitted src-over, centred at the top of the object rect, with `text` centred
// beneath it.  OS_SELECTED paints a highlight behind both.  (Classic monochrome
// G_ICON / ICONBLK is left for m68k-app compatibility, implemented separately.)
typedef struct { gfx_surface *img; const char *text; } CICON;

enum { OF_NONE=0x00, OF_SELECTABLE=0x01, OF_DEFAULT=0x02, OF_EXIT=0x04,
       OF_EDITABLE=0x08, OF_RBUTTON=0x10, OF_LASTOB=0x20, OF_TOUCHEXIT=0x40,
       OF_HIDETREE=0x80,
       OF_CANCEL=0x200,      // Esc fires this object (see form_keybd)
       OF_MOVEABLE=0x400,    // on the tree ROOT: dialog is movable (fly corner + grab-inert)
       // Clip this object's SUBTREE to its own rect.  Without it a child can draw
       // outside its parent (objc_draw sets the clip once, for the whole walk), which
       // makes a scrolling container impossible: the partially-scrolled row at the
       // edge paints over whatever sits next to it.  NSView clips subviews to bounds
       // by default; this is that, opt-in so existing resources are untouched.
       // 0x1000 deliberately clears every classic-GEM flag (OF_INDIRECT=0x100,
       // OF_FL3DIND=0x200, OF_FL3DBAK=0x400, OF_SUBMENU=0x800) — Rocks imports real
       // .rsc files and must not collide with them.
       OF_CLIPCHILDREN=0x1000 };

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

// The workstation the AES draws through. A wind_content callback draws through THIS: under gemd
// it is bound to the app's own backing store, and the app has no other workstation to reach for
// (it has no screen). Locally it is whatever the app passed to aes_init. Same callback, both.
int aes_handle(void);

// One library, two modes (RESPONSIBILITIES.md §5). The mode is decided in appl_init(), NOT
// here: aes_init merely binds a workstation and every app calls it (gemd included), so it
// cannot be the thing that decides who is the server.
//   LOCAL   single-process GEM. Unchanged, and what the SDL host always is.
//   CLIENT  an app under gemd. wind_* become messages; the app never learns.
//   SERVER  gemd itself: the window list, the z-order and the chrome are ITS.
enum { AES_LOCAL = 0, AES_CLIENT = 1, AES_SERVER = 2 };
int  aes_mode(void);
void aes_server_mode(void);       // gemd, and only gemd, calls this

// How long appl_init() waits for the "gem" service before giving up — and on XTOS giving up is
// FATAL (there is no single-process mode to fall back to). A program started ALONGSIDE gemd (the
// desktop, out of 99-Desktop) races it at boot and raises this so it cannot lose that race.
void gem_connect_set_wait(int ms);

// CLIENT: which of OUR windows the last input event was delivered to (0 = none/not a client).
// A client cannot deduce it — event coordinates are window-LOCAL, so every window sees a click
// at (10,10) — and it must not try: wind_find() needs a z-order and a geometry, and a client is
// entitled to neither. gemd hit-tested it and says so on the wire.
int  aes_event_win(void);

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
// ---- Live object-tree edits (classic AES; pure child-chain relinking) --------
// objc_add appends `obj` (caller-sized/placed) as parent's LAST child; objc_delete
// unlinks it (frees nothing); objc_order moves it among its siblings (0 = first /
// bottom, >= child-count = last / top).  The object array + OF_LASTOB are the
// caller's to manage.
void objc_add(OBJECT *tree, int parent, int obj);
void objc_delete(OBJECT *tree, int obj);
void objc_order(OBJECT *tree, int obj, int pos);
// USERDEF draw seam — one registered callback (like form_set_hook), invoked for
// each G_USERDEF object inside objc_draw.  Get the rect via objc_offset + ob_w/h,
// draw through aes_handle().  Return value is currently ignored.
typedef int (*objc_userdraw_fn)(OBJECT *tree, int obj, void *ud);
void objc_set_userdraw(objc_userdraw_fn fn, void *ud);

// ---- Events: the host source, the multiplexer, the message pipe ---------
// AES is event-driven by one host source: wait up to timeout_ms (-1 = forever)
// for the next input, fill ev (mx/my/button = the current pointer state), and
// return its type (AES_TIMER on timeout).  On the SDL testbed that's present +
// SDL_WaitEventTimeout; on hardware it's the AES event pump over the VDI input
// layer.  Everything else (form_do, evnt_multi) builds on this.
enum { AES_NONE=0, AES_BTN_DOWN=1, AES_BTN_UP=2, AES_KEY=3, AES_QUIT=4,
       AES_MOTION=5, AES_TIMER=6, AES_WHEEL=7,
       // AES_MESAG: the source queued an AES MESSAGE (appl_write) rather than an input event —
       // under gemd, WM_CLOSED/WM_MOVED/WM_SIZED arrive on the same channel as the input does.
       // evnt_multi must then LOOK IN THE PIPE; returning AES_TIMER instead would send it back
       // to sleep with the message still sitting there.
       AES_MESAG=8 };
// wheel: signed notch count for AES_WHEEL (>0 = away from the user / scroll up),
// with mx/my at the current pointer.  The host source (SDL) fills it from
// SDL_MOUSEWHEEL; the A9 kernel input layer has no wheel yet, so it stays 0
// there (scrollbar drag / arrows / page still work) — see wind_handle_wheel.
typedef struct { int type, mx, my, button, key, shift, wheel; } aes_event;
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

// Optional hook for dialogs with dependent widgets (a radio that shows/hides a
// popup, a G_POPUP combo whose menu is app-supplied): form_do calls it after a
// G_RADIO selection changes, or when a G_POPUP is clicked (obj = that object),
// so the app can toggle OF_HIDETREE on the dependents, or open the popup's
// linked menu and set its ob_spec.  Returns nonzero to request a redraw (form_do
// redraws regardless — the return is advisory).  ud is passed through; NULL fn
// clears it.  form.c stays resource-agnostic: the app maps obj -> effect.
typedef int (*form_hook_fn)(OBJECT *tree, int obj, void *ud);
void form_set_hook(form_hook_fn fn, void *ud);

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
// msg[3]=title object index, msg[4]=item object index) read via evnt_mesag — the
// bar click is intercepted inside evnt_multi, so apps just receive the message.
// Decode it as: title ordinal = msg[3]-2; item ordinal = menu_item_ord(tree,
// title_ord, msg[4]).  Separators never fire (they are non-selectable).
enum { MN_SELECTED = 10 };

// Bar-dropdown item encoding (the menu_def `items[]` strings): a leading marker
// byte, stripped before drawing, sets a row's initial kind/state.
//   MENU_SEP        -> a separator: a non-selectable divider line
//   MENU_CHECK(s)   -> row `s`, pre-ticked (toggle later with menu_icheck)
//   MENU_DISABLE(s) -> row `s`, greyed + non-selectable (menu_ienable re-enables)
// A plain string is an ordinary selectable item.  (The check/disable helpers below
// address rows by title/item ORDINAL, so state can be reflected after build.)
#define MENU_SEP          "-"
#define MENU_CHECK(s)     "\x01" s
#define MENU_DISABLE(s)   "\x02" s

typedef struct { const char *title; const char **items; int nitems; } menu_def;
OBJECT *menu_build(const menu_def *menus, int nmenus, int screen_w);   // malloc'd tree
void    menu_bar(OBJECT *tree, int show);          // show/erase the active menu bar
void    menu_tnormal(OBJECT *tree, int title_ord, int normal);          // (un)highlight a title (by ordinal)
void    menu_icheck(OBJECT *tree, int title_ord, int item_ord, int on); // tick / untick an item (by ordinal)
void    menu_ienable(OBJECT *tree, int title_ord, int item_ord, int on);// enable / disable an item (by ordinal)
int     menu_item_ord(OBJECT *tree, int title_ord, int item_obj);       // item object index -> ordinal (-1 none)

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
       W_LFARROW=0x200, W_RTARROW=0x400, W_HSLIDE=0x800,

       // W_BOTTOM — the entire cost of "the desktop is an ordinary app" (§4). It means TWO
       // things, and it needs both:
       //
       //   1. INSERT AT THE BOTTOM of the z-order, whenever the window is created.
       //   2. NEVER TOPPED by a click.
       //
       // (2) alone is not enough, and (1) is not free. It is tempting to say the desktop is
       // simply the first app launched, so it is at the bottom because new windows go on top —
       // no flag needed. THAT IS TRUE AT BOOT AND FALSE EVER AFTER. Restart the desktop while
       // apps are running — which §4 explicitly promises works, and which is exactly what you
       // do WHEN SOMETHING HAS ALREADY GONE WRONG — and its new screen-sized window is created
       // LAST. Without (1) it lands on TOP and swallows the entire session: every app
       // invisible, the machine apparently dead. Creation order is luck, not design.
       //
       // It is W_BOTTOM and not W_ROOT deliberately: it names a Z-ORDER POSITION, which is the
       // only thing gemd should understand. W_ROOT would smuggle a ROLE into the server, and
       // the whole argument of §4 is that gemd must not know what a desktop is. Nothing stops
       // two clients setting it; they simply stack at the bottom among themselves, and gemd
       // neither knows nor cares which of them is "the desktop".
       W_BOTTOM=0x1000 };
enum { WM_REDRAW=20, WM_TOPPED=21, WM_CLOSED=22, WM_FULLED=23, WM_ARROWED=24,
       WM_HSLID=25, WM_VSLID=26, WM_SIZED=27, WM_MOVED=28, WM_NEWTOP=29,
       WM_UNTOPPED=30,     // focus LOST (gemd's MSG_ACTIVATE 0; classic GEM has it too)
       // A right-side title button was pressed: msg[4] = its index (0 = leftmost).
       // Chrome routes input, so a title-button press is a MESSAGE — the same shape as
       // WM_CLOSED — and never an app-side hit-test against a rect it had to ask for
       // (RESPONSIBILITIES.md §11: "if a client has to DRAW it, it is not chrome").
       WM_TBUTTON=31,
       // A SEGMENT OF THE TITLE PATH was clicked: msg[4] = its index in the path the app set
       // (0 = the first component).  The app never drew the path and is never told where any of
       // it is — it set a string and gets back an index into that same string (§11).
       WM_PATHSEG=32 };

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
// wind_get / wind_set fields.  Classic numbers, so an m68k app binds directly.
enum { WF_KIND=1, WF_NAME=2, WF_INFO=3, WF_WORKXYWH=4, WF_CURRXYWH=5,
       WF_PREVXYWH=6, WF_FULLXYWH=7, WF_TOP=10,
       // ---- our extensions.  Numbered clear of the classic range. -----------
       WF_SUBTITLE=32,     // a second line / path, drawn smaller after the name
       WF_ICON=33,         // a THEME SLICE NAME: the proxy/document icon ("" = none)
       WF_TITLEFLAGS=34,   // WT_* below
       WF_TITLEBTNS=35,    // (a,b) = glyph array ptr; c = count
       // The scroll MODEL (M5).  Set through wind_content_size / wind_set_scroll — these are
       // their wire names, not a second app API.  Under gemd the scrollbar is CHROME: gemd
       // draws it, runs its interaction, and clamps a scroll request exactly as it clamps a
       // rect; the app hears WM_VSLID and repaints anything it pins (a status bar).
       WF_CONTENTSIZE=36,  // full content extent, work coords
       WF_SCROLL=37 };     // scroll offset — a REQUEST: gemd clamps and answers with the truth
enum { WT_MODIFIED = 0x01,     // WF_TITLEFLAGS: show the unsaved-changes dot
       // THE SUBTITLE IS A PATH.  The AES draws it as "/a/b/c" with each component its own
       // clickable span (middle-eliding at COMPONENT granularity when it will not fit), and a
       // click comes back as WM_PATHSEG(index).  This is what a breadcrumb becomes once chrome
       // is declarative: the app owns the STRING, the AES owns the drawing and the hit-testing,
       // and the only thing that crosses is an index.  A wedged app's breadcrumb still paints.
       WT_PATH     = 0x02 };

// ---- POINTER FIELDS: the classic hi/lo split -----------------------------------
// WF_NAME / WF_INFO / WF_SUBTITLE / WF_ICON / WF_TITLEBTNS carry a POINTER, and GEM
// has always passed one as two 16-bit halves (a = high, b = low) because the AES was
// born on a 16-bit machine.  We keep that: an m68k app must be able to call
// wind_set(h, WF_NAME, hi, lo, 0, 0) and have it work.
//
// Native callers use these.
//
// ⚠ THE SPLIT IS 16+16 ONLY WHERE A POINTER IS 32 BITS.  That is every TARGET (A9, m68k), and
// there the halves are exactly classic GEM's, so an m68k app binds directly — which is the whole
// point of keeping the split.  The SDL host is 64-bit, and a 64-bit pointer DOES NOT FIT in two
// 16-bit halves: packing it into 16+16 silently truncates it to its low 32 bits, and the AES then
// runs strlen() on an address that was never a string.  (It did.  wind_set_name went through
// wind_set the moment the chrome model landed, and the host build has been reading a truncated
// pointer ever since — "built, not run".)
//
// So the halves are pointer-WIDTH halves: 16+16 on the targets (the classic ABI, unchanged, and
// what the m68k track needs), 32+32 on a 64-bit dev host.  Nothing crosses the wire this way in
// either case — gemd is sent the BYTES (see gemproto.h); this split is a local C ABI and nothing
// more.
#if UINTPTR_MAX > 0xFFFFFFFFu
#define WIND_PTR_HI(p)  ((int)(uint32_t)(((uintptr_t)(p)) >> 32))
#define WIND_PTR_LO(p)  ((int)(uint32_t)( ((uintptr_t)(p)) & 0xFFFFFFFFu))
#define WIND_PTR(a,b)   ((void *)((((uintptr_t)(uint32_t)(a)) << 32) | (uintptr_t)(uint32_t)(b)))
#else
#define WIND_PTR_HI(p)  ((int)((((uintptr_t)(p)) >> 16) & 0xFFFF))
#define WIND_PTR_LO(p)  ((int)( ((uintptr_t)(p))        & 0xFFFF))
#define WIND_PTR(a,b)   ((void *)(uintptr_t)((((uint32_t)(a) & 0xFFFFu) << 16) | \
                                              ((uint32_t)(b) & 0xFFFFu)))
#endif
//
// NOTE FOR THE SPLIT: the pointer is a CLIENT-SIDE ABI detail and nothing more.  The
// AES *copies* every string it is given (it always has — see wind_set_name), so in the
// client/server world the client-side wind_set reassembles the pointer, reads the
// bytes, and sends THE BYTES to gemd.  A pointer means nothing across a process
// boundary; a buffer of characters means the same thing everywhere.
enum { WC_BORDER=0, WC_WORK=1 };                    // wind_calc direction

typedef void (*wind_draw_fn)(int handle, int wx, int wy, int ww, int wh, void *ud);

#define AES_INFO_H 24     // height of the W_INFO chrome line (a footer at the window bottom)
#define AES_MENUBAR_H 22  // height of the menu bar strip (menu.c draws it; gemd RESERVES it at
                          // startup even before the menu strip exists, so the fuller and the
                          // clamps never put a window where the bar is going to be)

int  wind_create(int kind, int x, int y, int w, int h);   // -> handle (0 = none)
void wind_open(int handle, int x, int y, int w, int h);
void wind_close(int handle);
void wind_delete(int handle);
// DEPRECATED — use wind_set(handle, WF_NAME, WIND_PTR_HI(s), WIND_PTR_LO(s), 0, 0).
// This wrapper existed before wind_set implemented WF_NAME, and its existence is why
// nobody noticed that it did not: everything in our own tree took the sugared path, so
// the COMPATIBLE path was never exercised and a classic app's title silently did
// nothing.  Kept only so existing callers keep building.
void wind_set_name(int handle, const char *name);
void wind_get(int handle, int field, int *a, int *b, int *c, int *d);
void wind_set(int handle, int field, int a, int b, int c, int d);
// Read a chrome string field back (WF_NAME / WF_INFO / WF_SUBTITLE / WF_ICON), hi/lo split.
// It returns the AES'S OWN COPY — the model it will actually draw, not the pointer you passed —
// so a caller gets a stable string it did not have to keep alive.  1 = field read, 0 = not a
// string field.  (It was defined and never declared: nobody could call it.)
int  wind_get_str(int handle, int field, int *a, int *b);
void wind_calc(int dir, int kind, int x,int y,int w,int h, int *ox,int *oy,int *ow,int *oh);
// Does this kind mask ask for ANY chrome? A window with none gets none — no frame, no title bar
// — and its work area IS its full rect. That is the whole mechanism behind §4's "the desktop is
// an ordinary client": a full-screen W_BOTTOM window with nothing drawn around it.
int  wind_has_chrome(int kind);
int  wind_find(int x, int y);                       // topmost window at point (0 = desktop)
int  wind_top(void);                                // topmost open window (0 = none)
void wind_raise(int handle);                        // bring an open window to the top
void wind_content(int handle, wind_draw_fn fn, void *ud);
// ---- Scrolling ----------------------------------------------------------
// The AES owns a vertical scrollbar per window.  The app reports its full
// content size (in the CURRENT work-area coordinate system); when content_h
// exceeds the work-area height, the AES draws a themed scrollbar in the right
// border and SHRINKS the work area (WF_WORKXYWH / the content callback's ww)
// by the bar's width, so the content reflows into the narrower span and
// objc_draw clips to it.  The app draws its content translated by -scroll_y
// (read wind_scroll_y) and adds scroll_y back into any click Y it hit-tests.
// Frame interaction (thumb drag, arrow step, track page) is caught inside
// evnt_multi; a mouse wheel over a scrollable window scrolls it too.  Scroll
// is clamped to [0, content-work] whenever content or the window size changes;
// the bar hides when the content fits.  content_w/scroll_x are tracked for a
// future horizontal bar (only the vertical bar is drawn today).
void wind_content_size(int handle, int w, int h);   // report full content size
int  wind_scroll_y(int handle);                      // current vertical offset
int  wind_scroll_x(int handle);                      // current horizontal offset
void wind_set_scroll(int handle, int x, int y);      // set (clamped) scroll
// A wheel notch over the window at (mx,my): scroll a scrollable window and
// redraw.  Returns 1 if consumed.  Called by evnt_multi on AES_WHEEL.
int  wind_handle_wheel(int mx, int my, int delta);
// ---- CHROME IS DECLARATIVE (§11) ----------------------------------------
// There is no title-draw callback, no info-draw callback, and no way to ask where
// a chrome control is: the AES draws chrome from its MODEL (WF_NAME / WF_SUBTITLE /
// WF_ICON / WF_TITLEFLAGS / WF_INFO / WF_TITLEBTNS, all set through wind_set), and
// it routes chrome input itself.  That is what lets gemd repaint the title bar of
// a WEDGED app — the model is gemd's, so no client is involved — and it is what
// keeps a drag from costing a client round-trip per frame.
//
// Anything that needs arbitrary drawing is CONTENT, and content goes in the work
// area (a breadcrumb bar, a status bar, a toolbar): the client draws it into its
// own backing store, hit-tests it in its own coordinates, and it costs gemd nothing.
//
// ---- App-defined right-side title buttons -------------------------------
// A window may register up to WIND_MAXTB small icon buttons at the RIGHT of its
// title bar, drawn in the same size/inset as the left close/full boxes so they read
// as a pair.  Each carries a vector glyph (WTG_*).  Declarative: a list of glyph
// ids in, and a press comes back as WM_TBUTTON(msg[4] = index) — the app never
// learns (and must never need) a screen rect.
enum { WTG_NONE = 0, WTG_CHEVRON = 1, WTG_EXPAND = 2 };   // title-button glyphs
#define WIND_MAXTB 3
#define WIND_MAXSEG 16   // WT_PATH: most path components the AES will lay out as crumbs
// DEPRECATED sugar over wind_set(handle, WF_TITLEBTNS, hi, lo, n, 0) — implemented
// THROUGH it, like wind_set_name.
void wind_titlebtns(int handle, const int *glyphs, int n);
// The W_INFO footer is a STRING: wind_set(handle, WF_INFO, hi, lo, 0, 0).  The work
// area shrinks by AES_INFO_H off the bottom; when the window is also W_SIZER, resize
// grips occupy both ends of the footer band.
void wind_set_desktop(uint32_t rgba);               // desktop background colour
// Optional desktop-content drawer — invoked by wind_redraw after the background
// fill and before any windows, so a wallpaper + desktop icons draw under every
// window.  Called as fn(0, x,y,w,h, ud) over the whole screen.  NULL clears it.
void wind_set_desktop_content(wind_draw_fn fn, void *ud);
int  aes_top_reserve(void);                         // px reserved at the top (menu bar) — offset desktop icons below it
void wind_redraw(void);                             // full-screen redraw (desktop + all windows)
void wind_redraw_area(int x, int y, int w, int h);  // repaint only this damage rect (bg+wallpaper+windows+bar, clipped + presented)
void wind_redraw_win(int handle);                   // repaint just one window's rect (the "only this window changed" case)
// Declare a non-scrolling strip at the work-area BOTTOM (a status bar drawn as content).
// Under gemd the scroll consequence shifts the backing store with a blit; without this the
// blit drags a stale copy of the pinned strip up through the content.
void wind_pin_bottom(int handle, int px);
// THE DIRTY-RECT TOOL: repaint one RECT of one window's content, in the SAME coordinate
// space the content callback draws in (client: surface coords; local: screen coords — i.e.
// whatever you measured your widgets in when you drew them).  Use it when a ROW changed, a
// selection toggled, a status bar ticked: wind_redraw_win for a one-line change renders the
// whole surface and makes gemd recomposite all of it.
void wind_redraw_rect(int handle, int x, int y, int w, int h);
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
