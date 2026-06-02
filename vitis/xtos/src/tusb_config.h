/* tusb_config.h — TinyUSB host config for the Zynq-7000 PS USB0 (xtos). */
#ifndef _TUSB_CONFIG_H_
#define _TUSB_CONFIG_H_

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Controller / OS -------------------------------------------------- */
#define CFG_TUSB_MCU              OPT_MCU_ZYNQ7000   /* ci_hs/EHCI, ci_hs_zynq.h */
#define CFG_TUSB_OS               OPT_OS_NONE        /* bare-metal */
#define CFG_TUSB_DEBUG            0

/* EHCI DMA structures live in (cached) DDR on the A9, so dcache management is
 * mandatory; the app provides strong hcd_dcache_* (-> Xil_DCache*) overriding
 * ehci.c's weak no-ops.  A9 L1 D-cache line = 32 bytes. */
#define CFG_TUH_MEM_DCACHE_ENABLE 1
#define CFG_TUH_MEM_DCACHE_LINE_SIZE 32

/* DMA-capable, cache-line-aligned section for the USB transfer buffers. */
#define CFG_TUSB_MEM_SECTION
#define CFG_TUSB_MEM_ALIGN        __attribute__((aligned(CFG_TUH_MEM_DCACHE_LINE_SIZE)))

/* ---- Host -------------------------------------------------------------- */
#define CFG_TUH_ENABLED           1
#define CFG_TUH_MAX_SPEED         OPT_MODE_HIGH_SPEED
#define BOARD_TUH_RHPORT          0                  /* USB0 = 0xE0002000 */

#define CFG_TUH_HUB               1                  /* hub support (your requirement) */
#define CFG_TUH_HID               4                  /* up to 4 HID interfaces (kbd+mouse+) */
/* device count: hub fan-out -> allow a few downstream devices */
#define CFG_TUH_DEVICE_MAX        (3 * CFG_TUH_HUB + 1)
#define CFG_TUH_ENUMERATION_BUFSIZE 256

#define CFG_TUH_HID_EPIN_BUFSIZE  64
#define CFG_TUH_HID_EPOUT_BUFSIZE 64

#ifdef __cplusplus
}
#endif

#endif
