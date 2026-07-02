/*
 * sprite.c — A9 hardware sprite-engine driver + the GEM mouse cursor (kernel/PL1;
 * GP0 at 0x43C0_0000 is a Device peripheral, PL0-none, so the cursor is owned
 * here and the PL0 desktop asks for it via syscalls).  Ported from
 * vitis/xtos/src/sprite.c.  The sprite arena (0x3400_0000) is Normal
 * NON-cacheable here (SEC_PLANE), so a dsb — not a cache flush — orders the arena
 * writes before the fetcher (HP2) reads them.
 */
#ifdef XT_HW
#include <stdint.h>

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

#else
typedef int sprite_translation_unit_not_empty;        /* qemu: no sprite engine */
#endif
