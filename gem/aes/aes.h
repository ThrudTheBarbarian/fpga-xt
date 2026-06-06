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
       // our themed extensions (checkbox / radio / popup), drawn via the theme
       G_CHECKBOX=40, G_RADIO=41, G_POPUP=42, G_FIELD=43 };

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

#endif // GEM_AES_H
