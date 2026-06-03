/* usb_hid.c — TinyUSB host on the Zynq-7000 PS USB0 (ci_hs/EHCI).
 *
 * Interrupt-driven: GIC IRQ 53 -> usb_isr() -> tuh_int_handler(0, true); the main
 * loop runs tuh_task() to service the queued events.  EHCI walks its DMA
 * structures in cached DDR on the A9, so the weak hcd_dcache_* hooks in ehci.c
 * are overridden here with Xil_DCache* (A9 flush = clean+invalidate).  TinyUSB's
 * critical sections (hcd_int_disable/enable) gate IRQ 53 via ci_hs_zynq_int_set.
 *
 * The HID callbacks print over UART; routing keyboard -> POKEY KBCODE/IRQ and
 * mouse -> the Atari is the next step.
 */

#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>           /* vsnprintf (TinyUSB log formatting) */
#include "xil_types.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"        /* XTime_GetTime / COUNTS_PER_SECOND (this BSP uses xiltimer, not xtime_l.h) */
#include "xscugic.h"         /* GIC — interrupt-driven USB (poll mode is timing-fragile on this core) */
#include "xil_exception.h"

#include "tusb.h"
#include "usb_hid.h"

#define USB0_IRQ_ID  53u     /* Zynq-7000 USB0 GIC interrupt ID */
static XScuGic s_gic;
static volatile int s_gic_ready = 0;

/* USB0 interrupt handler -> TinyUSB host int handler (in_isr=true). */
static void usb_isr(void *arg) {
  (void) arg;
  tuh_int_handler(BOARD_TUH_RHPORT, true);
}

/* CI_HCD_INT_ENABLE/DISABLE -> mask/unmask the USB0 GIC IRQ.  TinyUSB calls
 * these (hcd_int_disable/enable) around critical sections in IRQ mode to stop
 * the ISR racing the main loop; they MUST really gate the IRQ. */
void ci_hs_zynq_int_set(uint8_t rhport, int enabled) {
  (void) rhport;
  if (!s_gic_ready) return;
  if (enabled) XScuGic_Enable(&s_gic, USB0_IRQ_ID);
  else         XScuGic_Disable(&s_gic, USB0_IRQ_ID);
}

/* TinyUSB debug-log sink (CFG_TUSB_DEBUG_PRINTF): format then emit via the
 * BSP xil_printf so logs land on the same UART as everything else. */
int usb_logf(const char *fmt, ...) {
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  xil_printf("%s", buf);
  return n;
}

/* ---- TinyUSB time base (app-provided) --------------------------------- */
/* The host stack times enumeration/transfers in ms.  Derive it from the A9
 * global timer (free-running, COUNTS_PER_SECOND ticks/s). */
uint32_t tusb_time_millis_api(void) {
  XTime now;
  XTime_GetTime(&now);
  return (uint32_t)(now / (COUNTS_PER_SECOND / 1000ULL));
}

/* ---- EHCI dcache hooks (override ehci.c's TU_ATTR_WEAK no-ops) ---------
 * NOTE: while running the cache-OFF diagnostic build, Xil_DCache* may skip its
 * memory barrier, so the CPU's qTD/buffer writes can still sit in the write
 * buffer when the HC fetches the qTD (-> DMA to a stale buffer pointer, data
 * lands nowhere).  An explicit dsb forces them out before/after the HC acts. */
#define USB_DSB() __asm__ volatile ("dsb sy" ::: "memory")
bool hcd_dcache_clean(void const *addr, uint32_t data_size) {
  Xil_DCacheFlushRange((INTPTR)addr, (INTPTR)data_size);   /* A9: clean+invalidate */
  USB_DSB();
  return true;
}
bool hcd_dcache_invalidate(void const *addr, uint32_t data_size) {
  USB_DSB();
  Xil_DCacheInvalidateRange((INTPTR)addr, (INTPTR)data_size);
  return true;
}
bool hcd_dcache_clean_invalidate(void const *addr, uint32_t data_size) {
  Xil_DCacheFlushRange((INTPTR)addr, (INTPTR)data_size);
  USB_DSB();
  return true;
}

/* ---- bring-up / poll -------------------------------------------------- */
void usb_hid_init(void) {
  /* Interrupt-driven via GIC IRQ 53.  Poll mode is timing-fragile on this core
   * (constant USBSTS/qHD polling races + disrupts the HC's qTD execution — the
   * commercial Zynq TinyUSB port runs on FreeRTOS, i.e. interrupt-driven). */
  XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_XSCUGIC_0_BASEADDR);
  if (cfg) {
    XScuGic_CfgInitialize(&s_gic, cfg, cfg->CpuBaseAddress);
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                 (Xil_ExceptionHandler) XScuGic_InterruptHandler, &s_gic);
    XScuGic_Connect(&s_gic, USB0_IRQ_ID, (Xil_InterruptHandler) usb_isr, NULL);
    s_gic_ready = 1; // hcd_int_disable/enable can now gate the IRQ
  }

  tuh_init(BOARD_TUH_RHPORT);

  if (cfg) {
    XScuGic_Enable(&s_gic, USB0_IRQ_ID);
    Xil_ExceptionEnable();
  }
  xil_printf("USB: host init on USB0 (rhport %u, IRQ %u, interrupt-driven) — waiting\r\n",
             BOARD_TUH_RHPORT, USB0_IRQ_ID);
}

void usb_hid_task(void) {
  /* tuh_int_handler is now driven by the IRQ-53 ISR; just process queued events. */
  tuh_task();
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
