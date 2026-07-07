/*
 * sprite.c — A9 hardware sprite-engine driver + the GEM mouse cursor (kernel/PL1;
 * GP0 at 0x43C0_0000 is a Device peripheral, PL0-none, so the cursor is owned
 * here and the PL0 desktop asks for it via syscalls).  Ported from
 * vitis/xtos/src/sprite.c.  The sprite arena (0x3400_0000) is Normal
 * NON-cacheable here (SEC_PLANE), so a dsb — not a cache flush — orders the arena
 * writes before the fetcher (HP2) reads them.
 */
#include <stdint.h>
#include "xtsys.h"                /* struct os_event, OS_EV_* */
extern int desk_readc(void);         /* console bytes routed to the desktop (focus=desktop) */
extern int desk_readc_timeout(int ms);

#ifdef XT_HW

#define GP0_BASE     0x43C00000u
#define SPR_IDX      (GP0_BASE + 0x100u)     /* W: latch sprite reg index */
#define SPR_DATA     (GP0_BASE + 0x104u)     /* W: reg data + strobe      */
#define SPR_ARENA    0x34000000u             /* ARENA_BASE (sprite image store) */

/* sprite-engine register indices (reg_addr[7:0]) */
#define R_SEL        0xD0u
#define R_PRIO       0xD1u
#define R_LOG2SZ     0xD2u
#define R_ARENA_YLO  0xD3u
#define R_ARENA_HI   0xD4u
#define R_ARENA_XLO  0xD5u
#define R_SCREEN_YLO 0xD6u
#define R_SCREEN_HI  0xD7u
#define R_COMMIT     0xD8u
#define R_CTRL0      0xA0u
#define R_GLOBAL     0xDFu

static inline void spr_reg(uint8_t idx, uint8_t val) {
    *(volatile uint8_t *)SPR_IDX  = idx;     /* latch index */
    *(volatile uint8_t *)SPR_DATA = val;     /* data + reg_we pulse */
}

static void sprite_set(int slot, int prio, int log2sz,
                       int ax, int ay, int sx, int sy) {
    spr_reg(R_SEL,        (uint8_t)(slot & 0x0F));
    spr_reg(R_PRIO,       (uint8_t)(prio & 0x1F));
    spr_reg(R_LOG2SZ,     (uint8_t)(log2sz & 0x0F));
    spr_reg(R_ARENA_YLO,  (uint8_t)(ay & 0xFF));
    spr_reg(R_ARENA_HI,   (uint8_t)((((ax >> 8) & 0x0F) << 4) | ((ay >> 8) & 0x0F)));
    spr_reg(R_ARENA_XLO,  (uint8_t)(ax & 0xFF));
    spr_reg(R_SCREEN_YLO, (uint8_t)(sy & 0xFF));
    spr_reg(R_SCREEN_HI,  (uint8_t)((((sx >> 8) & 0x0F) << 4) | ((sy >> 8) & 0x0F)));
    spr_reg(R_COMMIT,     (uint8_t)(sx & 0xFF));      /* commit; carries screen_x[7:0] */
}
static void sprite_load_rgba(int ax, int ay, int w, int h, const uint32_t *img) {
    for (int r = 0; r < h; r++) {
        volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)
            (SPR_ARENA + ((uint32_t)(ay + r) << 14) + ((uint32_t)ax << 2));
        for (int c = 0; c < w; c++) p[c] = img[(uint32_t)r * w + c];
    }
    __asm__ volatile("dsb");                 /* arena is non-cacheable -> just order it */
}

/* ---- the GEM arrow cursor (sprite slot 0, on top of every plane) ---------- */
#define CURW 12
#define CURH 19
#define CUR_SLOT 0
static const char *s_arrow[CURH] = {
    "X           ", "XX          ", "X.X         ", "X..X        ",
    "X...X       ", "X....X      ", "X.....X     ", "X......X    ",
    "X.......X   ", "X........X  ", "X.....XXXXX ", "X..X..X     ",
    "X.X X..X    ", "XX  X..X    ", "X    X..X   ", "     X..X   ",
    "      X..X  ", "      X..X  ", "       XX   ",
};
static int cur_x = 960, cur_y = 540;

void cursor_init(void) {
    static uint32_t img[32 * 32];
    for (int r = 0; r < 32; r++)
        for (int c = 0; c < 32; c++) {
            uint32_t px = 0x00000000u;                /* transparent (alpha 0) */
            if (r < CURH && c < CURW) {
                char ch = s_arrow[r][c];
                if      (ch == 'X') px = 0x000000FFu;  /* black outline */
                else if (ch == '.') px = 0xFFFFFFFFu;  /* white fill */
            }
            img[r * 32 + c] = px;
        }
    sprite_load_rgba(0, 0, 32, 32, img);
    sprite_set(CUR_SLOT, 0, 5, 0, 0, cur_x, cur_y);   /* log2sz 5 = 32 px */
    spr_reg((uint8_t)(R_CTRL0 + CUR_SLOT), 0x21u);    /* enable(0) + format32(5) */
    spr_reg(R_GLOBAL, 0x01u);
}
void cursor_move(int x, int y) {
    cur_x = x; cur_y = y;
    sprite_set(CUR_SLOT, 0, 5, 0, 0, x, y);
}
void cursor_pos(int *x, int *y) { *x = cur_x; *y = cur_y; }

/* Serial "mouse", two sources:
 *
 * 1. The TERMINAL'S mouse via xterm SGR reporting: on the first call we switch
 *    the terminal into button-event tracking (CSI ?1002h: press/release + motion
 *    while a button is held) with SGR encoding (CSI ?1006h, unambiguous + >223
 *    cols), and query the text-area size (CSI 18t -> CSI 8;rows;cols t) to map
 *    terminal cells onto the 1920x1080 desktop.  This gives real point/click/drag
 *    with the mouse in the user's terminal window.
 * 2. Keyboard fallback: cursor keys move the pointer; Enter = a click (down now,
 *    up on the next call — a double-click is Enter Enter); SPACE toggles the
 *    button (press-hold-release), which is what makes window DRAG possible
 *    without terminal mouse support: point at the title bar, Space, arrows,
 *    Space.
 *
 * Runs kernel-side in the deferral thunk (task context) so sh_readc may block.
 * (Terminal caveat: mouse reporting stays on while the desktop runs; if focus
 * is toggled to the shell, mousing spews CSI bytes at it — known cosmetic.) */
#define CUR_STEP 16
static int s_pend_up;
static int s_btn;                       /* space-toggle / SGR button state */
static int s_mouse_init;
static int s_cols = 80, s_rows = 24;    /* terminal text area (CSI 18t reply) */

extern void puts0(const char *);

/* read a decimal int from the desktop queue; returns the terminating char
 * (or -1 on timeout) with the value in *v */
static int rd_int(int *v) {
    int n = 0, c;
    for (;;) {
        c = desk_readc_timeout(50);
        if (c < '0' || c > '9') break;
        n = n * 10 + (c - '0');
    }
    *v = n;
    return c;
}
static int cell2px(int cell, int cells, int span) {
    int p = (cell - 1) * span / (cells > 0 ? cells : 80) + span / (2 * (cells > 0 ? cells : 80));
    if (p < 0) p = 0; if (p > span - 1) p = span - 1;
    return p;
}

int input_next_event(struct os_event *ev, int timeout_ms) {
    if (!s_mouse_init) {                /* focus is on the desktop: hook the terminal */
        s_mouse_init = 1;
        puts0("\x1b[?1002h\x1b[?1006h"); /* button-event tracking, SGR encoding */
        puts0("\x1b[18t");               /* -> ESC [ 8 ; rows ; cols t */
    }
    ev->shift = 0; ev->key = 0;
    if (s_pend_up) { s_pend_up = 0; s_btn = 0; ev->type = OS_EV_BTN_UP; ev->button = 0; cursor_pos(&ev->mx, &ev->my); return 0; }

    for (;;) {
        int c = desk_readc_timeout(timeout_ms);
        if (c < 0) { ev->type = OS_EV_TIMER; ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0; }

        if (c == 0x1b) {                              /* ESC: CSI or a bare Escape */
            int c1 = desk_readc_timeout(30);
            if (c1 != '[') { ev->type = OS_EV_KEY; ev->key = 0x1b; ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0; }
            int c2 = desk_readc_timeout(50);

            if (c2 == '<') {                          /* SGR mouse: <b;x;yM / <b;x;ym */
                int b, cx, cy, t;
                if (rd_int(&b) != ';') continue;
                if (rd_int(&cx) != ';') continue;
                t = rd_int(&cy);
                if (t != 'M' && t != 'm') continue;
                if (b & 64) continue;                 /* wheel: ignore */
                int x = cell2px(cx, s_cols, 1920), y = cell2px(cy, s_rows, 1080);
                cursor_move(x, y);
                ev->mx = x; ev->my = y;
                if (t == 'm')            { s_btn = 0; ev->type = OS_EV_BTN_UP;   ev->button = 0; }
                else if (b & 32)         {            ev->type = OS_EV_MOTION;   ev->button = s_btn; }
                else                     { s_btn = 1; ev->type = OS_EV_BTN_DOWN; ev->button = 1; }
                return 0;
            }
            if (c2 >= '0' && c2 <= '9') {             /* CSI n... — the 18t size reply */
                int n1 = c2 - '0', n2, n3, t;
                for (;;) { t = desk_readc_timeout(50);
                           if (t < '0' || t > '9') break; n1 = n1 * 10 + (t - '0'); }
                if (t == ';' && n1 == 8) {
                    if (rd_int(&n2) == ';' && rd_int(&n3) == 't' && n2 > 0 && n3 > 0) {
                        s_rows = n2; s_cols = n3;
                    }
                }
                continue;                             /* consumed, no event */
            }
            {                                         /* arrows move the pointer */
                int x, y; cursor_pos(&x, &y);
                if      (c2 == 'A') y -= CUR_STEP;
                else if (c2 == 'B') y += CUR_STEP;
                else if (c2 == 'C') x += CUR_STEP;
                else if (c2 == 'D') x -= CUR_STEP;
                else continue;                        /* unknown CSI: swallow */
                if (x < 0) x = 0; if (x > 1919) x = 1919;
                if (y < 0) y = 0; if (y > 1079) y = 1079;
                cursor_move(x, y);
                ev->type = OS_EV_MOTION; ev->mx = x; ev->my = y; ev->button = s_btn; return 0;
            }
        }
        if (c == ' ') {                               /* Space: press-and-hold toggle */
            cursor_pos(&ev->mx, &ev->my);
            if (!s_btn) { s_btn = 1; ev->type = OS_EV_BTN_DOWN; ev->button = 1; }
            else        { s_btn = 0; ev->type = OS_EV_BTN_UP;   ev->button = 0; }
            return 0;
        }
        if (c == '\r' || c == '\n') {                 /* Enter: click (down, up next call) */
            ev->type = OS_EV_BTN_DOWN; ev->button = 1; s_btn = 1; s_pend_up = 1; cursor_pos(&ev->mx, &ev->my); return 0;
        }
        ev->type = OS_EV_KEY; ev->key = c; ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0;
    }
}

#else   /* qemu: no sprite engine / input */
int input_next_event(struct os_event *ev, int timeout_ms) {
    (void)timeout_ms; ev->type = OS_EV_TIMER; ev->button = 0; ev->mx = ev->my = 0; return 0;
}
#endif
