// aes/event.c — the AES event source plumbing: aes_wait (the low-level host
// source call), the appl_* message pipe, evnt_multi (the multiplexer) and its
// evnt_keybd/button/mouse/mesag/timer convenience wrappers.

#include "aes/aes_internal.h"
#include <string.h>

/* XTOS system messages (SD insert/remove, ...): the kernel queues them per-process;
 * we drain them into the AES message pipe so they surface as normal MU_MESAG events.
 * Guarded so the portable SDL testbed (no XTOS syscalls) just skips it. */
#ifdef GEM_XTOS
#include "usys.h"
static void xtos_drain(void) { int16_t xm[8]; while (sys_xtos_recv(xm)) appl_write(0, 16, xm); }
#else
static void xtos_drain(void) {}
#endif

static aes_event_fn g_src;
void aes_set_events(aes_event_fn fn) { g_src = fn; }
int  aes_wait(aes_event *ev, int timeout_ms) {
    if (!g_src) { ev->type = AES_QUIT; return AES_QUIT; }
    return g_src(ev, timeout_ms);
}

// ---- central idle hook ---------------------------------------------------
// Modal AES loops (form_do, drags, future menus) wait through aes_wait_idle:
// the caller's wait is chunked by the registered period and fn runs on each
// expiry, so async work (net_pump) stays alive inside modal interactions.
static void (*g_idle_fn)(void);
static int g_idle_ms;
static int g_in_idle;             // no re-entry: an idle-spawned modal loop
                                  // (e.g. an error alert) must not recurse
void aes_set_idle(void (*fn)(void), int period_ms) {
    g_idle_fn = fn; g_idle_ms = period_ms;
}
int aes_wait_idle(aes_event *ev, int timeout_ms) {
    if (!g_idle_fn || g_idle_ms <= 0 || g_in_idle)
        return aes_wait(ev, timeout_ms);
    long left = timeout_ms;                       // <0 = forever
    for (;;) {
        int chunk = (timeout_ms < 0 || left > g_idle_ms) ? g_idle_ms : (int)left;
        int t = aes_wait(ev, chunk);
        if (t != AES_TIMER) return t;
        g_in_idle = 1; g_idle_fn(); g_in_idle = 0;
        if (timeout_ms >= 0) {
            left -= chunk;
            if (left <= 0) return AES_TIMER;      // the caller's real timeout
        }
    }
}

// ---- message pipe (appl_write -> evnt_mesag) ----------------------------
#define MQW 8
#define MQN 32
static int16_t mq[MQN][MQW];
static int mqh, mqt;

/* THE MODE SWITCH (RESPONSIBILITIES.md §5, "one library, two modes").
 *
 * If the "gem" service is there, this app becomes a gemd CLIENT: wind_* stop touching a local
 * window list and start sending messages, and the app never learns. If it is NOT there (the SDL
 * host, a single-process build, gemd not running), the app stays LOCAL and behaves exactly as it
 * always has. That is §5's promise made mechanical:
 *
 *     "an app written against single-process GEM compiles and runs against gemd unmodified"
 *
 * Note this is appl_init and not aes_init: aes_init(vdi_handle, theme) merely binds a
 * workstation and is called by EVERY app (and by gemd itself), so it cannot be the thing that
 * decides who is the server. gemd declares itself with aes_server_mode().
 */
int  appl_init(void) {
    mqh = mqt = 0;
    wind_client_attach();     /* -> client mode iff gemd is listening (no-op off-target) */
    return 1;
}
void appl_exit(void) { wind_client_detach(); }
void appl_write(int dest, int len, const void *msg) {
    (void)dest;
    int n = (mqt + 1) % MQN; if (n == mqh) return;     // full: drop
    int w = len / 2; if (w > MQW) w = MQW;
    memset(mq[mqt], 0, sizeof mq[mqt]);
    memcpy(mq[mqt], msg, (size_t)w * 2);
    mqt = n;
}
int appl_read(int id, int len, void *buf) {
    (void)id; (void)len;
    if (mqh == mqt) return 0;
    memcpy(buf, mq[mqh], MQW * 2);
    mqh = (mqh + 1) % MQN;
    return 1;
}

// ---- evnt_multi ----------------------------------------------------------
static int in_rect(int x, int y, int rx, int ry, int rw, int rh) {
    return x >= rx && x < rx + rw && y >= ry && y < ry + rh;
}

int evnt_multi(int flags, int bclk, int bmask, int bstate,
               int m1f,int m1x,int m1y,int m1w,int m1h,
               int m2f,int m2x,int m2y,int m2w,int m2h,
               int16_t *mep, int tlc, int thc,
               int *omx,int *omy,int *omb,int *oks,int *okey,int *onc) {
    (void)bclk;
    long timeout = (flags & MU_TIMER)
                 ? (((long)(unsigned short)thc << 16) | (unsigned short)tlc) : -1;
    xtos_drain();                                                              // pull OS system events into the pipe
    if ((flags & MU_MESAG) && mep && appl_read(0, 16, mep)) return MU_MESAG;   // already queued

    for (;;) {
        aes_event ev;
        int t = aes_wait(&ev, (int)timeout);
        xtos_drain();                                                          // and again after each wakeup
        if (omx) *omx = ev.mx; if (omy) *omy = ev.my;
        if (omb) *omb = ev.button; if (oks) *oks = ev.shift;

        if (t == AES_QUIT) return MU_QUIT;
        if (t == AES_WHEEL) { wind_handle_wheel(ev.mx, ev.my, ev.wheel); continue; }   // scroll under pointer
        if (t == AES_TIMER) { if (flags & MU_TIMER) return MU_TIMER; continue; }
        if (t == AES_KEY && (flags & MU_KEYBD)) {
            if (okey) *okey = ev.key; return MU_KEYBD;
        }
        if (t == AES_BTN_DOWN && (menu_handle_click(ev.mx, ev.my) ||
                                  wind_handle_click(ev.mx, ev.my))) {
            if ((flags & MU_MESAG) && mep && appl_read(0, 16, mep)) return MU_MESAG;
            continue;                                   // menu / window frame consumed the click
        }
        if ((t == AES_BTN_DOWN || t == AES_BTN_UP) && (flags & MU_BUTTON)) {
            if (((ev.button) & bmask) == (bstate & bmask)) { if (onc) *onc = 1; return MU_BUTTON; }
        }
        if (t == AES_MOTION) {
            if ((flags & MU_M1) && (in_rect(ev.mx,ev.my,m1x,m1y,m1w,m1h) != 0) == (m1f == 0)) return MU_M1;
            if ((flags & MU_M2) && (in_rect(ev.mx,ev.my,m2x,m2y,m2w,m2h) != 0) == (m2f == 0)) return MU_M2;
        }
        if ((flags & MU_MESAG) && mep && appl_read(0, 16, mep)) return MU_MESAG;
        // otherwise: an event we weren't asked for — keep waiting
    }
}

int evnt_keybd(void) {
    int key = 0;
    evnt_multi(MU_KEYBD, 0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0,0,0, 0,0,0,0,&key,0);
    return key;
}
int evnt_button(int clicks, int mask, int state, int *mx, int *my, int *mb, int *ks) {
    int nc = 0;
    evnt_multi(MU_BUTTON, clicks, mask, state, 0,0,0,0,0, 0,0,0,0,0, 0,0,0, mx,my,mb,ks,0,&nc);
    return nc;
}
int evnt_mouse(int leave, int x, int y, int w, int h, int *mx, int *my, int *mb, int *ks) {
    return evnt_multi(MU_M1, 0,0,0, leave,x,y,w,h, 0,0,0,0,0, 0,0,0, mx,my,mb,ks,0,0) ? 1 : 0;
}
int evnt_mesag(int16_t *mep) {
    return evnt_multi(MU_MESAG, 0,0,0, 0,0,0,0,0, 0,0,0,0,0, mep,0,0, 0,0,0,0,0,0);
}
int evnt_timer(int lo, int hi) {
    return evnt_multi(MU_TIMER, 0,0,0, 0,0,0,0,0, 0,0,0,0,0, 0, lo, hi, 0,0,0,0,0,0);
}
