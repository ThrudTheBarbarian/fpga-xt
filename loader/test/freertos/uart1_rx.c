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
/* Two input queues + a focus flag: the console byte stream is routed to the shell
 * (sh_readc) or the desktop (desk_readc) by g_focus; the FOCUS_TOGGLE key flips it
 * (intercepted in the ISR, never forwarded) so the desktop and shell coexist —
 * like the vitis {/}/\ diversion, one key.  Default = shell. */
typedef struct { volatile uint8_t buf[RING_SZ]; volatile uint32_t head, tail; SemaphoreHandle_t sem; } rxq;
static rxq sh_q, dk_q;
static volatile int g_focus;                      /* 0 = shell, 1 = desktop */
#define FOCUS_TOGGLE 0x60                          /* backtick '`' */

static void q_push(rxq *q, uint8_t c, BaseType_t *woken) {
    uint32_t nt = (q->tail + 1u) % RING_SZ;
    if (nt != q->head) { q->buf[q->tail] = c; q->tail = nt; xSemaphoreGiveFromISR(q->sem, woken); }
}
static int q_read(rxq *q, int ms) {
    TickType_t t = (ms < 0) ? portMAX_DELAY : pdMS_TO_TICKS((uint32_t)ms);
    if (xSemaphoreTake(q->sem, t) != pdTRUE) return -1;
    uint8_t c = q->buf[q->head]; q->head = (q->head + 1u) % RING_SZ;
    return (int)c;
}

/* Called from vApplicationIRQHandler (zynq.c) when the acked id is UART1_IRQ_ID. */
void uart1_rx_isr(void)
{
    BaseType_t woken = pdFALSE;
    REG(UART_ISR) = REG(UART_ISR);                /* write-1-to-clear the pending status */
    while (!(REG(UART_SR) & SR_RXEMPTY)) {        /* drain every buffered byte */
        uint8_t c = (uint8_t)REG(UART_FIFO);
        if (c == FOCUS_TOGGLE) { g_focus ^= 1; continue; }        /* flip focus, don't forward */
        q_push(g_focus ? &dk_q : &sh_q, c, &woken);
    }
    portYIELD_FROM_ISR(woken);
}

/* Enable UART1 RX interrupts + route id 82 to CPU0. Call after gic_init(), before
 * the scheduler starts (the CPU won't actually take the IRQ until a task runs with
 * interrupts enabled, so early bytes just sit in the FIFO). */
void uart1_rx_init(void)
{
    sh_q.sem = xSemaphoreCreateCounting(RING_SZ, 0); sh_q.head = sh_q.tail = 0;
    dk_q.sem = xSemaphoreCreateCounting(RING_SZ, 0); dk_q.head = dk_q.tail = 0;

    REG(UART_IDR) = 0xFFFFFFFFu;                  /* mask all UART irqs while configuring */
    REG(UART_ISR) = 0xFFFFFFFFu;                  /* clear any stale status */
    REG(UART_RXWM) = 1;                           /* fire as soon as 1 byte is buffered */

    GICD_IPRIORITYR(UART1_IRQ_ID) = 0xA0;         /* same band as the tick: API-callable ISR */
    GICD_ITARGETSR(UART1_IRQ_ID)  = 0x01;         /* deliver to CPU0 */
    GICD_ISENABLER(UART1_IRQ_ID / 32u) = 1u << (UART1_IRQ_ID % 32u);

    REG(UART_IER) = IXR_RTRIG | IXR_RTOUT;        /* rx trigger + rx timeout */
}

int sh_readc(void)             { return q_read(&sh_q, -1); }  /* shell console byte (blocking) */
int sh_readc_timeout(int ms)   { return q_read(&sh_q, ms); }
int desk_readc(void)           { return q_read(&dk_q, -1); }  /* desktop input byte (focus=desktop) */
int desk_readc_timeout(int ms) { return q_read(&dk_q, ms); }
#else
typedef int uart1_rx_translation_unit_not_empty;  /* keep ISO C happy on qemu builds */
#endif
