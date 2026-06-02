/* usb_hid.c — TinyUSB host bring-up on the Zynq-7000 PS USB0 (ci_hs/EHCI).
 *
 * Poll-mode: usb_hid_task() drives tuh_int_handler() + tuh_task() from the main
 * loop, so no GIC wiring is needed to enumerate (see ci_hs_zynq.h).  EHCI walks
 * its DMA structures in cached DDR on the A9, so the weak hcd_dcache_* hooks in
 * ehci.c are overridden here with Xil_DCache* (A9 flush = clean+invalidate).
 *
 * For now the HID callbacks just print over UART; routing keyboard -> POKEY
 * KBCODE/IRQ and mouse -> the Atari follows once enumeration is proven.
 */

#include <stdint.h>
#include "xil_types.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"        /* XTime_GetTime / COUNTS_PER_SECOND (this BSP uses xiltimer, not xtime_l.h) */

#include "tusb.h"
#include "usb_hid.h"

/* ---- TinyUSB time base (app-provided) --------------------------------- */
/* The host stack times enumeration/transfers in ms.  Derive it from the A9
 * global timer (free-running, COUNTS_PER_SECOND ticks/s). */
uint32_t tusb_time_millis_api(void) {
  XTime now;
  XTime_GetTime(&now);
  return (uint32_t)(now / (COUNTS_PER_SECOND / 1000ULL));
}

/* ---- EHCI dcache hooks (override ehci.c's TU_ATTR_WEAK no-ops) --------- */
bool hcd_dcache_clean(void const *addr, uint32_t data_size) {
  Xil_DCacheFlushRange((INTPTR)addr, (INTPTR)data_size);   /* A9: clean+invalidate */
  return true;
}
bool hcd_dcache_invalidate(void const *addr, uint32_t data_size) {
  Xil_DCacheInvalidateRange((INTPTR)addr, (INTPTR)data_size);
  return true;
}
bool hcd_dcache_clean_invalidate(void const *addr, uint32_t data_size) {
  Xil_DCacheFlushRange((INTPTR)addr, (INTPTR)data_size);
  return true;
}

/* ---- bring-up / poll -------------------------------------------------- */
void usb_hid_init(void) {
  /* TODO(runtime): if enumeration won't start, add a USB3320 ULPI PHY reset and
   * force the controller to host mode here before tuh_init.  hcd_init (called
   * by tuh_init) resets the controller and starts the EHCI schedule. */
  tuh_init(BOARD_TUH_RHPORT);
  xil_printf("USB: host init on USB0 (rhport %u) — waiting for a device\r\n",
             BOARD_TUH_RHPORT);
}

void usb_hid_task(void) {
  tuh_int_handler(BOARD_TUH_RHPORT, false);   /* poll the controller */
  tuh_task();                                 /* process queued host events */
}

/* ---- host callbacks (print over UART; -> POKEY/Atari later) ----------- */
void tuh_mount_cb(uint8_t dev_addr) {
  xil_printf("\r\nUSB: device mounted (addr %u)\r\n> ", dev_addr);
}

void tuh_umount_cb(uint8_t dev_addr) {
  xil_printf("\r\nUSB: device unmounted (addr %u)\r\n> ", dev_addr);
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *desc_report, uint16_t desc_len) {
  (void)desc_report;
  (void)desc_len;
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);
  xil_printf("\r\nUSB-HID mount: addr %u inst %u proto %u (1=kbd 2=mouse)\r\n> ",
             dev_addr, instance, proto);
  tuh_hid_receive_report(dev_addr, instance);   /* arm the first report */
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance) {
  xil_printf("\r\nUSB-HID umount: addr %u inst %u\r\n> ", dev_addr, instance);
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);

  if (proto == HID_ITF_PROTOCOL_KEYBOARD && len >= 8) {
    xil_printf("KBD mods=%02x keys=%02x %02x %02x %02x %02x %02x\r\n",
               report[0], report[2], report[3], report[4],
               report[5], report[6], report[7]);
  } else if (proto == HID_ITF_PROTOCOL_MOUSE && len >= 3) {
    xil_printf("MOUSE btn=%02x dx=%d dy=%d\r\n",
               report[0], (int)(int8_t)report[1], (int)(int8_t)report[2]);
  } else {
    xil_printf("HID report inst=%u len=%u\r\n", instance, len);
  }

  tuh_hid_receive_report(dev_addr, instance);   /* re-arm */
}
