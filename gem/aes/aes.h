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
       OF_HIDETREE=0x80 };

enum { OS_NORMAL=0x00, OS_SELECTED=0x01, OS_CROSSED=0x02, OS_CHECKED=0x04,
       OS_DISABLED=0x08, OS_OUTLINED=0x10, OS_SHADOWED=0x20 };

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
// checkboxes toggle, radio buttons exclude their siblings, Return fires the
// DEFAULT button; returns the EXIT/TOUCHEXIT object clicked (-1 = quit).
int  form_do(OBJECT *tree, int start);

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
// The desktop work area windows are clamped to (so a window can't be dragged out
// of reach).  Defaults to the screen minus the menu bar; Desktop.app can reserve
// more (dock/sidebar).  wind_get(0, WF_WORKXYWH, …) reports it.
void aes_set_workarea(int x, int y, int w, int h);

#endif // GEM_AES_H
