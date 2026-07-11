// aes/form.c — form_do, the modal dialog interaction loop.  Drives the host
// event source: present the dialog (objc_draw), wait for a click/key, update
// object state, repeat — until an EXIT button is clicked or a key fires one.
//
// Keyboard policy (form_keybd, also public for bare evnt_multi clients):
//   Return       fires the OF_DEFAULT object
//   Esc          clears the focused edit field first; then (or with no edit
//                focus / an empty field) fires the OF_CANCEL object
//   TAB / Shift-TAB  cycle focus over OF_EDITABLE objects (tree order, wrap)
//   mnemonics    WHITEBAK-underlined letters act as clicks — bare letters when
//                no edit field has focus, Alt+letter (or Ctrl+letter, the
//                terminal testbed's substitute) always
// Mnemonics are auto-assigned on form_do entry (fix_shortcuts): app-declared
// WHITEBAK (or Geneva-style "[S]ave" brackets, promoted + stripped — bracket
// labels must be writable) claim first, then every button/checkbox/radio and
// every label-of-a-field gets the first unclaimed letter of its label.
//
// A root with OF_MOVEABLE is draggable by its fly corner (top-right 16x16,
// theme-drawn dog-ear) or any inert area (objc_find hit nothing SELECTABLE /
// EXIT / TOUCHEXIT / EDITABLE): save-under move on the host, the HW overlay
// plane on the A9 (same hooks as window drag).  Dialogs clamp to the work
// area.  form_do_dialog = centre + save-under + form_do + restore — the
// standard dialog wrapper (form_alert runs through it).
//
// All modal waits go through aes_wait_idle, so the registered idle hook
// (net_pump) keeps async I/O alive while a dialog is up.

#include "aes/aes_internal.h"
#include <string.h>
#include <ctype.h>

#define DEPTH 8
#define BIG   4096

#define EACH_CHILD(t, parent, c) \
    for (int c = (t)[parent].ob_head; c >= 0; c = (c == (t)[parent].ob_tail ? -1 : (t)[c].ob_next))

static int find_parent(OBJECT *t, int root, int target) {
    EACH_CHILD(t, root, c) {
        if (c == target) return root;
        int p = find_parent(t, c, target);
        if (p >= 0) return p;
    }
    return -1;
}
static int find_default(OBJECT *t, int root) {
    if (t[root].ob_flags & OF_DEFAULT) return root;
    EACH_CHILD(t, root, c) { int d = find_default(t, c); if (d >= 0) return d; }
    return -1;
}
static int find_cancel(OBJECT *t, int root) {
    if (t[root].ob_flags & OF_CANCEL) return root;
    EACH_CHILD(t, root, c) { int d = find_cancel(t, c); if (d >= 0) return d; }
    return -1;
}
// Select a radio button, deselecting its RBUTTON siblings.
static void do_radio(OBJECT *t, int o) {
    int p = find_parent(t, 0, o);
    if (p >= 0) EACH_CHILD(t, p, c) if (t[c].ob_flags & OF_RBUTTON) t[c].ob_state &= ~OS_SELECTED;
    t[o].ob_state |= OS_SELECTED;
}
// draw + push the dialog rect (aes_flush_rect: A9 back-buffer targets need an
// explicit present for draws outside wind_redraw; a no-op on the SDL host).
static void draw(OBJECT *t) {
    objc_draw(t, 0, DEPTH, 0, 0, BIG, BIG);
    aes_flush_rect(t[0].ob_x, t[0].ob_y, t[0].ob_w, t[0].ob_h);
}
static void draw_one(OBJECT *t, int o) {
    int x, y; objc_offset(t, o, &x, &y);
    objc_draw(t, o, 0, x, y, t[o].ob_w, t[o].ob_h);
    aes_flush_rect(x, y, t[o].ob_w, t[o].ob_h);
}
static int tree_count(OBJECT *t) {
    int n = 0;
    while (n < BIG && !(t[n].ob_flags & OF_LASTOB)) n++;
    return n + 1;
}

// App hook for radio-change / G_POPUP-click reactions (see aes.h).  The modal
// loop is non-reentrant, so a single pair of file statics is enough.
static form_hook_fn g_form_hook;
static void        *g_form_hook_ud;
void form_set_hook(form_hook_fn fn, void *ud) { g_form_hook = fn; g_form_hook_ud = ud; }

// ---- editable-field focus -------------------------------------------------
static int can_edit(OBJECT *t, int i) {
    return (t[i].ob_flags & OF_EDITABLE) && !(t[i].ob_state & OS_DISABLED)
        && !(t[i].ob_flags & OF_HIDETREE);
}
// Next / previous OF_EDITABLE in tree order, wrapping; -1 = none.
static int next_editable(OBJECT *t, int from) {
    int n = tree_count(t);
    for (int s = 1; s <= n; s++) { int i = (from + s) % n; if (i < 0) i += n; if (can_edit(t, i)) return i; }
    return -1;
}
static int prev_editable(OBJECT *t, int from) {
    int n = tree_count(t);
    if (from < 0) from = 0;
    for (int s = 1; s <= n; s++) { int i = (from - s + 2*n) % n; if (can_edit(t, i)) return i; }
    return -1;
}
static int focus_edit(OBJECT *t, int from, int to) {
    if (to == from) return to;
    if (from >= 0) objc_edit(t, from, 0, NULL, ED_END);
    if (to >= 0) { int c = -1; objc_edit(t, to, 0, &c, ED_INIT); }
    return to;
}

// ---- mnemonics (WHITEBAK) ---------------------------------------------------
static int has_label(OBJECT *t, int i) {
    int ty = t[i].ob_type;
    return (ty == G_BUTTON || ty == G_CHECKBOX || ty == G_RADIO || ty == G_STRING)
        && t[i].ob_spec;
}
static int label_of_field(OBJECT *t, int i) {   // G_STRING immediately preceding an editable
    int nx = t[i].ob_next;
    return t[i].ob_type == G_STRING && nx >= 0 && (t[nx].ob_flags & OF_EDITABLE);
}
// Promote Geneva "[S]ave" markers to WHITEBAK (stripping the brackets), claim
// app-declared letters, then auto-assign the rest (first unclaimed letter of
// each label, case-insensitive).  Idempotent — safe on re-entered trees.
static void fix_shortcuts(OBJECT *t) {
    int n = tree_count(t);
    unsigned claimed = 0;
    for (int i = 0; i < n; i++) {
        if (!has_label(t, i)) continue;
        if (t[i].ob_type == G_STRING && !label_of_field(t, i)) continue;  // plain text: leave brackets alone
        char *s = (char *)t[i].ob_spec;
        if (!(t[i].ob_state & OS_WHITEBAK)) {
            char *b = strchr(s, '[');                     // "[S]ave" -> "Save" + WHITEBAK
            if (b && b[1] && b[2] == ']') {
                int idx = (int)(b - s);
                memmove(b, b + 1, strlen(b + 1) + 1);     // drop '['
                memmove(b + 1, b + 2, strlen(b + 2) + 1); // drop ']'
                t[i].ob_state |= WB_MAKE(idx);
            }
        }
        if (t[i].ob_state & OS_WHITEBAK) {                // app-declared: claim it
            int c = tolower((unsigned char)s[WB_INDEX(t[i].ob_state)]);
            if (c >= 'a' && c <= 'z') claimed |= 1u << (c - 'a');
        }
    }
    for (int i = 0; i < n; i++) {                         // auto-assign the rest
        if ((t[i].ob_state & OS_WHITEBAK) || !has_label(t, i)) continue;
        if (t[i].ob_type == G_STRING && !label_of_field(t, i)) continue;
        const char *s = (const char *)t[i].ob_spec;
        for (int j = 0; s[j]; j++) {                      // collisions fall through
            int c = tolower((unsigned char)s[j]);
            if (c < 'a' || c > 'z' || (claimed & (1u << (c - 'a')))) continue;
            claimed |= 1u << (c - 'a');
            t[i].ob_state |= WB_MAKE(j);
            break;
        }
    }
}
static int mnemonic_obj(OBJECT *t, int letter) {
    int n = tree_count(t), c = tolower(letter);
    for (int i = 0; i < n; i++) {
        if (!(t[i].ob_state & OS_WHITEBAK) || !has_label(t, i)) continue;
        if (t[i].ob_flags & OF_HIDETREE) continue;
        const char *s = (const char *)t[i].ob_spec;
        if (tolower((unsigned char)s[WB_INDEX(t[i].ob_state)]) == c) return i;
    }
    return -1;
}

// ---- form_keybd -------------------------------------------------------------
int form_keybd(OBJECT *t, int edobj, int key, int kstate, int *new_edobj) {
    int ascii = key & 0xFF, exit_obj = -1;
    if (edobj >= 0 && !(t[edobj].ob_flags & OF_EDITABLE)) edobj = -1;

    if (ascii == '\r' || ascii == '\n') {                 // Return -> default
        int d = find_default(t, 0);
        if (d >= 0 && !(t[d].ob_state & OS_DISABLED)) {
            t[d].ob_state |= OS_SELECTED; draw_one(t, d);
            exit_obj = d;
        }
        goto out;
    }
    if (ascii == 0x1b) {                                  // Esc: two-stage
        if (edobj >= 0) {
            TEDINFO *te = (TEDINFO *)t[edobj].ob_spec;
            if (te && te->te_ptext && te->te_ptext[0]) {  // stage 1: clear the field
                objc_edit(t, edobj, 0x15, NULL, ED_CHAR); // Ctrl-U = clear
                goto out;
            }
        }
        int c = find_cancel(t, 0);                        // stage 2: fire OF_CANCEL
        if (c >= 0 && !(t[c].ob_state & OS_DISABLED)) {
            t[c].ob_state |= OS_SELECTED; draw_one(t, c);
            exit_obj = c;
        }
        goto out;                                         // no OF_CANCEL: stay modal
    }
    if (ascii == 0x09) {                                  // TAB / Shift-TAB focus cycle
        int to = (kstate & (K_LSHIFT | K_RSHIFT)) ? prev_editable(t, edobj)
                                                  : next_editable(t, edobj);
        if (to >= 0) edobj = focus_edit(t, edobj, to);
        goto out;
    }
    if (isalpha((unsigned char)ascii) &&
        ((kstate & (K_ALT | K_CTRL)) || edobj < 0)) {     // mnemonic fire
        // Ctrl-U belongs to the editor (clear) while a field has focus
        if (!(edobj >= 0 && (kstate & K_CTRL) && tolower(ascii) == 'u')) {
            int m = mnemonic_obj(t, ascii);
            if (m >= 0 && !(t[m].ob_state & OS_DISABLED)) {
                if (t[m].ob_flags & (OF_EXIT | OF_TOUCHEXIT)) {
                    t[m].ob_state |= OS_SELECTED; draw_one(t, m);
                    exit_obj = m;
                } else if (t[m].ob_flags & OF_RBUTTON) {
                    do_radio(t, m); if (g_form_hook) g_form_hook(t, m, g_form_hook_ud); draw(t);
                } else if (t[m].ob_flags & OF_SELECTABLE) {
                    t[m].ob_state ^= OS_SELECTED; draw_one(t, m);
                } else if (label_of_field(t, m) && can_edit(t, t[m].ob_next)) {
                    edobj = focus_edit(t, edobj, t[m].ob_next);
                }
                goto out;
            }
        }
    }
    if (edobj >= 0) {                                     // everything else: the editor
        if ((kstate & K_CTRL) && tolower(ascii) == 'u') key = 0x15;
        objc_edit(t, edobj, key, NULL, ED_CHAR);
    }
out:
    if (new_edobj) *new_edobj = edobj;
    return exit_obj;
}

// ---- save-under stack (form_do_dialog + the drag loop) ----------------------
// A small stack so dialogs nest (a dialog's error alert on top of it); each
// entry remembers its tree so the drag loop only touches its own pixels.
#define SAVN 4
static struct { gfx_surface *s; OBJECT *t; int x, y, w, h; } g_sav[SAVN];
static int g_nsav;

static void sav_blit(int i, int to_screen) {
    int H = aes_handle();
    MFDB scr = {0}, m; mfdb_from_surface(&m, g_sav[i].s);
    int x = g_sav[i].x, y = g_sav[i].y, w = g_sav[i].w, h = g_sav[i].h;
    if (to_screen) {
        int16_t p[8] = {0,0,(int16_t)(w-1),(int16_t)(h-1),
                        (int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1)};
        vro_cpyfm(H, VRO_COPY, p, &m, &scr);
    } else {
        int16_t p[8] = {(int16_t)x,(int16_t)y,(int16_t)(x+w-1),(int16_t)(y+h-1),
                        0,0,(int16_t)(w-1),(int16_t)(h-1)};
        vro_cpyfm(H, VRO_COPY, p, &scr, &m);
    }
}
static void sav_push(OBJECT *t) {
    if (g_nsav >= SAVN) { g_nsav++; return; }             // too deep: skip (counted)
    gfx_surface *s = gfx_surface_alloc(t[0].ob_w, t[0].ob_h);
    g_sav[g_nsav].s = s; g_sav[g_nsav].t = t;
    g_sav[g_nsav].x = t[0].ob_x; g_sav[g_nsav].y = t[0].ob_y;
    g_sav[g_nsav].w = t[0].ob_w; g_sav[g_nsav].h = t[0].ob_h;
    if (s) sav_blit(g_nsav, 0);
    g_nsav++;
}
// Restore what the dialog covered.  Returns 1 if the save-under was blitted back,
// 0 if there was nothing to restore with — either the nesting went past SAVN (so
// sav_push recorded nothing) or the surface alloc failed.  The caller MUST then
// regenerate the rect itself, or the dialog is left painted on the screen forever.
// Callers used to paper over this with a full-screen repaint(); returning the
// failure lets them redraw just the dialog's rect instead.
static int sav_pop_restore(void) {
    if (g_nsav <= 0) return 0;
    g_nsav--;
    if (g_nsav >= SAVN || !g_sav[g_nsav].s) return 0;
    sav_blit(g_nsav, 1);
    aes_flush_rect(g_sav[g_nsav].x, g_sav[g_nsav].y, g_sav[g_nsav].w, g_sav[g_nsav].h);
    gfx_surface_free(g_sav[g_nsav].s);
    g_sav[g_nsav].s = NULL; g_sav[g_nsav].t = NULL;
    return 1;
}
// The top save-under, if it belongs to `t` (the dialog the drag is moving).
static int sav_top_of(OBJECT *t) {
    int i = g_nsav - 1;
    return (i >= 0 && i < SAVN && g_sav[i].t == t && g_sav[i].s) ? i : -1;
}

// ---- movable dialogs ---------------------------------------------------------
static int want_move(OBJECT *t, int o, int mx, int my) {
    int rx = t[0].ob_x, ry = t[0].ob_y;
    if (mx >= rx + t[0].ob_w - 16 && mx < rx + t[0].ob_w &&
        my >= ry && my < ry + 16) return 1;               // the fly corner
    if (o < 0) return 0;                                  // outside the dialog
    if (o == 0) return 1;                                 // root = inert
    return !(t[o].ob_flags & (OF_SELECTABLE | OF_EXIT | OF_TOUCHEXIT | OF_EDITABLE));
}
static void clamp_dlg(OBJECT *t, int *nx, int *ny) {
    int wx, wy, ww, wh; wind_get(0, WF_WORKXYWH, &wx, &wy, &ww, &wh);
    if (*nx > wx + ww - t[0].ob_w) *nx = wx + ww - t[0].ob_w;
    if (*ny > wy + wh - t[0].ob_h) *ny = wy + wh - t[0].ob_h;
    if (*nx < wx) *nx = wx;
    if (*ny < wy) *ny = wy;
}
static void drag_dialog(OBJECT *t, int mx, int my) {
    int gx = mx - t[0].ob_x, gy = my - t[0].ob_y;
    int sav = sav_top_of(t);
    int ox = t[0].ob_x, oy = t[0].ob_y, w = t[0].ob_w, h = t[0].ob_h;

    if (aes_ovl_lift(ox, oy, w, h)) {                     // A9: ride the HW overlay
        if (sav >= 0) sav_blit(sav, 1); else wind_redraw();
        aes_flush_rect(ox, oy, w, h);                     // dialog gone from the plane (overlay covers it)
        for (;;) {
            aes_event e; int ty = aes_wait_idle(&e, -1);
            if (ty == AES_QUIT || ty == AES_BTN_UP) break;
            if (ty != AES_MOTION) continue;
            int nx = e.mx - gx, ny = e.my - gy; clamp_dlg(t, &nx, &ny);
            t[0].ob_x = (int16_t)nx; t[0].ob_y = (int16_t)ny;
            aes_ovl_move(nx, ny);                         // register write, no redraw
        }
        if (sav >= 0) {                                   // re-save + paint at the new home
            g_sav[sav].x = t[0].ob_x; g_sav[sav].y = t[0].ob_y;
            sav_blit(sav, 0);
        }
        draw(t);
        aes_ovl_drop();
        return;
    }
    for (;;) {                                            // host: restore/move/save/redraw
        aes_event e; int ty = aes_wait_idle(&e, -1);
        if (ty == AES_QUIT || ty == AES_BTN_UP) break;
        if (ty != AES_MOTION) continue;
        int nx = e.mx - gx, ny = e.my - gy; clamp_dlg(t, &nx, &ny);
        if (nx == t[0].ob_x && ny == t[0].ob_y) continue;
        int px = t[0].ob_x, py = t[0].ob_y;
        if (sav >= 0) sav_blit(sav, 1); else wind_redraw();
        t[0].ob_x = (int16_t)nx; t[0].ob_y = (int16_t)ny;
        if (sav >= 0) { g_sav[sav].x = nx; g_sav[sav].y = ny; sav_blit(sav, 0); }
        objc_draw(t, 0, DEPTH, 0, 0, BIG, BIG);
        aes_flush_rect(px, py, w, h);
        aes_flush_rect(nx, ny, w, h);
    }
}

// ---- form_do ------------------------------------------------------------------
int form_do(OBJECT *t, int start) {
    fix_shortcuts(t);
    int edobj = -1;
    if (start == 0)      edobj = next_editable(t, -1);    // classic: 0 = first editable
    else if (start > 0 && can_edit(t, start)) edobj = start;
    if (edobj >= 0) { int c = -1; objc_edit(t, edobj, 0, &c, ED_INIT); }
    draw(t);
    int pressed = -1;
#define END_FOCUS() do { if (edobj >= 0) objc_edit(t, edobj, 0, NULL, ED_END); } while (0)
    for (;;) {
        aes_event ev;
        int gen = aes_redraw_gen();
        int ty = aes_wait_idle(&ev, -1);
        if (aes_redraw_gen() != gen) draw(t);             // idle work repainted under us
        if (ty == AES_QUIT) { END_FOCUS(); return -1; }

        if (ty == AES_KEY) {
            int r = form_keybd(t, edobj, ev.key, ev.shift, &edobj);
            if (r >= 0) { END_FOCUS(); return r; }
            continue;
        }
        if (ty == AES_BTN_DOWN) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            if ((t[0].ob_flags & OF_MOVEABLE) && want_move(t, o, ev.mx, ev.my)) {
                drag_dialog(t, ev.mx, ev.my);
                continue;
            }
            if (o > 0 && can_edit(t, o)) {                // click focuses an edit field
                edobj = focus_edit(t, edobj, o);
                continue;
            }
            if (o >= 0 && (t[o].ob_flags & OF_SELECTABLE) && !(t[o].ob_state & OS_DISABLED)) {
                if (t[o].ob_type == G_POPUP) {                // combo: app runs the linked menu
                    if (g_form_hook) g_form_hook(t, o, g_form_hook_ud);
                    draw(t);
                } else {
                    if (t[o].ob_flags & (OF_EXIT | OF_TOUCHEXIT)) { t[o].ob_state |= OS_SELECTED; pressed = o; }
                    else if (t[o].ob_flags & OF_RBUTTON)         { do_radio(t, o); if (g_form_hook) g_form_hook(t, o, g_form_hook_ud); }
                    else                                          { t[o].ob_state ^= OS_SELECTED; }
                    draw(t);
                    if (t[o].ob_flags & OF_TOUCHEXIT) { END_FOCUS(); return o; }
                }
            }
            continue;
        }
        if (ty == AES_BTN_UP && pressed >= 0) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            int hit = (o == pressed);
            t[pressed].ob_state &= ~OS_SELECTED; draw(t);
            int p = pressed; pressed = -1;
            if (hit) { END_FOCUS(); return p; }           // released inside -> trigger
        }
    }
#undef END_FOCUS
}

// Centre + save-under + form_do + restore: the standard dialog wrapper.
int form_do_dialog(OBJECT *t, int start) {
    int wx, wy, ww, wh; wind_get(0, WF_WORKXYWH, &wx, &wy, &ww, &wh);
    t[0].ob_x = (int16_t)(wx + (ww - t[0].ob_w) / 2);
    t[0].ob_y = (int16_t)(wy + (wh - t[0].ob_h) / 2);
    sav_push(t);
    int r = form_do(t, start);
    // The dialog is MOVEABLE, so read the moved-to rect off the tree, not the
    // pushed one.  If the save-under couldn't restore (nesting past SAVN, or the
    // alloc failed), regenerate just that rect — never leave the dialog painted.
    int dx = t[0].ob_x, dy = t[0].ob_y, dw = t[0].ob_w, dh = t[0].ob_h;
    if (!sav_pop_restore()) wind_redraw_area(dx, dy, dw, dh);
    return r;
}

// ---- form_alert ---------------------------------------------------------
static int atext_w(const char *s){ int16_t e[8]; vst_height(aes_handle(),14,0,0,0,0); vqt_extent(aes_handle(),s,e); return e[2]-e[0]; }

int form_alert(int defbtn, const char *s) {
    char line[5][80], btn[3][24]; int icon=0, nl=0, nb=0;
    const char *p=s;
    while(*p && *p!='[') p++; if(*p)p++;                 // [icon]
    if(*p>='0'&&*p<='9') icon=*p-'0';
    while(*p && *p!=']') p++; if(*p)p++;
    while(*p && *p!='[') p++; if(*p)p++;                 // [message]
    { int li=0,ci=0; while(*p&&*p!=']'){ if(*p=='|'){ line[li][ci]=0; if(++li>=5){li=4;break;} ci=0; }
        else if(ci<79) line[li][ci++]=*p; p++; } line[li][ci]=0; nl=li+1; }
    while(*p && *p!=']') p++; if(*p)p++;
    while(*p && *p!='[') p++; if(*p)p++;                 // [buttons]
    { int bi=0,ci=0; while(*p&&*p!=']'){ if(*p=='|'){ btn[bi][ci]=0; if(++bi>=3){bi=2;break;} ci=0; }
        else if(ci<23) btn[bi][ci++]=*p; p++; } btn[bi][ci]=0; nb=bi+1; }
    if(defbtn<1||defbtn>nb) defbtn=nb;

    const char *icn = icon==1?"alert.note":icon==2?"alert.wait":icon==3?"alert.stop":0;
    const theme_slice *is = icn? theme_find(aes_theme(),icn):0;
    int iw = is?is->sw:0, ih = is?is->sh:0;

    int PAD=18, LINEH=18, BTNH=28, GAP=10;
    int msgw=0; for(int i=0;i<nl;i++){ int w=atext_w(line[i]); if(w>msgw)msgw=w; }
    int bw[3], tbw=0; for(int i=0;i<nb;i++){ bw[i]=atext_w(btn[i])+28; tbw+=bw[i]+(i?GAP:0); }
    int ix = PAD, mx = PAD + (iw?iw+PAD:0);
    int body_w = mx + msgw + PAD, box_w = body_w>PAD+tbw+PAD?body_w:PAD+tbw+PAD;
    int content_h = (ih>nl*LINEH?ih:nl*LINEH);
    int box_h = PAD + content_h + PAD + BTNH + PAD;

    OBJECT o[12]; memset(o,0,sizeof o); int n=1;
    o[0]=(OBJECT){NIL,1,0,G_BOX,OF_MOVEABLE,OS_NORMAL,0,0,0,(int16_t)box_w,(int16_t)box_h};
    if(icn){ o[n]=(OBJECT){0,NIL,NIL,G_IMAGE,OF_NONE,OS_NORMAL,(void*)icn,(int16_t)ix,(int16_t)PAD,(int16_t)iw,(int16_t)ih}; n++; }
    for(int i=0;i<nl;i++){ o[n]=(OBJECT){0,NIL,NIL,G_STRING,OF_NONE,OS_NORMAL,(void*)line[i],(int16_t)mx,(int16_t)(PAD+i*LINEH),(int16_t)msgw,LINEH}; n++; }
    int firstbtn=n, bx=(box_w-tbw)/2, by=box_h-PAD-BTNH;
    for(int i=0;i<nb;i++){ o[n]=(OBJECT){0,NIL,NIL,G_BUTTON,
        (uint16_t)(OF_SELECTABLE|OF_EXIT|((i+1==defbtn)?OF_DEFAULT:0)|((nb==1)?OF_CANCEL:0)),OS_NORMAL,
        (void*)btn[i],(int16_t)bx,(int16_t)by,(int16_t)bw[i],BTNH}; bx+=bw[i]+GAP; n++; }
    o[0].ob_tail=n-1;
    for(int i=1;i<n;i++) o[i].ob_next=(i<n-1)?(i+1):0;
    o[n-1].ob_flags|=OF_LASTOB;

    int r=form_do_dialog(o,-1);
    return (r>=firstbtn && r<firstbtn+nb) ? (r-firstbtn+1) : defbtn;
}
