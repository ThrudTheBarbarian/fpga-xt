// tools/mkrsc.c — author gem/resources/desktop.rsc with the SHARED GEM .rsc
// engine (../fpga-gem/src/rsc.c), the same reader/writer the GemRCS editor uses.
//
// Builds a handful of minimal-but-valid GEM trees in memory through the engine's
// builder API (rsc_new / rsc_alloc_objects / rsc_add_tree / rsc_intern_str /
// rsc_new_tedinfo) and rsc_write()s them to a .rsc, so later desktop tasks can
// pull dialogs out of the resource (rsrc_gaddr-style) instead of hand-coding
// OBJECT arrays.
//
//   Trees:
//     0  New dialog     — G_BOX "New"; Folder/File radios; a Type: G_POPUP
//                         (current ".txt") linked to tree 1 (link in the ob_type
//                         high byte); a Name: G_FTEXT field; Cancel + OK buttons.
//     1  Type menu      — the popup's linked tree: .txt / .html / .md items.
//     2  Confirm dialog — a message G_STRING + Yes / No buttons.
//     3  Add-Server     — mirrors the desktop's add_server_dialog fields, for a
//                         later migration off the hand-coded tree.
//
//   usage: mkrsc [out.rsc]   (default resources/desktop.rsc)

#include "aes/aes.h"     // G_*, OF_*, OS_*, TE_LEFT (flag/type enums)
#include "rsc.h"         // the shared engine builder API + RSC_OBJECT/RSC_BOXWORD
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { F_SEL = OF_SELECTABLE, F_DEF = OF_DEFAULT, F_EXIT = OF_EXIT,
       F_EDIT = OF_EDITABLE, F_RBUT = OF_RBUTTON,
       F_CANCEL = OF_CANCEL, F_MOVE = OF_MOVEABLE };

static const char *TMPL24 = "________________________";   // 24 input slots

// default GEM colour word: border=1, text=1, hollow, no fill (matches gcw_default)
#define DLG_COLOR 0x1100

// Fill object t[rel] (tree-relative).  Links are set later by link_flat().
static void set_obj(RSC_OBJECT *t, int rel, int type, unsigned flags,
                    unsigned state, void *spec, int x, int y, int w, int h) {
    RSC_OBJECT *o = &t[rel];
    o->ob_next = o->ob_head = o->ob_tail = RSC_NIL;
    o->ob_type = (uint16_t)type;
    o->ob_flags = (uint16_t)flags;
    o->ob_state = (uint16_t)state;
    o->ob_spec = spec;
    o->ob_x = (int16_t)x; o->ob_y = (int16_t)y;
    o->ob_w = (int16_t)w; o->ob_h = (int16_t)h;
}

// Wire up a flat dialog: root at rel 0, direct children rel 1..nchild.  Sibling
// chain head->..->tail; the last child's ob_next points back to the root and
// carries OF_LASTOB (the tree terminator).
static void link_flat(RSC_OBJECT *t, int nchild) {
    t[0].ob_next = RSC_NIL;
    t[0].ob_head = nchild ? 1 : RSC_NIL;
    t[0].ob_tail = nchild ? nchild : RSC_NIL;
    for (int k = 1; k <= nchild; k++) {
        t[k].ob_head = t[k].ob_tail = RSC_NIL;
        t[k].ob_next = (int16_t)(k < nchild ? k + 1 : 0);   // last -> parent (root)
        t[k].ob_flags &= (uint16_t)~OF_LASTOB;
    }
    if (nchild) t[nchild].ob_flags |= OF_LASTOB;
    else        t[0].ob_flags |= OF_LASTOB;
}

static void *boxword(void) { return (void *)(uintptr_t)RSC_BOXWORD(0, 1, DLG_COLOR); }
static char *S(RSC *r, const char *s) { return rsc_intern_str(r, s); }

// A G_FTEXT TEDINFO: only te_ptext/ptmplt/pvalid/te_just are meaningful to this
// AES (the writer derives te_txtlen/te_tmplen from the strings).
static RSC_TEDINFO *ted(RSC *r, const char *text, const char *tmpl,
                        const char *valid, int just) {
    RSC_TEDINFO *ti = rsc_new_tedinfo(r);
    ti->te_ptext  = rsc_intern_str(r, text);
    ti->te_ptmplt = rsc_intern_str(r, tmpl);
    ti->te_pvalid = rsc_intern_str(r, valid);
    ti->te_just   = (int16_t)just;
    ti->te_txtlen = (int16_t)(strlen(tmpl) + 1);
    return ti;
}

// ---- tree 0: New dialog ---------------------------------------------------
static void build_new(RSC *r, int popup_menu_tree) {
    int base = rsc_alloc_objects(r, 11);
    rsc_add_tree(r, base);
    RSC_OBJECT *t = rsc_objects(r, NULL) + base;
    set_obj(t, 0,  G_BOX,    F_MOVE, OS_NORMAL,  boxword(),        0,   0, 360, 220);
    set_obj(t, 1,  G_STRING, OF_NONE, OS_NORMAL, S(r, "New"),     20,  12, 200,  16);
    set_obj(t, 2,  G_STRING, OF_NONE, OS_NORMAL, S(r, "Kind:"),   24,  46,  64,  20);
    set_obj(t, 3,  G_RADIO,  F_SEL|F_RBUT, OS_SELECTED, S(r,"Folder"), 96, 44, 100, 20);
    set_obj(t, 4,  G_RADIO,  F_SEL|F_RBUT, OS_NORMAL,   S(r,"File"),  200, 44,  90, 20);
    set_obj(t, 5,  G_STRING, OF_NONE, OS_NORMAL, S(r, "Type:"),   24,  82,  64,  20);
    // G_POPUP: linked menu tree index in the ob_type high byte (RSC-FORMAT §5).
    set_obj(t, 6,  G_POPUP | ((popup_menu_tree & 0xFF) << 8), F_SEL, OS_NORMAL,
            S(r, ".txt"), 96, 78, 130, 24);
    set_obj(t, 7,  G_STRING, OF_NONE, OS_NORMAL, S(r, "Name:"),   24, 118,  64,  20);
    set_obj(t, 8,  G_FTEXT,  F_EDIT, OS_NORMAL, ted(r,"",TMPL24,"X",TE_LEFT), 96,114,232,26);
    set_obj(t, 9,  G_BUTTON, F_SEL|F_EXIT|F_CANCEL, OS_NORMAL, S(r,"Cancel"), 132,168,100,32);
    set_obj(t, 10, G_BUTTON, F_SEL|F_EXIT|F_DEF,    OS_NORMAL, S(r,"OK"),     244,168, 92,32);
    link_flat(t, 10);
}

// ---- tree 1: the Type popup's linked menu ---------------------------------
static void build_typemenu(RSC *r) {
    int base = rsc_alloc_objects(r, 4);
    rsc_add_tree(r, base);
    RSC_OBJECT *t = rsc_objects(r, NULL) + base;
    set_obj(t, 0, G_BOX, OF_NONE, OS_NORMAL, boxword(), 96, 78, 100, 66);
    const char *items[] = { ".txt", ".html", ".md" };
    for (int i = 0; i < 3; i++)
        set_obj(t, 1 + i, G_STRING, F_SEL, OS_NORMAL, S(r, items[i]), 8, 4 + i*20, 84, 18);
    link_flat(t, 3);
}

// ---- tree 2: Confirm dialog ----------------------------------------------
static void build_confirm(RSC *r) {
    int base = rsc_alloc_objects(r, 4);
    rsc_add_tree(r, base);
    RSC_OBJECT *t = rsc_objects(r, NULL) + base;
    set_obj(t, 0, G_BOX,    F_MOVE, OS_NORMAL, boxword(),          0,  0, 320, 140);
    set_obj(t, 1, G_STRING, OF_NONE, OS_NORMAL, S(r,"Are you sure?"), 24, 28, 272, 20);
    set_obj(t, 2, G_BUTTON, F_SEL|F_EXIT|F_CANCEL, OS_NORMAL, S(r,"No"),  84, 88, 90, 32);
    set_obj(t, 3, G_BUTTON, F_SEL|F_EXIT|F_DEF,    OS_NORMAL, S(r,"Yes"), 196, 88, 90, 32);
    link_flat(t, 3);
}

// ---- tree 3: Add-Server (mirrors desktop add_server_dialog) ---------------
static void build_addserver(RSC *r) {
    int base = rsc_alloc_objects(r, 14);
    rsc_add_tree(r, base);
    RSC_OBJECT *t = rsc_objects(r, NULL) + base;
    set_obj(t, 0,  G_BOX,    F_MOVE, OS_NORMAL, boxword(),        0,   0, 480, 246);
    set_obj(t, 1,  G_STRING, OF_NONE, OS_NORMAL, S(r,"Add FujiNet server"), 20, 12, 440, 20);
    set_obj(t, 2,  G_STRING, OF_NONE, OS_NORMAL, S(r,"Host:"),    20,  50,  88, 20);
    set_obj(t, 3,  G_FTEXT,  F_EDIT, OS_NORMAL, ted(r,"",TMPL24,"P",TE_LEFT), 116, 47, 340, 26);
    set_obj(t, 4,  G_STRING, OF_NONE, OS_NORMAL, S(r,"Transport:"), 20, 86, 88, 20);
    set_obj(t, 5,  G_RADIO,  F_SEL|F_RBUT, OS_NORMAL,   S(r,"udp"),  116, 84, 70, 20);
    set_obj(t, 6,  G_RADIO,  F_SEL|F_RBUT, OS_NORMAL,   S(r,"tcp"),  196, 84, 70, 20);
    set_obj(t, 7,  G_RADIO,  F_SEL|F_RBUT, OS_SELECTED, S(r,"auto"), 276, 84, 80, 20);
    set_obj(t, 8,  G_STRING, OF_NONE, OS_NORMAL, S(r,"Path:"),    20, 122,  88, 20);
    set_obj(t, 9,  G_FTEXT,  F_EDIT, OS_NORMAL, ted(r,"/",TMPL24,"P",TE_LEFT), 116, 119, 340, 26);
    set_obj(t, 10, G_STRING, OF_NONE, OS_NORMAL, S(r,"Name:"),    20, 158,  88, 20);
    set_obj(t, 11, G_FTEXT,  F_EDIT, OS_NORMAL, ted(r,"",TMPL24,"X",TE_LEFT), 116, 155, 340, 26);
    set_obj(t, 12, G_BUTTON, F_SEL|F_EXIT|F_CANCEL, OS_NORMAL, S(r,"Cancel"), 252, 196, 100, 32);
    set_obj(t, 13, G_BUTTON, F_SEL|F_EXIT|F_DEF,    OS_NORMAL, S(r,"OK"),     364, 196,  92, 32);
    link_flat(t, 13);
}

int main(int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "resources/desktop.rsc";
    RSC *r = rsc_new();
    if (!r) { fprintf(stderr, "mkrsc: out of memory\n"); return 1; }

    build_new(r, 1);        // tree 0; Type popup links tree 1
    build_typemenu(r);      // tree 1
    build_confirm(r);       // tree 2
    build_addserver(r);     // tree 3

    uint8_t *bytes = NULL; size_t len = 0; const char *err = NULL;
    if (rsc_write(r, &bytes, &len, &err) != 0) {
        fprintf(stderr, "mkrsc: rsc_write failed: %s\n", err ? err : "?");
        rsc_free(r);
        return 1;
    }
    FILE *f = fopen(out, "wb");
    if (!f || fwrite(bytes, 1, len, f) != len) {
        fprintf(stderr, "mkrsc: failed to write %s\n", out);
        if (f) fclose(f);
        free(bytes); rsc_free(r);
        return 1;
    }
    fclose(f);
    printf("mkrsc: wrote %s (%d trees, %zu bytes)\n", out, rsc_ntrees(r), len);
    free(bytes);
    rsc_free(r);
    return 0;
}
