/*
 * gemd/route.c — INPUT ROUTING (M4). Who gets the click, and what they are told about it.
 *
 * The rule (RESPONSIBILITIES.md §3): gemd owns the pointer. It hit-tests the z-order, decides
 * whether an event belongs to the CHROME (which is gemd's) or to a client's CONTENT, and if it
 * is content it sends it to exactly one client — in WINDOW-LOCAL coordinates. A client is never
 * told where it is on screen, what is above it, or that anything happened outside its own work
 * area. It cannot even ask.
 *
 * WHAT IS NOT HERE, AND WHY: the closer/mover/sizer hit test, the drag loop and the resize loop.
 * They are `wind_handle_click()` in gem/aes/window.c — the AES's own code, running in this
 * process, unchanged. That is M2's thesis carried into input: gemd IS the AES in server mode, so
 * frame interaction is not reimplemented server-side, it simply runs here. What this file adds
 * is the routing around it: focus, forwarding, and turning the AES messages that fall out of the
 * frame interaction (WM_CLOSED, WM_MOVED, WM_SIZED) into wire messages for the window's owner.
 *
 * gemd does NOT close a window when the closer is clicked. It sends MSG_CLOSED and lets the app
 * decide — an app may want to ask "save changes?" first. Classic GEM, and the right split.
 */
#include <stdio.h>
#include <string.h>
#include "gemd.h"
#include "aes/aes_internal.h"

static int g_focus;                   /* the window that gets keys. 0 = nobody. */
static int g_pmx, g_pmy;              /* the pointer, as gemd last saw it */

static void send_win(int hd, const gem_msg *m)
{
    int ci = wind_client_of(hd);
    if (ci >= 0) gemd_send_to(ci, m);
}

/* Focus follows the CLICK, not the z-order: a click on a W_BOTTOM window (the desktop) focuses
 * it without topping it — it must never be topped (§4(2)) but it must still be usable. */
static void set_focus(int hd)
{
    if (hd == g_focus) return;
    gem_msg m; memset(&m, 0, sizeof m);
    if (g_focus) { m.w[0] = GEM_MSG_ACTIVATE; m.w[1] = (int16_t)g_focus; m.w[2] = 0;
                   send_win(g_focus, &m); }
    g_focus = hd;
    if (g_focus) { memset(&m, 0, sizeof m);
                   m.w[0] = GEM_MSG_ACTIVATE; m.w[1] = (int16_t)g_focus; m.w[2] = 1;
                   send_win(g_focus, &m); }
}

void gemd_forget_window(int hd) { if (g_focus == hd) g_focus = 0; }

/* Screen -> window-local. The client draws its content at 0,0 and is told where the pointer is
 * IN THAT SAME SPACE, so it hit-tests its own widgets with the coordinates it drew them at. */
static void to_local(int hd, int sx, int sy, int *lx, int *ly)
{
    int ox, oy;
    wind_work_origin(hd, &ox, &oy);
    *lx = sx - ox; *ly = sy - oy;
}

static void send_button(int hd, int x, int y, int button, int shift)
{
    if (!hd) return;
    int lx, ly; to_local(hd, x, y, &lx, &ly);
    gem_msg m; memset(&m, 0, sizeof m);
    m.w[0] = GEM_EV_BUTTON; m.w[1] = (int16_t)hd;
    m.w[2] = (int16_t)lx; m.w[3] = (int16_t)ly;
    m.w[4] = (int16_t)button; m.w[5] = (int16_t)shift;
    send_win(hd, &m);
}

void gemd_route(int type, const aes_event *ev)
{
    g_pmx = ev->mx; g_pmy = ev->my;

    switch (type) {
    case AES_BTN_DOWN: {
        int hd = wind_find(ev->mx, ev->my);
        if (!hd) { gemd_flush_msgs(); return; }        /* the bare plane: nobody's */
        set_focus(hd);
        /* THE AES'S OWN FRAME HIT TEST — closer, mover, sizer, scrollbars — running in gemd.
         * It returns 1 when the chrome consumed the click, and its drag/resize loops wait
         * through aes_wait_idle, which is OUR event source: gemd keeps servicing every client
         * channel while a window is being dragged. It never blocks (§3). */
        if (wind_handle_click(ev->mx, ev->my)) break;  /* chrome. The client hears the CONSEQUENCE. */
        send_button(hd, ev->mx, ev->my, ev->button ? ev->button : 1, ev->shift);
        break;
    }
    case AES_BTN_UP:
        /* The release goes wherever the press went — to the FOCUSED window, not to whatever is
         * under the pointer now. A press that drags out of a window still ends in that window,
         * which is what makes a button behave like a button. */
        if (g_focus) send_button(g_focus, ev->mx, ev->my, 0, ev->shift);
        break;

    case AES_MOTION:
        if (g_focus) {
            int lx, ly; to_local(g_focus, ev->mx, ev->my, &lx, &ly);
            gem_msg m; memset(&m, 0, sizeof m);
            m.w[0] = GEM_EV_MOTION; m.w[1] = (int16_t)g_focus;
            m.w[2] = (int16_t)lx; m.w[3] = (int16_t)ly; m.w[4] = (int16_t)ev->button;
            send_win(g_focus, &m);
        }
        break;

    case AES_KEY:
        if (g_focus) {
            gem_msg m; memset(&m, 0, sizeof m);
            m.w[0] = GEM_EV_KEY; m.w[1] = (int16_t)g_focus;
            m.w[2] = (int16_t)ev->key; m.w[3] = (int16_t)ev->shift;
            send_win(g_focus, &m);
        }
        break;

    default: break;                                    /* TIMER / anything else: nothing to route */
    }
    gemd_flush_msgs();
}

/* The AES posts its window messages into the local pipe (appl_write) exactly as it does in a
 * single-process app. In gemd they are not for gemd — they are for the window's OWNER, so drain
 * the pipe and put them on the wire. This is the whole of "the chrome is live": the closer, the
 * title-bar drag and the sizer already worked; they just had nowhere to send the result. */
void gemd_flush_msgs(void)
{
    int16_t msg[8];
    while (appl_read(0, 16, msg)) {
        int hd = msg[3];
        if (hd < 1 || hd >= GEMD_MAXW) continue;
        gem_msg m; memset(&m, 0, sizeof m);
        switch (msg[0]) {
        case WM_CLOSED:                                /* the closer. NOT gemd's decision (§3). */
            m.w[0] = GEM_MSG_CLOSED; m.w[1] = (int16_t)hd;
            send_win(hd, &m);
            break;
        case WM_MOVED:                                 /* gemd already moved the pixels: no redraw */
            m.w[0] = GEM_MSG_MOVED; m.w[1] = (int16_t)hd;
            m.w[2] = msg[4]; m.w[3] = msg[5]; m.w[4] = msg[6]; m.w[5] = msg[7];
            send_win(hd, &m);
            break;
        case WM_SIZED:                                 /* the sizer / the fuller: §12 does the rest */
            gemd_resize_surface(hd);
            break;
        case WM_TOPPED:
            set_focus(hd);
            break;
        default: break;                                /* WM_VSLID &c: gemd's scrollbars, gemd's */
        }
    }
}
