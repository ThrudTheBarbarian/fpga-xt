/* keymap.c — USB HID keyboard -> Atari key, positionally.
 *
 * The mapping is by KEY, not by character: pressing the PC key legended "2"
 * presses the Atari's "2" key, so shifting it gives whatever the Atari's
 * keyboard gives (a double-quote), not what the PC's does. That is what makes
 * the machine behave like the machine. The layouts agree more than they differ
 * — ":" really is shift-semicolon on both — but the number row diverges (Atari
 * shift-6 is "&", shift-7 is "'", shift-8 is "@") and following the Atari is
 * the point.
 *
 * KBCODE values come from the machine's own ROM: TCKD, the table of character
 * key definitions at $FB51 in the XL OS (refs/OS-xl-rev-2-Disassembly.lst).
 * That table's index is also the authority for the modifier bits — shift is
 * bit 6, ctrl is bit 7.
 *
 * The table lives in RAM and is replaceable a byte at a time over the SPI link
 * (SPI_REG_KEYMAP_IDX / _VAL), so the Desktop can ship international layouts
 * without new firmware. What is here is only the default.
 *
 * Physical-row correspondence, which is where the punctuation choices come
 * from — the Atari has two keys the PC does not (+ and *) and lacks four the
 * PC has ([ ] ' \), so the rows are lined up and the leftovers paired off:
 *
 *   Atari  ESC 1..0 <   >   BKSP        PC  ESC 1..0 -  =  BKSP
 *   Atari  TAB Q..P -   =   RETURN      PC  TAB Q..P [  ]  \
 *   Atari  CTL A..L ;   +   *    CAPS   PC  CAP A..L ;  '  RETURN
 *   Atari  SHF Z..M ,   .   /    ATARI  PC  SHF Z..M ,  .  /
 */
#include "keymap.h"

/* ------------------------------------------------- Atari matrix keycodes ---*/

#define K_L     0x00
#define K_J     0x01
#define K_SEMI  0x02
#define K_K     0x05
#define K_PLUS  0x06
#define K_STAR  0x07
#define K_O     0x08
#define K_P     0x0A
#define K_U     0x0B
#define K_RET   0x0C
#define K_I     0x0D
#define K_MINUS 0x0E
#define K_EQUAL 0x0F
#define K_V     0x10
#define K_HELP  0x11
#define K_C     0x12
#define K_B     0x15
#define K_X     0x16
#define K_Z     0x17
#define K_4     0x18
#define K_3     0x1A
#define K_6     0x1B
#define K_ESC   0x1C
#define K_5     0x1D
#define K_2     0x1E
#define K_1     0x1F
#define K_COMMA 0x20
#define K_SPACE 0x21
#define K_DOT   0x22
#define K_N     0x23
#define K_M     0x25
#define K_SLASH 0x26
#define K_INV   0x27            /* the Atari (inverse video) key */
#define K_R     0x28
#define K_E     0x2A
#define K_Y     0x2B
#define K_TAB   0x2C
#define K_T     0x2D
#define K_W     0x2E
#define K_Q     0x2F
#define K_9     0x30
#define K_0     0x32
#define K_7     0x33
#define K_BKSP  0x34
#define K_8     0x35
#define K_LESS  0x36            /* CLEAR when shifted  */
#define K_GT    0x37            /* INSERT when shifted */
#define K_F     0x38
#define K_H     0x39
#define K_D     0x3A
#define K_CAPS  0x3C
#define K_G     0x3D
#define K_S     0x3E
#define K_A     0x3F

/* Arrows are ctrl-<key> on this keyboard, so the PC arrow keys map to the
 * matching key with ctrl already folded in. */
#define K_UP    (K_MINUS | KEYMAP_CTRL)
#define K_DOWN  (K_EQUAL | KEYMAP_CTRL)
#define K_LEFT  (K_PLUS  | KEYMAP_CTRL)
#define K_RIGHT (K_STAR  | KEYMAP_CTRL)

#define __      KEYMAP_NONE

static uint8_t s_map[KEYMAP_SIZE];

static const uint8_t s_default[KEYMAP_SIZE] = {
    /* 0x00 */ __, __, __, __,
    /* 0x04 a..z, in HID order */
    K_A, K_B, K_C, K_D, K_E, K_F, K_G, K_H, K_I, K_J, K_K, K_L, K_M,
    K_N, K_O, K_P, K_Q, K_R, K_S, K_T, K_U, K_V, K_W, K_X, K_Y, K_Z,
    /* 0x1E 1..9 0 */
    K_1, K_2, K_3, K_4, K_5, K_6, K_7, K_8, K_9, K_0,
    /* 0x28 */ K_RET, K_ESC, K_BKSP, K_TAB, K_SPACE,
    /* 0x2D - =  : the Atari's top row ends < > where the PC's ends - = */
    K_LESS, K_GT,
    /* 0x2F [ ]  : the Atari's second row ends - = where the PC's ends [ ] */
    K_MINUS, K_EQUAL,
    /* 0x31 backslash : nothing there on the Atari; give it the * key, which
     * BASIC needs and which the PC has nowhere else */
    K_STAR,
    /* 0x32 non-US #  */ K_STAR,
    /* 0x33 ; 0x34 '  : ' sits where the Atari's + does */
    K_SEMI, K_PLUS,
    /* 0x35 grave : no Atari equivalent, so give it the Atari/inverse key */
    K_INV,
    /* 0x36 , 0x37 . 0x38 / */
    K_COMMA, K_DOT, K_SLASH,
    /* 0x39 caps lock */ K_CAPS,
    /* 0x3A F1..F12 — console keys follow the emulator convention, so F1 and
     * the 1200XL's F-key codes lose out to OPTION/SELECT/START/RESET */
    __, KEYMAP_OPTION, KEYMAP_SELECT, KEYMAP_START, KEYMAP_RESET,
    K_HELP, KEYMAP_BREAK, __, __, __, __, KEYMAP_BREAK,
    /* 0x46 printscreen, scroll lock, pause */ __, __, __,
    /* 0x49 insert, home, pageup, delete, end, pagedown */
    (K_GT | KEYMAP_SHIFT), (K_LESS | KEYMAP_SHIFT), __,
    (K_BKSP | KEYMAP_SHIFT), __, __,
    /* 0x4F right, left, down, up */
    K_RIGHT, K_LEFT, K_DOWN, K_UP,
    /* 0x53 num lock */ __,
    /* 0x54 KP / * - +  : matches the xtmouse keypad convention already in
     * CTRL_CONSOL — KP_* is OPTION, KP_- is SELECT, KP_+ is START */
    K_SLASH, KEYMAP_OPTION, KEYMAP_SELECT, KEYMAP_START,
    /* 0x58 KP enter, KP 1..9, KP 0, KP . */
    K_RET, K_1, K_2, K_3, K_4, K_5, K_6, K_7, K_8, K_9, K_0, K_DOT,
};

void keymap_init(void)
{
    keymap_reset();
}

void keymap_reset(void)
{
    for (unsigned i = 0; i < KEYMAP_SIZE; i++)
        s_map[i] = i < sizeof s_default ? s_default[i] : KEYMAP_NONE;
}

void keymap_set(uint8_t usage, uint8_t value)
{
    s_map[usage] = value;
}

uint8_t keymap_get(uint8_t usage)
{
    return s_map[usage];
}

int keymap_lookup(uint8_t usage, uint8_t modifiers, uint8_t *out)
{
    uint8_t v = s_map[usage];

    if (v == KEYMAP_NONE)
        return KEYMAP_R_NONE;

    /* BOTH modifier bits, not either: a plain ctrl-key entry (the arrows carry
     * one) has bit 7 set and is not special. */
    if ((v & KEYMAP_SPECIAL) == KEYMAP_SPECIAL) {
        *out = v;
        return KEYMAP_R_SPECIAL;
    }

    /* Modifiers from the host are OR'd onto whatever the table already carries
     * — the arrow keys, for instance, arrive with ctrl already set. */
    if (modifiers & (HID_MOD_LSHIFT | HID_MOD_RSHIFT))
        v |= KEYMAP_SHIFT;
    if (modifiers & (HID_MOD_LCTRL | HID_MOD_RCTRL))
        v |= KEYMAP_CTRL;

    *out = v;
    return KEYMAP_R_KEY;
}
