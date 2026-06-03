/* tusb_config.h — TinyUSB host config for the Zynq-7000 PS USB0 (xtos). */
#ifndef _TUSB_CONFIG_H_
#define _TUSB_CONFIG_H_

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Controller / OS -------------------------------------------------- */
#define CFG_TUSB_MCU              OPT_MCU_ZYNQ7000   /* ci_hs/EHCI, ci_hs_zynq.h */
#define CFG_TUSB_OS               OPT_OS_NONE        /* bare-metal */
/* Enumeration works; logging off.  Set to 1/2 to re-enable TinyUSB tracing
 * (incl. the >>ARM/PE/CTRL/REAP/EDPT bring-up probes, which are TU_LOG1) — it
 * routes via usb_logf() (vsnprintf -> xil_printf) since the BSP xil_printf is
 * void but TinyUSB's hook must return int. */
extern int usb_logf(const char *fmt, ...);
#define CFG_TUSB_DEBUG            0
#define CFG_TUSB_DEBUG_PRINTF     usb_logf

/* EHCI DMA structures live in (cached) DDR on the A9, so dcache management is
 * mandatory; the app provides strong hcd_dcache_* (-> Xil_DCache*) overriding
 * ehci.c's weak no-ops.  A9 L1 D-cache line = 32 bytes. */
#define CFG_TUH_MEM_DCACHE_ENABLE 1
#define CFG_TUH_MEM_DCACHE_LINE_SIZE 32

/* DMA objects live in normal CACHED .bss; coherency is via the strong
 * hcd_dcache_clean/invalidate hooks (Xil_DCacheFlush/InvalidateRange) — the
 * approach the working Zynq TinyUSB port uses ("all RAM operated by the HCD &
 * USB controller need a cache flush", hathach/tinyusb#62). 32-byte aligned. */
#define CFG_TUSB_MEM_SECTION
#define CFG_TUSB_MEM_ALIGN        __attribute__((aligned(CFG_TUH_MEM_DCACHE_LINE_SIZE)))

/* ---- Host -------------------------------------------------------------- */
#define CFG_TUH_ENABLED           1
#define CFG_TUH_MAX_SPEED         OPT_MODE_HIGH_SPEED
#define BOARD_TUH_RHPORT          0                  /* USB0 = 0xE0002000 */

#define CFG_TUH_HUB               4                  /* nested hubs (USB-3 hub = compound device w/ inner hubs) */
#define CFG_TUH_HID               4                  /* up to 4 HID interfaces (kbd+mouse+) */
/* device count: nested hubs + downstream devices need plenty of address slots */
#define CFG_TUH_DEVICE_MAX        8
#define CFG_TUH_ENUMERATION_BUFSIZE 256

#define CFG_TUH_HID_EPIN_BUFSIZE  64
#define CFG_TUH_HID_EPOUT_BUFSIZE 64

#ifdef __cplusplus
}
#endif

#endif
