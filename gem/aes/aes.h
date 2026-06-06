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

#endif // GEM_AES_H
