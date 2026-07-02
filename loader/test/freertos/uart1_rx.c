/*
 * uart1_rx.c — interrupt-driven Zynq UART1 receive (HW build only, -DXT_HW_UART).
 *
 * Replaces the busy-wait sh_readc (which spun on the UART status register, burning
 * a task's whole time-slice and starving the idle task / equal-priority daemons
 * while a REPL waited for a keystroke) with a BLOCKING read: the RX interrupt drains
 * the FIFO into a ring and gives a counting semaphore; sh_readc blocks on it. A shell
 * waiting for input now consumes zero CPU (the idle task can WFI), and background
 * tasks run full-speed. TX (puts0) stays a brief poll in bare_rt.c — it only waits
 * for FIFO space, it never blocks on external input.
 *
 * On qemu (no XT_HW_UART) this file is empty; sh_readc comes from bare_rt.c's
 * semihosting path (SYS_READC), which is a blocking host call by nature.
 */
#ifdef XT_HW_UART
#include <stdint.h>
#include "FreeRTOS.h"
#include "semphr.h"

/* Zynq UART1 (0xE0001000; baud/format already set by ps7_init). */
#define UART1_BASE 0xE0001000u
#define REG(o)     (*(volatile uint32_t *)(UART1_BASE + (o)))
#define UART_IER   0x08u        /* interrupt enable  (write 1 to enable)  */
#define UART_IDR   0x0Cu        /* interrupt disable (write 1 to disable) */
#define UART_ISR   0x14u        /* interrupt status  (write 1 to clear)   */
#define UART_RXWM  0x20u        /* Rx FIFO trigger level                  */
#define UART_SR    0x2Cu        /* channel status                         */
#define UART_FIFO  0x30u        /* Rx/Tx data                             */
#define SR_RXEMPTY 0x00000002u
#define IXR_RTRIG  0x00000001u  /* Rx FIFO reached trigger level */
#define IXR_RTOUT  0x00000100u  /* Rx timeout (chars below the trigger level) */

/* GIC distributor — enable/route the UART1 shared peripheral interrupt (id 82). */
#define GICD_BASE            0xF8F01000UL
#define GICD_ISENABLER(n)    (*(volatile uint32_t *)(GICD_BASE + 0x100u + 4u * (n)))
#define GICD_IPRIORITYR(id)  (*(volatile uint8_t  *)(GICD_BASE + 0x400u + (id)))
#define GICD_ITARGETSR(id)   (*(volatile uint8_t  *)(GICD_BASE + 0x800u + (id)))
#define UART1_IRQ_ID 82u

#define RING_SZ 256
static volatile uint8_t  ring[RING_SZ];
static volatile uint32_t r_head, r_tail;          /* ISR writes tail, reader writes head */
static SemaphoreHandle_t rx_sem;                  /* count == bytes waiting in the ring */

/* Called from vApplicationIRQHandler (zynq.c) when the acked id is UART1_IRQ_ID. */
void uart1_rx_isr(void)
{
    BaseType_t woken = pdFALSE;
    REG(UART_ISR) = REG(UART_ISR);                /* write-1-to-clear the pending status */
    while (!(REG(UART_SR) & SR_RXEMPTY)) {        /* drain every buffered byte */
        uint8_t c = (uint8_t)REG(UART_FIFO);
        uint32_t nt = (r_tail + 1u) % RING_SZ;
        if (nt != r_head) {                       /* space? (else drop — keyboard never overruns) */
            ring[r_tail] = c;
            r_tail = nt;
            xSemaphoreGiveFromISR(rx_sem, &woken);
        }
    }
    portYIELD_FROM_ISR(woken);
}

/* Enable UART1 RX interrupts + route id 82 to CPU0. Call after gic_init(), before
 * the scheduler starts (the CPU won't actually take the IRQ until a task runs with
 * interrupts enabled, so early bytes just sit in the FIFO). */
void uart1_rx_init(void)
{
    rx_sem = xSemaphoreCreateCounting(RING_SZ, 0);
    r_head = r_tail = 0;

    REG(UART_IDR) = 0xFFFFFFFFu;                  /* mask all UART irqs while configuring */
    REG(UART_ISR) = 0xFFFFFFFFu;                  /* clear any stale status */
    REG(UART_RXWM) = 1;                           /* fire as soon as 1 byte is buffered */

    GICD_IPRIORITYR(UART1_IRQ_ID) = 0xA0;         /* same band as the tick: API-callable ISR */
    GICD_ITARGETSR(UART1_IRQ_ID)  = 0x01;         /* deliver to CPU0 */
    GICD_ISENABLER(UART1_IRQ_ID / 32u) = 1u << (UART1_IRQ_ID % 32u);

    REG(UART_IER) = IXR_RTRIG | IXR_RTOUT;        /* rx trigger + rx timeout */
}

/* Blocking read of one console byte. count(rx_sem) == bytes in the ring, so a take
 * both waits for and accounts one byte. Returns the byte (never <0 on HW: the UART
 * has no EOF). */
int sh_readc(void)
{
    xSemaphoreTake(rx_sem, portMAX_DELAY);        /* one token == one buffered byte */
    uint8_t c = ring[r_head];
    r_head = (r_head + 1u) % RING_SZ;
    return (int)c;
}

/* Blocking read with a timeout (ms < 0 = forever) — returns the byte, or -1 on
 * timeout.  Used by the input driver for the double-click / escape-sequence windows. */
int sh_readc_timeout(int ms)
{
    TickType_t t = (ms < 0) ? portMAX_DELAY : pdMS_TO_TICKS((uint32_t)ms);
    if (xSemaphoreTake(rx_sem, t) != pdTRUE) return -1;
    uint8_t c = ring[r_head];
    r_head = (r_head + 1u) % RING_SZ;
    return (int)c;
}
#else
typedef int uart1_rx_translation_unit_not_empty;  /* keep ISO C happy on qemu builds */
#endif
