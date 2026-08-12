/* tusb_config.h — TinyUSB configuration for the I/O companion.
 *
 * Host only: this MCU never presents itself as a USB device.  Firmware update
 * goes over SWD or USART2, so the OTG-FS core is dedicated to hosting the
 * on-board 4-way hub and whatever HID gear is plugged into it.
 */
#ifndef TUSB_CONFIG_H
#define TUSB_CONFIG_H

#define CFG_TUSB_MCU                OPT_MCU_STM32F4
#define CFG_TUSB_OS                 OPT_OS_NONE
/* TinyUSB's log goes to our console (RTT and USART2), so enumeration can be
 * watched live.  Level 2 is verbose enough to see descriptor fetches; drop to 0
 * once the bus is trusted, since the formatting cost is real. */
#ifndef CFG_TUSB_DEBUG
#define CFG_TUSB_DEBUG              2
#endif
int usb_log_printf(const char *fmt, ...);
#define CFG_TUSB_DEBUG_PRINTF       usb_log_printf

/* OTG-FS is full-speed only, and PA9 carries HUB_RST rather than VBUS, so the
 * core runs with VBUS sensing off — TinyUSB forces that for host mode anyway.
 * The hub is self-powered from the board rail and owns VBUS and overcurrent. */
#define CFG_TUH_ENABLED             1
#define CFG_TUH_MAX_SPEED           OPT_MODE_FULL_SPEED
#define BOARD_TUH_RHPORT            0

/* DMA-capable memory needs no special section on this part: the F411 has no
 * data cache, so plain .bss is coherent with the USB core's bus master. */
#define CFG_TUH_MEM_SECTION
#define CFG_TUH_MEM_ALIGN           __attribute__((aligned(4)))

/* The 4-way hub on the board may well have something nested behind it, and a
 * compound device eats addresses fast — an under-sized pool asserts inside
 * tuh_address_set rather than failing gracefully, so leave headroom. */
#define CFG_TUH_HUB                 4
#define CFG_TUH_DEVICE_MAX          (CFG_TUH_HUB ? 8 : 1)

#define CFG_TUH_HID                 8   /* a keyboard alone reports 2 interfaces */
#define CFG_TUH_HID_EPIN_BUFSIZE    64
#define CFG_TUH_HID_EPOUT_BUFSIZE   64

#define CFG_TUH_ENUMERATION_BUFSIZE 256

#endif /* TUSB_CONFIG_H */
