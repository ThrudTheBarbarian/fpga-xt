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
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>           /* vsnprintf (TinyUSB log formatting) */
#include "xil_types.h"
#include "xil_cache.h"
#include "xil_io.h"          /* Xil_Out8 — keyboard inject through the GP0 bridge */
#include "xil_printf.h"
#include "xt_blitter.h"      /* XT_BLITTER_BASE (axi_blitter_bridge GP0 slave) */
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

/* ---- USB HID keyboard -> Atari POKEY KBCODE ---------------------------
 * The PL pulses POKEY's kbd_event (loads KBCODE $D209 + raises the keyboard
 * IRQ) when the PS writes an Atari KBCODE byte to $D4CF through the GP0 blitter
 * bridge (axi_blitter_bridge -> bridge_bus_addr $D4CF, fpga_xt_top.sv:1496).
 * $D4CF = XT_BLITTER_BASE + 0x1F (awaddr[4]=1 -> $D4Cx page, low nibble F; the
 * bridge strobes bl_we and the FONT_CTRL alias is a harmless side-effect).  The
 * Atari KBCODE byte = {shift(b7), ctrl(b6), 6-bit key matrix code}; the XL OS
 * keyboard IRQ handler maps that (via its shift/ctrl tables) to ATASCII in CH. */
#define XT_KBD_INJECT_ADDR   (XT_BLITTER_BASE + 0x1Fu)  /* $D4CF key-down: KBCODE + IRQ  */
#define XT_KBD_RELEASE_ADDR  (XT_BLITTER_BASE + 0x1Du)  /* $D4CD all-keys-up: SKSTAT clear */
#define XT_KBD_BREAK_ADDR    (XT_BLITTER_BASE + 0x1Bu)  /* $D4CB Atari BREAK (POKEY IRQ b7) */
#define HID_KEY_F12          0x45u                       /* -> Atari BREAK */

/* USB HID usage (0x04..0x39) -> Atari 6-bit KBCODE; 0xFF = no Atari key. */
static const uint8_t s_hid_to_kbcode[] = {
  /*04 a*/0x3F,/*05 b*/0x15,/*06 c*/0x12,/*07 d*/0x3A,/*08 e*/0x2A,/*09 f*/0x38,
  /*0A g*/0x3D,/*0B h*/0x39,/*0C i*/0x0D,/*0D j*/0x01,/*0E k*/0x05,/*0F l*/0x00,
  /*10 m*/0x25,/*11 n*/0x23,/*12 o*/0x08,/*13 p*/0x0A,/*14 q*/0x2F,/*15 r*/0x28,
  /*16 s*/0x3E,/*17 t*/0x2D,/*18 u*/0x0B,/*19 v*/0x10,/*1A w*/0x2E,/*1B x*/0x16,
  /*1C y*/0x2B,/*1D z*/0x17,/*1E 1*/0x1F,/*1F 2*/0x1E,/*20 3*/0x1A,/*21 4*/0x18,
  /*22 5*/0x1D,/*23 6*/0x1B,/*24 7*/0x33,/*25 8*/0x35,/*26 9*/0x30,/*27 0*/0x32,
  /*28 ret*/0x0C,/*29 esc*/0x1C,/*2A bsp*/0x34,/*2B tab*/0x2C,/*2C spc*/0x21,
  /*2D -*/0x0E,/*2E =*/0x0F,/*2F [*/0xFF,/*30 ]*/0xFF,/*31 \*/0xFF,/*32 #*/0xFF,
  /*33 ;*/0x02,/*34 '*/0xFF,/*35 `*/0xFF,/*36 ,*/0x20,/*37 .*/0x22,/*38 /*/0x26,
  /*39 caps*/0x3C,
};
#define HID_KBCODE_FIRST 0x04u
#define HID_KBCODE_LAST  (HID_KBCODE_FIRST + sizeof(s_hid_to_kbcode) - 1u)

static uint8_t s_prev_keys[6];   /* boot-report keycodes from the previous report */
static bool    s_any_key_down;   /* a mapped KBCODE key was held last report */

static bool kbd_key_held(uint8_t k, const uint8_t keys[6]) {
  for (int i = 0; i < 6; i++) if (keys[i] == k) return true;
  return false;
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len) {
  uint8_t const proto = tuh_hid_interface_protocol(dev_addr, instance);

  if (proto == HID_ITF_PROTOCOL_KEYBOARD && len >= 8) {
    /* Boot-keyboard report: [0]=modifiers, [2..7]=pressed keycodes.  Inject on
     * key-DOWN edges only (a key still held from the last report is skipped —
     * the XL OS does its own auto-repeat off the held KBCODE). */
    uint8_t const  mods = report[0];
    uint8_t const *keys = &report[2];
    bool const shift = (mods & 0x22u) != 0;   /* L/R Shift (bits 1,5) */
    bool const ctrl  = (mods & 0x11u) != 0;   /* L/R Ctrl  (bits 0,4) */
    bool any_mapped = false;                  /* a KBCODE key is currently held */
    for (int i = 0; i < 6; i++) {
      uint8_t k = keys[i];
      bool const is_new = !kbd_key_held(k, s_prev_keys);
      if (k == HID_KEY_F12) {                                   /* F12 -> Atari BREAK */
        if (is_new) { Xil_Out8(XT_KBD_BREAK_ADDR, 0); xil_printf("KBD BREAK\r\n"); }
        continue;
      }
      if (k < HID_KBCODE_FIRST || k > HID_KBCODE_LAST) continue; /* none/rollover/out-of-range */
      uint8_t kb = s_hid_to_kbcode[k - HID_KBCODE_FIRST];
      if (kb == 0xFFu) continue;                                /* no Atari equivalent */
      any_mapped = true;
      if (!is_new) continue;                                    /* held, not a new press */
      /* Atari KBCODE: bit 6 = Shift, bit 7 = Ctrl (bits 5:0 = key matrix). */
      uint8_t code = (uint8_t)(kb | (shift ? 0x40u : 0u) | (ctrl ? 0x80u : 0u));
      Xil_Out8(XT_KBD_INJECT_ADDR, code);                       /* -> $D4CF -> KBCODE + IRQ */
      xil_printf("KBD inject KBCODE=%02x (hid=%02x%s%s)\r\n", code, k,
                 shift ? " sh" : "", ctrl ? " ctl" : "");
    }
    /* When the last mapped key lifts, clear POKEY's SKSTAT key-down so the OS
     * auto-repeat stops (a held key keeps it set -> the OS repeats naturally). */
    if (!any_mapped && s_any_key_down) Xil_Out8(XT_KBD_RELEASE_ADDR, 0);
    s_any_key_down = any_mapped;
    for (int i = 0; i < 6; i++) s_prev_keys[i] = keys[i];
  } else if (proto == HID_ITF_PROTOCOL_MOUSE && len >= 3) {
    xil_printf("MOUSE btn=%02x dx=%d dy=%d\r\n",
               report[0], (int)(int8_t)report[1], (int)(int8_t)report[2]);
  } else {
    xil_printf("HID report inst=%u len=%u\r\n", instance, len);
  }

  tuh_hid_receive_report(dev_addr, instance);   /* re-arm */
}
