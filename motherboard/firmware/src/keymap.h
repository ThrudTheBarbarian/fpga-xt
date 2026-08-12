/* keymap.h — see keymap.c */
#ifndef KEYMAP_H
#define KEYMAP_H

#include <stdint.h>

/* HID boot-protocol modifier bits (report byte 0) */
#define HID_MOD_LCTRL   0x01
#define HID_MOD_LSHIFT  0x02
#define HID_MOD_LALT    0x04
#define HID_MOD_RCTRL   0x10
#define HID_MOD_RSHIFT  0x20

/* HID usages we treat specially */
#define HID_KEY_ENTER       0x28
#define HID_KEY_ESCAPE      0x29
#define HID_KEY_BACKSPACE   0x2A
#define HID_KEY_TAB         0x2B
#define HID_KEY_CAPSLOCK    0x39
#define HID_KEY_F1          0x3A
#define HID_KEY_F2          0x3B
#define HID_KEY_F3          0x3C
#define HID_KEY_F4          0x3D
#define HID_KEY_F11         0x44
#define HID_KEY_F12         0x45

enum {
    KEYMAP_NONE = 0,        /* no Atari equivalent  */
    KEYMAP_KEY,             /* *out is a KBCODE     */
    KEYMAP_BREAK            /* the BREAK key        */
};

/* Returns one of the KEYMAP_* codes above; *out is the Atari KBCODE with
 * shift in bit 6 and ctrl in bit 7. */
int keymap_hid_to_atari(uint8_t usage, uint8_t modifiers, uint8_t *out);

#endif /* KEYMAP_H */
