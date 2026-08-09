// aes/edit.c — objc_edit, the OF_EDITABLE text-field engine (classic entry
// points: ED_INIT focus + caret, ED_CHAR one key, ED_END drop focus).  Works
// on the reduced TEDINFO: te_ptext is the caller's buffer, te_ptmplt is the
// display template ('_' = input position, literals are skipped over
// automatically), te_pvalid validates per input position (classic set).
// One field has focus at a time (module state); object.c asks for it via
// objc_edit_state so the caret survives full tree redraws.  Usable both from
// form_do and from a bare evnt_multi client's MU_KEYBD arm (via form_keybd).

#include "aes/aes_internal.h"
#include <string.h>
#include <ctype.h>

static struct { OBJECT *tree; int obj; int caret; } g_ed = { 0, -1, 0 };

// XG (and any client that owns its own damage/repaint) drives field redraws through its own
// paint cycle, where the draw surface is bound.  The AES's own edit-redraw runs OUTSIDE that
// cycle (straight from objc_edit) and would blit to an unbound surface.  A client sets this to
// route the caret/text update through its next paint instead.  gemd leaves it 0 (its form_do
// dialogs draw directly).  Per-process, so it never crosses the client/server boundary.
static int g_ed_nodraw = 0;
void objc_edit_set_nodraw(int on) { g_ed_nodraw = on; }

int objc_edit_state(OBJECT *tree, int obj, int *caret) {
    if (g_ed.tree != tree || g_ed.obj != obj) return 0;
    if (caret) *caret = g_ed.caret;
    return 1;
}

// Merge template + text into a display string; *dpos (optional) receives the
// display index of input position `pos` (for caret placement).
int ted_display(const TEDINFO *ted, char *out, int cap, int pos, int *dpos) {
    int di = 0, ti = 0;
    const char *txt = ted->te_ptext ? ted->te_ptext : "";
    if (dpos) *dpos = 0;
    if (!ted->te_ptmplt || !ted->te_ptmplt[0]) {          // free text, no template
        while (txt[ti] && di < cap - 1) {
            if (dpos && ti == pos) *dpos = di;
            out[di++] = txt[ti++];
        }
        if (dpos && pos >= ti) *dpos = di;
        out[di] = 0;
        return di;
    }
    int ip = 0, ended = 0;                                // input-position counter
    for (const char *tp = ted->te_ptmplt; *tp && di < cap - 1; tp++) {
        if (*tp == '_') {
            if (dpos && ip == pos) *dpos = di;
            // te_ptext is a C string: once its NUL is reached every remaining slot
            // is empty ('_').  (Reading past the NUL would spill whatever
            // uninitialised bytes follow into the field — the "garbage field" bug.)
            if (!ended && !txt[ip]) ended = 1;
            out[di++] = ended ? '_' : txt[ip];
            ip++;
        } else {
            out[di++] = *tp;
        }
    }
    if (dpos && pos >= ip) *dpos = di;
    out[di] = 0;
    return di;
}

// Max chars te_ptext can hold: the buffer, capped by the template's '_' count.
static int ted_maxlen(const TEDINFO *te) {
    int m = te->te_txtlen - 1;
    if (te->te_ptmplt && te->te_ptmplt[0]) {
        int u = 0;
        for (const char *p = te->te_ptmplt; *p; p++) if (*p == '_') u++;
        if (u < m) m = u;
    }
    return m < 0 ? 0 : m;
}

// The classic te_pvalid set; the last class char extends over the tail.
// Returns the (possibly case-forced) char to insert, or 0 = rejected.
static int pv_filter(const TEDINFO *te, int pos, int c) {
    int cls = 'X';
    if (te->te_pvalid && te->te_pvalid[0]) {
        int n = (int)strlen(te->te_pvalid);
        cls = te->te_pvalid[pos < n ? pos : n - 1];
    }
    if (cls == 'A' || cls == 'N' || cls == 'x') c = toupper(c);
    switch (cls) {
        case '9': return isdigit(c) ? c : 0;
        case 'A': return (isupper(c) || c == ' ') ? c : 0;
        case 'a': return (isalpha(c) || c == ' ') ? c : 0;
        case 'N': return (isdigit(c) || isupper(c) || c == ' ') ? c : 0;
        case 'n': return (isalnum(c) || c == ' ') ? c : 0;
        case 'F': case 'f': return (isalnum(c) || strchr("._-*?", c)) ? c : 0;
        case 'P': case 'p': return (isalnum(c) || strchr("._-*?/\\:", c)) ? c : 0;
        default:  return c;                               // 'X' / 'x' / unknown: anything
    }
}

// Redraw one field in place (+ flush its rect so modal draws present).
static void ed_redraw(OBJECT *tree, int obj) {
    if (g_ed_nodraw) return;
    int x, y; objc_offset(tree, obj, &x, &y);
    objc_draw(tree, obj, 0, x, y, tree[obj].ob_w, tree[obj].ob_h);
    aes_flush_rect(x, y, tree[obj].ob_w, tree[obj].ob_h);
}

int objc_edit(OBJECT *tree, int obj, int key, int *idx, int kind) {
    if (!tree || obj < 0) return 0;
    TEDINFO *te = (TEDINFO *)tree[obj].ob_spec;
    if (!te || !te->te_ptext) return 0;
    int len = (int)strlen(te->te_ptext);

    switch (kind) {
    case ED_START:
        return 1;
    case ED_INIT: {
        if (g_ed.obj >= 0 && (g_ed.tree != tree || g_ed.obj != obj)) {
            OBJECT *ot = g_ed.tree; int oo = g_ed.obj;    // drop the old focus
            g_ed.tree = NULL; g_ed.obj = -1;
            ed_redraw(ot, oo);
        }
        g_ed.tree = tree; g_ed.obj = obj;
        g_ed.caret = (idx && *idx >= 0 && *idx <= len) ? *idx : len;
        ed_redraw(tree, obj);
        if (idx) *idx = g_ed.caret;
        return 1;
    }
    case ED_END:
        if (g_ed.tree == tree && g_ed.obj == obj) {
            g_ed.tree = NULL; g_ed.obj = -1;
            ed_redraw(tree, obj);
        }
        return 1;
    case ED_CHAR: {
        if (g_ed.tree != tree || g_ed.obj != obj) {       // implicit focus
            g_ed.tree = tree; g_ed.obj = obj; g_ed.caret = len;
        }
        char *s = te->te_ptext;
        int ascii = key & 0xFF, sc = (key >> 8) & 0xFF;
        int caret = g_ed.caret, used = 1;
        if (caret > len) caret = len;

        if      (sc == XK_LEFT)  { if (caret > 0) caret--; }
        else if (sc == XK_RIGHT) { if (caret < len) caret++; }
        else if (sc == XK_HOME)  { caret = 0; }
        else if (sc == XK_DEL)   { if (caret < len) memmove(s+caret, s+caret+1, (size_t)(len-caret)); }
        else if (ascii == 0x08 || ascii == 0x7F) {        // Backspace
            if (caret > 0) { memmove(s+caret-1, s+caret, (size_t)(len-caret+1)); caret--; }
        }
        else if (ascii == 0x15) { s[0] = 0; caret = 0; }  // Ctrl-U: clear
        else if (ascii >= 32 && ascii < 127) {            // insert (pvalid-checked)
            int c = pv_filter(te, caret, ascii);
            if (c && len < ted_maxlen(te)) {
                memmove(s+caret+1, s+caret, (size_t)(len-caret+1));
                s[caret] = (char)c; caret++;
            }
        }
        else used = 0;

        if (used) { g_ed.caret = caret; ed_redraw(tree, obj); }
        if (idx) *idx = g_ed.caret;
        return used;
    }
    }
    return 0;
}
