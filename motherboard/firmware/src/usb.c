/* usb.c — USB-HID host on OTG-FS.
 *
 * The board's USB port goes to an on-board 4-way hub, so essentially every
 * device is behind at least one hub and a compound keyboard can be behind two.
 * That is the whole reason CFG_TUH_HUB and the device pool are sized the way
 * they are in tusb_config.h — an under-sized pool asserts deep inside address
 * assignment rather than failing politely.
 *
 * Pin-wise this is nearly free: PA11/PA12 are DM/DP on AF10 and that is all the
 * core needs.  PA9, which would normally be OTG_FS_VBUS, carries HUB_RST on
 * this board instead — so there is no VBUS sensing and the hub, being
 * self-powered from the board rail, owns VBUS and overcurrent itself.
 */
#include "usb.h"

#include <stdarg.h>

#include "board.h"
#include "clock.h"
#include "console.h"
#include "keymap.h"
#include "spi_link.h"
#include "tusb.h"

/* dwc2_remote_wakeup_delay() spins on this; see compat/stm32f4xx.h */
uint32_t SystemCoreClock = SYSCLK_HZ;

/* TinyUSB's TU_LOG sink.  It wants a printf that returns an int; ours does not
 * report a length and nothing in the stack checks it. */
int usb_log_printf(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    console_vprintf(fmt, ap);
    va_end(ap);
    return 0;
}

#define KEY_RING        16

static int      s_started;
static uint8_t  s_mounted[CFG_TUH_DEVICE_MAX + 1];
static uint16_t s_mount_count;

static struct {
    uint8_t dev, idx, proto;
} s_hid[CFG_TUH_HID];

/* Most recent input, for the REPL until the SPI link carries it to the FPGA. */
static struct {
    uint8_t  keys[KEY_RING];
    uint8_t  modifiers;
    uint8_t  count;
    uint32_t events;
} s_kbd;

static struct {
    int32_t  x, y, wheel;
    uint8_t  buttons;
    uint32_t reports;
} s_mouse;

int usb_init(void)
{
    /* USB needs 48 MHz within 0.25%.  On the HSI fallback the PLL output is
     * nowhere near that, and a host that enumerates unreliably is worse than
     * one that says why it refused. */
    if (!clock_on_hse()) {
        console_puts("usb: refusing to start — no crystal, 48 MHz would be "
                     "out of spec\r\n");
        return -1;
    }

    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;

    gpio_af(GPIOA, PIN_USB_DM, AF_OTG_FS);
    gpio_af(GPIOA, PIN_USB_DP, AF_OTG_FS);
    gpio_speed(GPIOA, PIN_USB_DM, GPIO_SPEED_HIGH);
    gpio_speed(GPIOA, PIN_USB_DP, GPIO_SPEED_HIGH);
    gpio_pull(GPIOA, PIN_USB_DM, GPIO_PULL_NONE);
    gpio_pull(GPIOA, PIN_USB_DP, GPIO_PULL_NONE);

    RCC->AHB2ENR |= RCC_AHB2ENR_OTGFS;

    /* Above the paddle sampler and the fan: a late paddle tick costs a little
     * resolution, a late USB interrupt costs an enumeration. */
    nvic_priority(IRQ_OTG_FS, 4);

    /* Bring the hub out of reset before the core starts looking for it, and
     * give it time to settle — otherwise the first bus reset races the hub's
     * own power-on and devices come up missing. */
    board_hub_cycle();

    /* OTG-FS has no high-speed PHY, so state full-speed explicitly rather than
     * letting the stack infer it. */
    const tusb_rhport_init_t rh = {
        .role  = TUSB_ROLE_HOST,
        .speed = TUSB_SPEED_FULL,
    };

    if (!tusb_rhport_init(BOARD_TUH_RHPORT, &rh)) {
        console_puts("usb: host init failed\r\n");
        return -1;
    }

    s_started = 1;
    return 0;
}

void usb_task(void)
{
    if (s_started)
        tuh_task();
}

void otg_fs_handler(void)
{
    tuh_int_handler(BOARD_TUH_RHPORT, true);
}

/* TinyUSB's time base — it only needs milliseconds. */
uint32_t tusb_time_millis_api(void)
{
    return clock_millis();
}

void tusb_time_delay_ms_api(uint32_t ms)
{
    clock_delay_ms(ms);
}

/* ------------------------------------------------------------- mount/umount */

void tuh_mount_cb(uint8_t daddr)
{
    uint16_t vid = 0, pid = 0;
    tuh_vid_pid_get(daddr, &vid, &pid);

    if (daddr <= CFG_TUH_DEVICE_MAX)
        s_mounted[daddr] = 1;
    s_mount_count++;

    console_printf("usb: device %u mounted, %04x:%04x\r\n",
                   daddr, vid, pid);
}

void tuh_umount_cb(uint8_t daddr)
{
    if (daddr <= CFG_TUH_DEVICE_MAX)
        s_mounted[daddr] = 0;

    console_printf("usb: device %u removed\r\n", daddr);
}

/* ---------------------------------------------------------------- keyboard -*/

/* A boot-protocol report is the SET of keys currently held, not an event — so
 * the events have to be recovered by diffing against the previous report.
 * Anything in the new set that was not in the old one is a fresh press; an
 * empty set is the all-released that stops the OS auto-repeating. */
static uint8_t s_prev[6];

static int was_held(uint8_t usage)
{
    for (unsigned i = 0; i < sizeof s_prev; i++)
        if (s_prev[i] == usage)
            return 1;
    return 0;
}

static uint8_t s_consol = 0x07;     /* active low: bit0 START, 1 SELECT, 2 OPTION */

static void handle_keyboard(const uint8_t *report)
{
    uint8_t mods   = report[0];
    uint8_t consol = 0x07;
    int     held   = 0;

    s_kbd.modifiers = mods;
    s_kbd.count     = 0;

    for (int i = 2; i < 8; i++) {
        uint8_t usage = report[i];
        uint8_t v;

        if (!usage || usage == 1)               /* 1 = rollover error */
            continue;
        held++;
        if (s_kbd.count < KEY_RING)
            s_kbd.keys[s_kbd.count++] = usage;

        int kind = keymap_lookup(usage, mods, &v);

        /* Console keys are levels, not events — the 6502 reads CONSOL and sees
         * what is held right now — so they are rebuilt from every report
         * rather than diffed against the last one. */
        if (kind == KEYMAP_R_SPECIAL) {
            if (v == KEYMAP_START)  consol &= (uint8_t)~0x01;
            if (v == KEYMAP_SELECT) consol &= (uint8_t)~0x02;
            if (v == KEYMAP_OPTION) consol &= (uint8_t)~0x04;
        }

        if (was_held(usage))
            continue;                           /* still down, not a new press */

        if (kind == KEYMAP_R_KEY) {
            spi_link_post_key(v, SPI_KBD_DOWN);
            s_kbd.events++;
        } else if (kind == KEYMAP_R_SPECIAL) {
            if (v == KEYMAP_BREAK) {
                spi_link_post_key(0, SPI_KBD_BREAK);
                s_kbd.events++;
            } else if (v == KEYMAP_RESET) {
                spi_link_post_key(0, SPI_KBD_RESET);
                s_kbd.events++;
            }
        }
    }

    if (consol != s_consol) {
        s_consol = consol;
        spi_link_post_consol(consol);
    }

    if (!held && s_prev[0])
        spi_link_post_key(0, SPI_KBD_ALLUP);

    for (unsigned i = 0; i < sizeof s_prev; i++)
        s_prev[i] = report[2 + i];
}

uint8_t usb_consol(void)
{
    return s_consol;
}

/* ------------------------------------------------------------------- HID ---*/

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t idx,
                      const uint8_t *report_desc, uint16_t desc_len)
{
    (void)report_desc;
    (void)desc_len;

    uint8_t proto = tuh_hid_interface_protocol(dev_addr, idx);
    static const char *names[] = { "none", "keyboard", "mouse" };

    if (idx < CFG_TUH_HID) {
        s_hid[idx].dev   = dev_addr;
        s_hid[idx].idx   = idx;
        s_hid[idx].proto = proto;
    }

    console_printf("usb: hid %u.%u is a %s\r\n", dev_addr, idx,
                   proto <= 2 ? names[proto] : "device");

    /* Boot protocol: a fixed 8-byte keyboard / 3-byte mouse report, no report
     * descriptor parsing.  That is all the Atari side can use anyway, and it
     * sidesteps every vendor's creative idea of a report layout. */
    tuh_hid_set_protocol(dev_addr, idx, HID_PROTOCOL_BOOT);

    if (!tuh_hid_receive_report(dev_addr, idx))
        console_printf("usb: hid %u.%u would not start reporting\r\n",
                       dev_addr, idx);
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t idx)
{
    if (idx < CFG_TUH_HID && s_hid[idx].dev == dev_addr)
        s_hid[idx].proto = 0;

    console_printf("usb: hid %u.%u gone\r\n", dev_addr, idx);
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t idx,
                                const uint8_t *report, uint16_t len)
{
    switch (tuh_hid_interface_protocol(dev_addr, idx)) {
    case HID_ITF_PROTOCOL_KEYBOARD:
        if (len >= 8)
            handle_keyboard(report);
        break;

    case HID_ITF_PROTOCOL_MOUSE:
        if (len >= 3) {
            s_mouse.buttons = report[0];
            s_mouse.x      += (int8_t)report[1];
            s_mouse.y      += (int8_t)report[2];
            if (len >= 4)
                s_mouse.wheel += (int8_t)report[3];
            s_mouse.reports++;
        }
        break;

    default:
        break;
    }

    /* Reports are one-shot: ask for the next one or the device goes quiet. */
    tuh_hid_receive_report(dev_addr, idx);
}

/* -------------------------------------------------------------- reporting -*/

int usb_started(void)
{
    return s_started;
}

void usb_status(void)
{
    static const char *names[] = { "none", "keyboard", "mouse" };

    if (!s_started) {
        console_puts("usb: not started\r\n");
        return;
    }

    console_printf("mounts %u total\r\n", s_mount_count);
    for (unsigned d = 1; d <= CFG_TUH_DEVICE_MAX; d++) {
        if (!s_mounted[d])
            continue;
        uint16_t vid = 0, pid = 0;
        tuh_vid_pid_get((uint8_t)d, &vid, &pid);
        console_printf("  device %u  %04x:%04x\r\n", d, vid, pid);
    }
    for (unsigned i = 0; i < CFG_TUH_HID; i++) {
        if (!s_hid[i].proto)
            continue;
        console_printf("  hid %u.%u  %s\r\n", s_hid[i].dev, s_hid[i].idx,
                       s_hid[i].proto <= 2 ? names[s_hid[i].proto] : "device");
    }

    console_printf("keyboard  events %lu  mods %02x  keys",
                   s_kbd.events, s_kbd.modifiers);
    for (unsigned i = 0; i < s_kbd.count; i++)
        console_printf(" %02x", s_kbd.keys[i]);
    console_puts("\r\n");

    console_printf("mouse     reports %lu  x %ld  y %ld  wheel %ld  buttons %02x\r\n",
                   s_mouse.reports, s_mouse.x, s_mouse.y, s_mouse.wheel,
                   s_mouse.buttons);
}
