/* keymap.h — see keymap.c */
#ifndef KEYMAP_H
#define KEYMAP_H

#include <stdint.h>

#define KEYMAP_SIZE     256         /* one entry per HID usage */

/* Table entry encoding.  A matrix key is its KBCODE in bits 0-5 with the
 * modifiers the ROM's own table uses: shift is bit 6, ctrl is bit 7.  That
 * leaves no room for the keys which are not matrix keys at all, so those are
 * encoded as SPECIAL values — which is honest, because START/SELECT/OPTION are
 * GTIA CONSOL bits, BREAK is a separate POKEY interrupt source, and RESET is a
 * line, not a code. */
#define KEYMAP_SHIFT    0x40
#define KEYMAP_CTRL     0x80

/* Both modifier bits set marks a table entry as not-a-KBCODE.  Test for both,
 * never for either — the arrow entries legitimately carry ctrl on its own.
 * The cost is that a table entry cannot pre-set shift AND ctrl together; no
 * default needs to, and a lookup can still RETURN that combination when the
 * user holds both. */
#define KEYMAP_SPECIAL  0xC0
#define KEYMAP_BREAK    (KEYMAP_SPECIAL | 0x01)
#define KEYMAP_RESET    (KEYMAP_SPECIAL | 0x02)
#define KEYMAP_START    (KEYMAP_SPECIAL | 0x04)
#define KEYMAP_SELECT   (KEYMAP_SPECIAL | 0x08)
#define KEYMAP_OPTION   (KEYMAP_SPECIAL | 0x10)

#define KEYMAP_NONE     0xFF        /* no Atari key */

/* HID boot-protocol modifier bits (report byte 0) */
#define HID_MOD_LCTRL   0x01
#define HID_MOD_LSHIFT  0x02
#define HID_MOD_LALT    0x04
#define HID_MOD_RCTRL   0x10
#define HID_MOD_RSHIFT  0x20

enum {
    KEYMAP_R_NONE = 0,      /* nothing here                          */
    KEYMAP_R_KEY,           /* *out is a KBCODE with modifier bits   */
    KEYMAP_R_SPECIAL        /* *out is one of the KEYMAP_* specials  */
};

/* Built-in starting points; the Desktop can overwrite any entry afterwards. */
#define KEYMAP_POSITIONAL   0
#define KEYMAP_SYMBOLIC     1

void    keymap_init(void);
void    keymap_load(uint8_t layout);            /* KEYMAP_POSITIONAL|SYMBOLIC */
uint8_t keymap_layout(void);
void    keymap_set(uint8_t usage, int shifted, uint8_t value);
uint8_t keymap_get(uint8_t usage, int shifted);
int     keymap_lookup(uint8_t usage, uint8_t modifiers, uint8_t *out);

#endif /* KEYMAP_H */
