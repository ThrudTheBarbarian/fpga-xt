// tools/mkrsc.c — author gem/resources/desktop.rsc with the shared rsc codec.
//
// Builds a handful of minimal-but-valid GEM trees in memory through the rsc
// builder API and rsc_save()s them, so later desktop tasks can pull dialogs out
// of the resource (rsrc_gaddr-style) instead of hand-coding OBJECT arrays.
//
//   Trees:
//     0  New dialog     — G_BOX "New"; Folder/File radios; a Type: G_POPUP
//                         (current ".txt") linked to tree 1; a Name: G_FTEXT
//                         field; Cancel + OK buttons.
//     1  Type menu      — the popup's linked tree: .txt / .html / .md items.
//     2  Confirm dialog — a message G_STRING + Yes / No buttons.
//     3  Add-Server     — mirrors the desktop's add_server_dialog fields, for a
//                         later migration off the hand-coded tree.
//
//   usage: mkrsc [out.rsc]   (default gem/resources/desktop.rsc)

#include "aes/rsc.h"
#include <stdio.h>
#include <string.h>

// aes.h flag/state values used below (kept explicit for readability).
enum { F_SEL = OF_SELECTABLE, F_DEF = OF_DEFAULT, F_EXIT = OF_EXIT,
       F_EDIT = OF_EDITABLE, F_RBUT = OF_RBUTTON, F_LAST = OF_LASTOB,
       F_CANCEL = OF_CANCEL, F_MOVE = OF_MOVEABLE };

static const char *TMPL24 = "________________________";   // 24 input slots

// ---- tree 0: New dialog ---------------------------------------------------
static void build_new(rsc *r, int popup_menu_tree) {
    int t = rsc_add_tree(r);                              // == 0
    int root = rsc_add_object(r, t, -1, G_BOX, F_MOVE, OS_NORMAL, 0, 0, 360, 220);
    rsc_set_box(r, t, root, 0, 1, rsc_default_color());

    int title = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 12, 200, 16);
    rsc_set_string(r, t, title, "New");

    int lkind = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 24, 46, 64, 20);
    rsc_set_string(r, t, lkind, "Kind:");
    int rfolder = rsc_add_object(r, t, root, G_RADIO, F_SEL | F_RBUT, OS_SELECTED, 96, 44, 100, 20);
    rsc_set_string(r, t, rfolder, "Folder");             // default
    int rfile = rsc_add_object(r, t, root, G_RADIO, F_SEL | F_RBUT, OS_NORMAL, 200, 44, 90, 20);
    rsc_set_string(r, t, rfile, "File");

    int ltype = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 24, 82, 64, 20);
    rsc_set_string(r, t, ltype, "Type:");
    int popup = rsc_add_object(r, t, root, G_POPUP, F_SEL, OS_NORMAL, 96, 78, 130, 24);
    rsc_set_string(r, t, popup, ".txt");                 // current value
    rsc_set_popup_link(r, t, popup, popup_menu_tree);    // -> tree 1 (high byte)

    int lname = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 24, 118, 64, 20);
    rsc_set_string(r, t, lname, "Name:");
    int fname = rsc_add_object(r, t, root, G_FTEXT, F_EDIT, OS_NORMAL, 96, 114, 232, 26);
    rsc_set_tedinfo(r, t, fname, "", TMPL24, "X", TE_LEFT);

    int cancel = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_CANCEL, OS_NORMAL, 132, 168, 100, 32);
    rsc_set_string(r, t, cancel, "Cancel");
    int ok = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_DEF | F_LAST, OS_NORMAL, 244, 168, 92, 32);
    rsc_set_string(r, t, ok, "OK");
}

// ---- tree 1: the Type popup's linked menu ---------------------------------
static void build_typemenu(rsc *r) {
    int t = rsc_add_tree(r);                              // == 1
    int box = rsc_add_object(r, t, -1, G_BOX, OF_NONE, OS_NORMAL, 96, 78, 100, 66);
    rsc_set_box(r, t, box, 0, 1, rsc_default_color());
    const char *items[] = { ".txt", ".html", ".md" };
    for (int i = 0; i < 3; i++) {
        int it = rsc_add_object(r, t, box, G_STRING, F_SEL, OS_NORMAL, 8, 4 + i * 20, 84, 18);
        rsc_set_string(r, t, it, items[i]);
    }
}

// ---- tree 2: Confirm dialog ----------------------------------------------
static void build_confirm(rsc *r) {
    int t = rsc_add_tree(r);                              // == 2
    int root = rsc_add_object(r, t, -1, G_BOX, F_MOVE, OS_NORMAL, 0, 0, 320, 140);
    rsc_set_box(r, t, root, 0, 1, rsc_default_color());
    int msg = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 24, 28, 272, 20);
    rsc_set_string(r, t, msg, "Are you sure?");
    int no = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_CANCEL, OS_NORMAL, 84, 88, 90, 32);
    rsc_set_string(r, t, no, "No");
    int yes = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_DEF, OS_NORMAL, 196, 88, 90, 32);
    rsc_set_string(r, t, yes, "Yes");
}

// ---- tree 3: Add-Server (mirrors aesdesk add_server_dialog) ---------------
static void build_addserver(rsc *r) {
    int t = rsc_add_tree(r);                              // == 3
    int root = rsc_add_object(r, t, -1, G_BOX, F_MOVE, OS_NORMAL, 0, 0, 480, 246);
    rsc_set_box(r, t, root, 0, 1, rsc_default_color());
    int title = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 12, 440, 20);
    rsc_set_string(r, t, title, "Add FujiNet server");

    int lhost = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 50, 88, 20);
    rsc_set_string(r, t, lhost, "Host:");
    int fhost = rsc_add_object(r, t, root, G_FTEXT, F_EDIT, OS_NORMAL, 116, 47, 340, 26);
    rsc_set_tedinfo(r, t, fhost, "", TMPL24, "P", TE_LEFT);

    int ltran = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 86, 88, 20);
    rsc_set_string(r, t, ltran, "Transport:");
    int rudp = rsc_add_object(r, t, root, G_RADIO, F_SEL | F_RBUT, OS_NORMAL, 116, 84, 70, 20);
    rsc_set_string(r, t, rudp, "udp");
    int rtcp = rsc_add_object(r, t, root, G_RADIO, F_SEL | F_RBUT, OS_NORMAL, 196, 84, 70, 20);
    rsc_set_string(r, t, rtcp, "tcp");
    int rauto = rsc_add_object(r, t, root, G_RADIO, F_SEL | F_RBUT, OS_SELECTED, 276, 84, 80, 20);
    rsc_set_string(r, t, rauto, "auto");

    int lpath = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 122, 88, 20);
    rsc_set_string(r, t, lpath, "Path:");
    int fpath = rsc_add_object(r, t, root, G_FTEXT, F_EDIT, OS_NORMAL, 116, 119, 340, 26);
    rsc_set_tedinfo(r, t, fpath, "/", TMPL24, "P", TE_LEFT);

    int lname = rsc_add_object(r, t, root, G_STRING, OF_NONE, OS_NORMAL, 20, 158, 88, 20);
    rsc_set_string(r, t, lname, "Name:");
    int fname = rsc_add_object(r, t, root, G_FTEXT, F_EDIT, OS_NORMAL, 116, 155, 340, 26);
    rsc_set_tedinfo(r, t, fname, "", TMPL24, "X", TE_LEFT);

    int cancel = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_CANCEL, OS_NORMAL, 252, 196, 100, 32);
    rsc_set_string(r, t, cancel, "Cancel");
    int ok = rsc_add_object(r, t, root, G_BUTTON, F_SEL | F_EXIT | F_DEF | F_LAST, OS_NORMAL, 364, 196, 92, 32);
    rsc_set_string(r, t, ok, "OK");
}

int main(int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "resources/desktop.rsc";
    rsc *r = rsc_new();
    if (!r) { fprintf(stderr, "mkrsc: out of memory\n"); return 1; }

    build_new(r, 1);        // New dialog; popup links tree 1
    build_typemenu(r);      // tree 1
    build_confirm(r);       // tree 2
    build_addserver(r);     // tree 3

    if (rsc_save(r, out) != 0) {
        fprintf(stderr, "mkrsc: failed to write %s\n", out);
        rsc_free(r);
        return 1;
    }
    printf("mkrsc: wrote %s (%d trees)\n", out, rsc_ntree(r));
    rsc_free(r);
    return 0;
}
