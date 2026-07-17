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
extern int con_gui_readc(void);         /* console bytes routed to the desktop (focus=desktop) */
extern int con_gui_readc_timeout(int ms);

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
static int cur_x = 96, cur_y = 96;   /* home near the top-left: that is where the desktop
                                      * icons live, and a serial mouse crosses half of 1080p
                                      * slowly (user request — was screen centre) */

/* ---- resize cursors (proximity-resize affordance; gemd swaps via SYS_cursor_shape) ----
 * 16x16 double-headed arrows, CENTRE hotspot (8,8) — the arrow keeps its tip hotspot (0,0).
 * Each shape pre-rendered into its own 32px arena cell at init; switching is ONE sprite
 * commit with a different arena x, cheap enough to do per hover transition. */
#define RSZW 16
static const char *s_rsz_ew[RSZW] = {   /* <-> */
    "                ", "                ", "                ", "                ",
    "                ", "   X       X    ", "  XX       XX   ", " X.XXXXXXXXX.X  ",
    "X.............X ", " X.XXXXXXXXX.X  ", "  XX       XX   ", "   X       X    ",
    "                ", "                ", "                ", "                ",
};
static const char *s_rsz_ns[RSZW] = {   /* up-down */
    "       X        ", "      X.X       ", "     X...X      ", "    X.....X     ",
    "   XXXX.XXXX    ", "      X.X       ", "      X.X       ", "      X.X       ",
    "      X.X       ", "      X.X       ", "      X.X       ", "   XXXX.XXXX    ",
    "    X.....X     ", "     X...X      ", "      X.X       ", "       X        ",
};
static const char *s_rsz_nwse[RSZW] = { /* top-left <-> bottom-right */
    "XXXXXX          ", "X....X          ", "X...X           ", "X..X.X          ",
    "X.X X.X         ", "XX   X.X        ", "      X.X       ", "       X.X      ",
    "        X.X     ", "         X.X    ", "          X.XX  ", "         X.X X.X",
    "          X.X..X", "           X...X", "          X....X", "          XXXXXX",
};
static const char *s_rsz_nesw[RSZW] = { /* top-right <-> bottom-left */
    "          XXXXXX", "          X....X", "           X...X", "          X.X..X",
    "         X.X X.X", "        X.X   XX", "       X.X      ", "      X.X       ",
    "     X.X        ", "    X.X         ", "  XX.X          ", "X.X X.X         ",
    "X..X.X          ", "X...X           ", "X....X          ", "XXXXXX          ",
};
static const struct { const char **art; int n, ax, hx, hy; } s_shapes[] = {
    { 0,          0,   0,   0, 0 },      /* 0: the arrow (rendered by cursor_init) */
    { s_rsz_ew,   RSZW, 32, 8, 8 },
    { s_rsz_ns,   RSZW, 64, 8, 8 },
    { s_rsz_nwse, RSZW, 96, 8, 8 },
    { s_rsz_nesw, RSZW, 128,8, 8 },
};
#define NSHAPES 5
static int cur_shape = 0;
static void shape_render(int i){
    static uint32_t img[32*32];
    for(int r=0;r<32;r++) for(int c=0;c<32;c++){
        uint32_t px=0x00000000u;
        if(r<s_shapes[i].n && c<s_shapes[i].n){
            char ch=s_shapes[i].art[r][c];
            if(ch=='X') px=0x000000FFu; else if(ch=='.') px=0xFFFFFFFFu;
        }
        img[r*32+c]=px;
    }
    sprite_load_rgba(s_shapes[i].ax, 0, 32, 32, img);
}

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
    for (int i = 1; i < NSHAPES; i++) shape_render(i);
    sprite_set(CUR_SLOT, 0, 5, 0, 0, cur_x, cur_y);   /* log2sz 5 = 32 px */
    spr_reg((uint8_t)(R_CTRL0 + CUR_SLOT), 0x21u);    /* enable(0) + format32(5) */
    spr_reg(R_GLOBAL, 0x01u);
}
void cursor_move(int x, int y) {
    cur_x = x; cur_y = y;
    sprite_set(CUR_SLOT, 0, 5, s_shapes[cur_shape].ax, 0,
               x - s_shapes[cur_shape].hx, y - s_shapes[cur_shape].hy);
    /* SELF-HEAL the sprite enables on every move.  The sprite engine clears
     * global_enable (and per-sprite enable) on ANY clk_pix reset pulse, and
     * clk_pix's MMCM briefly unlocks under DDR/power pressure (a big SD DMA, an
     * HDMI RxSense dip) — which silently killed the cursor mid-session.  These
     * two writes are idempotent and cost nothing; re-asserting them per input
     * event means the cursor comes back within one mouse move of any glitch.
     * The real fix is RTL (global_enable should survive a transient reset). */
    spr_reg((uint8_t)(R_CTRL0 + CUR_SLOT), 0x21u);
    spr_reg(R_GLOBAL, 0x01u);
}
void cursor_set_shape(int n) {
    if (n < 0 || n >= NSHAPES || n == cur_shape) return;
    cur_shape = n;
    sprite_set(CUR_SLOT, 0, 5, s_shapes[n].ax, 0,
               cur_x - s_shapes[n].hx, cur_y - s_shapes[n].hy);
}
void cursor_pos(int *x, int *y) { *x = cur_x; *y = cur_y; }

/* ---- keyboard -> the 6502 (POKEY inject, GP0 CTRL block) -------------------
 * ASCII -> Atari KBCODE (bit6 = Shift, bit7 = Ctrl); 0xFF = no Atari key.
 * Letters map to the unshifted key so the Atari's power-on caps gives uppercase
 * (BASIC-friendly).  Injection = KBCODE down then all-keys-up (the release
 * stops the OS auto-repeat); Ctrl-C = the Atari BREAK key.  The desktop routes
 * keys here (SYS_kbd_6502) while an emulator window is topped. */
#define KBD_INJECT  (GP0_BASE + 0x30Cu)     /* W: KBCODE + POKEY IRQ  */
#define KBD_RELEASE (GP0_BASE + 0x310u)     /* W: all keys up         */
#define KBD_BREAK   (GP0_BASE + 0x314u)     /* W: Atari BREAK         */

static uint8_t ascii_to_kbcode(int c)
{
    static const uint8_t LET[26] = {  /* A..Z key codes */
      0x3F,0x15,0x12,0x3A,0x2A,0x38,0x3D,0x39,0x0D,0x01,0x05,0x00,0x25,
      0x23,0x08,0x0A,0x2F,0x28,0x3E,0x2D,0x0B,0x10,0x2E,0x16,0x2B,0x17 };
    static const uint8_t DIG[10] = {  /* 0..9 unshifted */
      0x32,0x1F,0x1E,0x1A,0x18,0x1D,0x1B,0x33,0x35,0x30 };
    if (c >= 'a' && c <= 'z') return LET[c - 'a'];
    if (c >= 'A' && c <= 'Z') return LET[c - 'A'];   /* both -> uppercase */
    if (c >= '0' && c <= '9') return DIG[c - '0'];
    switch (c) {
      case ' ':  return 0x21;
      case '\r': case '\n': return 0x0C;             /* Return */
      case 0x08: case 0x7F: return 0x34;             /* Backspace/Delete */
      case '\t': return 0x2C;                        /* Tab */
      case 0x1B: return 0x1C;                        /* Esc */
      case '-': return 0x0E;  case '=': return 0x0F;  case ';': return 0x02;
      case ',': return 0x20;  case '.': return 0x22;  case '/': return 0x26;
      case '+': return 0x06;  case '*': return 0x07;  case '<': return 0x36;
      case '>': return 0x37;
      case '!': return 0x1F|0x40;  case '"': return 0x1E|0x40;
      case '#': return 0x1A|0x40;  case '$': return 0x18|0x40;
      case '%': return 0x1D|0x40;  case '&': return 0x1B|0x40;
      case '\'':return 0x33|0x40;  case '@': return 0x35|0x40;
      case '(': return 0x30|0x40;  case ')': return 0x32|0x40;
      case ':': return 0x02|0x40;  case '?': return 0x26|0x40;
      case '[': return 0x20|0x40;  case ']': return 0x22|0x40;
      case '_': return 0x0E|0x40;  case '|': return 0x0F|0x40;
      case '\\':return 0x06|0x40;  case '^': return 0x07|0x40;
      default:  return 0xFF;
    }
}

/* Keyboard injection into the 6502 is split into a PACE step and an INJECT step
 * so the meter delay lands BEFORE the key it protects.  POKEY's KBCODE is a
 * single latch the Atari OS reads once per VBLANK (with KEYDEL debounce), so
 * injecting at serial ring-drain speed overwrites keys before the 6502 reads
 * them — a fast paste loses almost everything.  Pace values ported from the
 * vitis serial-paste bridge, then halved in rate for margin: ~40 ms base
 * (~25 cps), 120 ms before a REPEATED key (beat the KEYDEL debounce, else the
 * second identical char is dropped, e.g. PEEK -> PEK), 200 ms after Return (let
 * BASIC tokenize the line).  The repeat/
 * tokenize gaps must PRECEDE the key, so they key off the PREVIOUS char — a
 * lookahead like the vitis peek, done as look-behind since we get one char at a
 * time.  The SYS_kbd_6502 handler waits kbd_6502_pace() ms, then calls
 * kbd_6502_inject(); the wait blocks the desktop task, back-pressuring the ring
 * drain.  CR/LF collapse: terminals send \r\n (or \n\r) per line and BOTH map to
 * Return, so the pace step swallows the second half of a pair — else every Enter
 * injects two Returns (the old debounce used to hide the duplicate; correct
 * pacing exposes it). */
int kbd_6502_pace(int c)                 /* ms to wait BEFORE this key; -1 = no Atari key */
{
    static uint8_t prev_kb = 0xFF;       /* previous injected KBCODE (0xFF = none) */
    static int     prev_ret;             /* previous key was Return */
    static int     prev_eol;             /* CR/LF collapse: 0 none, 1 saw CR, 2 saw LF */
    if (c == 0x03) { prev_kb = 0xFF; prev_ret = 0; prev_eol = 0; return 40; }  /* Ctrl-C = BREAK */
    if (c == '\r')      { if (prev_eol == 2) { prev_eol = 0; return -1; } prev_eol = 1; }  /* \n\r pair */
    else if (c == '\n') { if (prev_eol == 1) { prev_eol = 0; return -1; } prev_eol = 2; }  /* \r\n pair */
    else                  prev_eol = 0;
    uint8_t kb = ascii_to_kbcode(c);
    if (kb == 0xFFu) return -1;
    int ms = prev_ret ? 200 : (kb == prev_kb) ? 120 : 40;
    prev_kb = kb; prev_ret = (c == '\r' || c == '\n');
    return ms;
}
void kbd_6502_inject(int c)              /* the actual POKEY write, after the pace wait */
{
    if (c == 0x03) { *(volatile uint8_t *)KBD_BREAK = 0; return; }
    uint8_t kb = ascii_to_kbcode(c);
    if (kb == 0xFFu) return;
    *(volatile uint8_t *)KBD_INJECT  = kb;
    *(volatile uint8_t *)KBD_RELEASE = 0;
}

/* Serial "mouse", two sources:
 *
 * 1. The TERMINAL'S mouse: on every focus flip to the desktop we switch the
 *    terminal into button-event tracking (CSI ?1002h: press/release + motion
 *    while a button is held), request SGR encoding (CSI ?1006h), and query the
 *    text-area size (CSI 18t -> CSI 8;rows;cols t) to map terminal cells onto
 *    the 1920x1080 desktop.  BOTH report encodings are decoded — SGR
 *    (CSI < b;x;y M/m) and legacy X10 (CSI M b x y, byte-32) — since terminals
 *    that accept ?1002h but not ?1006h fall back to the latter.
 * 2. Keyboard fallback: cursor keys move the pointer; Enter = a click (down
 *    now, up on the next call — a double-click is Enter Enter); SPACE toggles
 *    the button (press-hold-release = drag).
 *
 * `raw` (SYS_input arg 2, set by the desktop while an emulator window is
 * topped) disables the Enter/Space button synthesis so those characters TYPE
 * into the emulated machine; the mouse and the arrow keys still work.
 *
 * Runs kernel-side in the deferral thunk (task context) so con_tty_readc may block.
 * klog markers ("mouse: ...") make the handshake visible in dmesg.
 * (Terminal caveat: mouse reporting stays on while the desktop runs; if focus
 * is toggled to the shell, mousing spews CSI bytes at it — known cosmetic.) */
#define CUR_STEP 16
static int s_pend_up;
static int s_btn;                       /* space-toggle / SGR button state */
static int s_mouse_gen = -1;            /* focus generation the enable was sent under */
static int s_cols = 80, s_rows = 24;    /* terminal text area (CSI 18t reply) */
/* SGR-PIXELS (?1016): the terminal reports mouse coordinates in text-area PIXELS instead of
 * cells — same ~cadence, ~17x finer horizontal granularity. Three-part handshake, each part
 * defensive because terminals lie by omission:
 *   - we ARM 1016 (a terminal that lacks it ignores the sequence and keeps sending cells);
 *   - we query CSI 14t for the text area's PIXEL size (the scale denominator);
 *   - we believe reports are pixels only after one PROVES it by exceeding the cell grid
 *     (there is no ACK for 1016 — a coord like x=53 could be either unit, but x=800 in a
 *     109-column terminal can only be pixels). Until then cells are assumed, which is right
 *     either way near the origin and self-corrects on the first real movement. */
static int s_pxw, s_pxh;                /* terminal text area in pixels (CSI 14t reply) */
static int s_sgr_pixels;                /* latched: this terminal's reports are PIXELS */
static int s_saw_report;                /* first mouse report logged once */

extern void puts0(const char *);
extern int  con_focus_gen(void);       /* uart1_rx.c: bumps on each flip TO the desktop */
extern void klog(const char *);         /* frtos_os.c: kernel log -> dmesg */
extern void klog_u(unsigned);

/* read a decimal int from the desktop queue; returns the terminating char
 * (or -1 on timeout) with the value in *v */
static int rd_int(int *v) {
    int n = 0, c;
    for (;;) {
        c = con_gui_readc_timeout(50);
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
/* SGR coordinate -> screen pixel, in whatever unit this terminal actually sends. A report
 * beyond the cell grid LATCHES pixel mode (the only proof there is — 1016 has no ACK); the
 * scale denominator is the 14t text-area pixel size. No 14t reply = stay in cell mode. */
static void sgr2px(int cx, int cy, int *px, int *py) {
    if (!s_sgr_pixels && s_pxw > 0 && s_pxh > 0
        && (cx > s_cols + 1 || cy > s_rows + 1)) {
        s_sgr_pixels = 1;
        klog("[mouse] PIXEL reports confirmed (?1016)\r\n");
    }
    if (s_sgr_pixels) {
        int x = (cx - 1) * 1920 / (s_pxw > 0 ? s_pxw : 1920);
        int y = (cy - 1) * 1080 / (s_pxh > 0 ? s_pxh : 1080);
        if (x < 0) x = 0; if (x > 1919) x = 1919;
        if (y < 0) y = 0; if (y > 1079) y = 1079;
        *px = x; *py = y;
    } else {
        *px = cell2px(cx, s_cols, 1920);
        *py = cell2px(cy, s_rows, 1080);
    }
}
static void mouse_rearm(void) {
    int g = con_focus_gen();
    if (g == s_mouse_gen) return;
    s_mouse_gen = g;
    if (g == 0) return;   /* boot-time arm: focus is still the shell — the
                           * terminal's replies would land there as garbage
                           * ("22;80t" at the prompt); wait for the backtick */
    /* ?1000 = press/release (the floor every mouse-capable terminal has);
     * ?1002 = + motion while a button is held (what DRAG needs) — layered so a
     * terminal without 1002 still reports clicks; ?1006 = SGR encoding (we
     * decode legacy X10 too, for terminals that ignore 1006). */
    puts0("\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1016h");   /* 1016 = SGR-PIXELS, if honoured */
    puts0("\x1b[18t");                  /* -> ESC [ 8 ; rows ; cols t */
    puts0("\x1b[14t");                  /* -> ESC [ 4 ; height ; width t (text area PIXELS) */
    klog("mouse: reporting armed (gen "); klog_u((unsigned)g); klog(")\r\n");
}
/* deliver one decoded mouse action (both encodings converge here) */
static int mouse_event(struct os_event *ev, int x, int y, int kind /*0=up 1=down 2=motion*/) {
    if (!s_saw_report) { s_saw_report = 1; klog("[mouse] terminal reports ARRIVING\r\n"); }
    cursor_move(x, y);
    ev->mx = x; ev->my = y;
    if      (kind == 0) { s_btn = 0; ev->type = OS_EV_BTN_UP;   ev->button = 0; }
    else if (kind == 1) { s_btn = 1; ev->type = OS_EV_BTN_DOWN; ev->button = 1; }
    else                {            ev->type = OS_EV_MOTION;   ev->button = s_btn; }
    return 0;
}

/* one full left-click at the cursor: down now, up on the next call (Enter/Tab) */
static int click_event(struct os_event *ev) {
    ev->type = OS_EV_BTN_DOWN; ev->button = 1; s_btn = 1; s_pend_up = 1;
    cursor_pos(&ev->mx, &ev->my); return 0;
}

int input_next_event(struct os_event *ev, int timeout_ms, int raw) {
    ev->shift = 0; ev->key = 0; ev->wheel = 0;
    if (s_pend_up) { s_pend_up = 0; s_btn = 0; ev->type = OS_EV_BTN_UP; ev->button = 0; cursor_pos(&ev->mx, &ev->my); return 0; }

    for (;;) {
        /* re-arm INSIDE the loop: the desktop blocks here for the next byte, and
         * the flip-to-desktop wake byte (uart1_rx pushes 0x00) must re-hook the
         * terminal while the replies can actually reach OUR queue (the desktop
         * is boot-spawned; focus defaults to the shell, so the boot-time enable
         * was answered into the shell's queue). */
        mouse_rearm();
        int c = con_gui_readc_timeout(timeout_ms);
        if (c < 0) { ev->type = OS_EV_TIMER; ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0; }
        if (c == 0)  continue;                        /* focus-flip wake sentinel */

        if (c == 0x1b) {                              /* ESC: CSI or a bare Escape */
            int c1 = con_gui_readc_timeout(30);
            if (c1 != '[') { ev->type = OS_EV_KEY; ev->key = 0x1b; ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0; }
            int c2 = con_gui_readc_timeout(50);

            if (c2 == '<') {                          /* SGR mouse: <b;x;yM / <b;x;ym */
                int b, cx, cy, t;
                if (rd_int(&b) != ';') continue;
                if (rd_int(&cx) != ';') continue;
                t = rd_int(&cy);
                if (t != 'M' && t != 'm') continue;
                if (b & 64) {                         /* wheel: 64 = away/up (+1), 65 = toward (-1) */
                    int wx, wy;
                    if (t != 'M') continue;           /* wheels only press */
                    sgr2px(cx, cy, &wx, &wy);
                    cursor_move(wx, wy);
                    ev->type = OS_EV_WHEEL; ev->wheel = (b & 1) ? -1 : 1;
                    ev->button = s_btn; cursor_pos(&ev->mx, &ev->my);
                    return 0;
                }
                { int mx2, my2; sgr2px(cx, cy, &mx2, &my2);
                  return mouse_event(ev, mx2, my2, (t == 'm') ? 0 : (b & 32) ? 2 : 1); }
            }
            if (c2 == 'M') {                          /* legacy X10 mouse: M b x y (byte-32) */
                int b = con_gui_readc_timeout(50), cx = con_gui_readc_timeout(50), cy = con_gui_readc_timeout(50);
                if (b < 0 || cx < 0 || cy < 0) continue;
                b -= 32; cx -= 32; cy -= 32;
                if (b & 64) {                         /* wheel, same mapping as SGR */
                    cursor_move(cell2px(cx, s_cols, 1920), cell2px(cy, s_rows, 1080));
                    ev->type = OS_EV_WHEEL; ev->wheel = (b & 1) ? -1 : 1;
                    ev->button = s_btn; cursor_pos(&ev->mx, &ev->my);
                    return 0;
                }
                int kind = ((b & 3) == 3) ? 0 : (b & 32) ? 2 : 1;
                return mouse_event(ev, cell2px(cx, s_cols, 1920), cell2px(cy, s_rows, 1080), kind);
            }
            if (c2 >= '0' && c2 <= '9') {             /* CSI n... — the 18t / 14t size replies */
                int n1 = c2 - '0', n2, n3, t;
                for (;;) { t = con_gui_readc_timeout(50);
                           if (t < '0' || t > '9') break; n1 = n1 * 10 + (t - '0'); }
                if (t == ';' && n1 == 8) {
                    if (rd_int(&n2) == ';' && rd_int(&n3) == 't' && n2 > 0 && n3 > 0) {
                        s_rows = n2; s_cols = n3;
                        klog("mouse: terminal is "); klog_u((unsigned)n3);
                        klog("x"); klog_u((unsigned)n2); klog(" cells\r\n");
                    }
                } else if (t == ';' && n1 == 4) {     /* text area pixel size: the 1016 scale */
                    if (rd_int(&n2) == ';' && rd_int(&n3) == 't' && n2 > 0 && n3 > 0) {
                        s_pxh = n2; s_pxw = n3;
                        klog("mouse: terminal is "); klog_u((unsigned)n3);
                        klog("x"); klog_u((unsigned)n2); klog(" px\r\n");
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
        if (c == 0x09) return click_event(ev);        /* Tab: click — a single clean byte,
                                                       * fires even while the emu holds the
                                                       * grab (unlike Enter/Space) and can't
                                                       * be swallowed/mis-parsed like End was */
        if (c == '\\' || (!raw && c == ' ')) {        /* press-and-hold toggle (drag): '\' is a
                                                       * non-Atari key so it works even while an
                                                       * emu window holds the grab (Space can't);
                                                       * toggle down -> arrow-move -> toggle up */
            cursor_pos(&ev->mx, &ev->my);
            if (!s_btn) { s_btn = 1; ev->type = OS_EV_BTN_DOWN; ev->button = 1; }
            else        { s_btn = 0; ev->type = OS_EV_BTN_UP;   ev->button = 0; }
            return 0;
        }
        if (!raw && (c == '\r' || c == '\n')) return click_event(ev);   /* Enter: click */
        /* The terminal can't send scancodes or a real modifier state, but it CAN
         * infer Ctrl: bytes 0x01-0x1A are Ctrl+letter.  Report them as the plain
         * letter + K_CTRL (0x04) so mnemonics / the field editor's Ctrl-U see
         * them — the documented graceful degradation (arrows/Tab still special,
         * everything else 0).  Exclude the keys already carried literally:
         * Backspace (0x08), Tab (0x09, handled above), LF (0x0A), CR (0x0D). */
        ev->type = OS_EV_KEY; ev->key = c; ev->shift = 0;
        if (c >= 0x01 && c <= 0x1A && c != 0x08 && c != 0x0A && c != 0x0D) {
            ev->key = c + 0x60;                       /* 0x01 -> 'a' ... */
            ev->shift = 0x04;                         /* K_CTRL */
        }
        ev->button = s_btn; cursor_pos(&ev->mx, &ev->my); return 0;
    }
}

#else   /* qemu: no sprite engine / input / POKEY */
int input_next_event(struct os_event *ev, int timeout_ms, int raw) {
    (void)timeout_ms; (void)raw; ev->type = OS_EV_TIMER; ev->button = 0; ev->mx = ev->my = 0; return 0;
}
int  kbd_6502_pace(int c)   { (void)c; return -1; }
void kbd_6502_inject(int c) { (void)c; }
void cursor_move(int x, int y) { (void)x; (void)y; }   /* no HW cursor sprite on qemu; the UDP  */
void cursor_pos(int *x, int *y) { *x = 0; *y = 0; }    /* mouse (net/input_udp.c) still links   */
#endif
