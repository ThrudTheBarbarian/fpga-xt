// aes/form.c — form_do, the modal dialog interaction loop.  Drives the host
// event source: present the dialog (objc_draw), wait for a click/key, update
// object state, repeat — until an EXIT button is clicked or Return fires the
// default button.

#include "aes/aes.h"

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
// Select a radio button, deselecting its RBUTTON siblings.
static void do_radio(OBJECT *t, int o) {
    int p = find_parent(t, 0, o);
    if (p >= 0) EACH_CHILD(t, p, c) if (t[c].ob_flags & OF_RBUTTON) t[c].ob_state &= ~OS_SELECTED;
    t[o].ob_state |= OS_SELECTED;
}
static void draw(OBJECT *t) { objc_draw(t, 0, DEPTH, 0, 0, BIG, BIG); }

int form_do(OBJECT *t, int start) {
    (void)start;
    draw(t);
    int pressed = -1;
    for (;;) {
        aes_event ev;
        int ty = aes_wait(&ev, -1);
        if (ty == AES_QUIT) return -1;

        if (ty == AES_KEY) {
            if (ev.key == '\r' || ev.key == '\n') {
                int d = find_default(t, 0);
                if (d >= 0 && !(t[d].ob_state & OS_DISABLED)) {
                    t[d].ob_state |= OS_SELECTED; draw(t);
                    return d;
                }
            }
            continue;
        }
        if (ty == AES_BTN_DOWN) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            if (o >= 0 && (t[o].ob_flags & OF_SELECTABLE) && !(t[o].ob_state & OS_DISABLED)) {
                if (t[o].ob_flags & (OF_EXIT | OF_TOUCHEXIT)) { t[o].ob_state |= OS_SELECTED; pressed = o; }
                else if (t[o].ob_flags & OF_RBUTTON)         { do_radio(t, o); }
                else                                          { t[o].ob_state ^= OS_SELECTED; }
                draw(t);
                if (t[o].ob_flags & OF_TOUCHEXIT) return o;
            }
            continue;
        }
        if (ty == AES_BTN_UP && pressed >= 0) {
            int o = objc_find(t, 0, DEPTH, ev.mx, ev.my);
            int hit = (o == pressed);
            t[pressed].ob_state &= ~OS_SELECTED; draw(t);
            int p = pressed; pressed = -1;
            if (hit) return p;                          // released inside -> trigger
        }
    }
}
