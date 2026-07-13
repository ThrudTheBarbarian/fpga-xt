/*
 * uart1_rx.c — interrupt-driven Zynq UART1 receive (HW build only, -DXT_HW_UART).
 *
 * Replaces the busy-wait con_tty_readc (which spun on the UART status register, burning
 * a task's whole time-slice and starving the idle task / equal-priority daemons
 * while a REPL waited for a keystroke) with a BLOCKING read: the RX interrupt drains
 * the FIFO into a ring and gives a counting semaphore; con_tty_readc blocks on it. A shell
 * waiting for input now consumes zero CPU (the idle task can WFI), and background
 * tasks run full-speed. TX (puts0) stays a brief poll in bare_rt.c — it only waits
 * for FIFO space, it never blocks on external input.
 *
 * On qemu (no XT_HW_UART) this file is empty; con_tty_readc comes from bare_rt.c's
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

/* 8 KB: the desktop meters keys into the 6502 at ~50 cps (single KBCODE latch,
 * see kbd_6502_ascii), far slower than a host paste arrives (~11 k cps at
 * 115200), so the ring must hold a whole pasted BASIC listing while it drains.
 * A smaller ring silently drops the paste tail. (g_tty_q shares the size — a bigger
 * shell paste buffer is a harmless bonus.) */
#define RING_SZ 8192
/* Two console input lanes + a focus flag: the UART byte stream is routed to the
 * interactive TTY (con_tty_readc) or the GUI/desktop (con_gui_readc) by g_focus;
 * the FOCUS_TOGGLE key flips it (intercepted in the ISR, never forwarded) so the
 * two coexist — like the vitis {/}/\ diversion, one key.  Default = TTY.
 * NOTE: the GUI lane is TRANSITIONAL — the desktop only reads console bytes here
 * because its mouse/keyboard currently arrive over the serial terminal. Once the
 * STM32F411 companion feeds real HID, the GUI lane + the focus toggle go away and
 * only the TTY lane remains. */
typedef struct { volatile uint8_t buf[RING_SZ]; volatile uint32_t head, tail; SemaphoreHandle_t sem; } rxq;
static rxq g_tty_q, g_gui_q;                      /* lane 0 = tty console, lane 1 = gui (transitional) */
static volatile int g_focus;                      /* 0 = tty (con_tty), 1 = gui (con_gui) */
static volatile int g_focus_gen;                  /* bumps on every flip TO the desktop —
                                                   * the input layer re-arms terminal mouse
                                                   * reporting when it sees a new generation
                                                   * (the enable/size-query replies only reach
                                                   * the desktop queue while it has focus) */
#define FOCUS_TOGGLE 0x60                          /* backtick '`' */

int con_focus_gen(void) { return g_focus_gen; }

static void q_push(rxq *q, uint8_t c, BaseType_t *woken) {
    uint32_t nt = (q->tail + 1u) % RING_SZ;
    if (nt != q->head) { q->buf[q->tail] = c; q->tail = nt; xSemaphoreGiveFromISR(q->sem, woken); }
}
static int q_read(rxq *q, int ms) {
    extern int xt_block_check(void);      /* honour kill/signals while parked at PL1 */
    if (ms < 0) {                         /* block "forever": poll so kill/signals are seen */
        for (;;) {
            if (xSemaphoreTake(q->sem, pdMS_TO_TICKS(50)) == pdTRUE) {
                uint8_t c = q->buf[q->head]; q->head = (q->head + 1u) % RING_SZ;
                return (int)c;
            }
            if (xt_block_check() == -4) return -4;   /* -EINTR (a kill exits inside the check) */
        }
    }
    if (xSemaphoreTake(q->sem, pdMS_TO_TICKS((uint32_t)ms)) != pdTRUE) return -1;
    uint8_t c = q->buf[q->head]; q->head = (q->head + 1u) % RING_SZ;
    return (int)c;
}

extern int frtos_tty_sigint(void);   /* ^C: kill the foreground job (cooked mode only) */
extern int frtos_tty_sigtstp(void);  /* ^Z: stop it (fg/bg resume it) */

/* Called from vApplicationIRQHandler (zynq.c) when the acked id is UART1_IRQ_ID. */
void uart1_rx_isr(void)
{
    BaseType_t woken = pdFALSE;
    REG(UART_ISR) = REG(UART_ISR);                /* write-1-to-clear the pending status */
    while (!(REG(UART_SR) & SR_RXEMPTY)) {        /* drain every buffered byte */
        uint8_t c = (uint8_t)REG(UART_FIFO);
        if (c == FOCUS_TOGGLE) {                                  /* flip focus, don't forward */
            g_focus ^= 1;
            if (g_focus) {
                g_focus_gen++;
                q_push(&g_gui_q, 0, &woken);   /* wake sentinel: the desktop blocks in
                                             * con_gui_readc; byte 0 (swallowed by the
                                             * input layer) unblocks it so the mouse
                                             * re-arm goes out NOW, not at the next
                                             * keypress */
            }
            continue;
        }
        if (c == 3 && !g_focus) frtos_tty_sigint();   /* ^C HERE, not at the eventual read:
                                                       * a compute-looping fg job must die at
                                                       * its next syscall gate. The byte still
                                                       * queues — the discipline drops the
                                                       * line + echoes. Raw mode: no-op. */
        if (c == 26 && !g_focus) frtos_tty_sigtstp(); /* ^Z likewise: stop at the next gate */
        q_push(g_focus ? &g_gui_q : &g_tty_q, c, &woken);
    }
    portYIELD_FROM_ISR(woken);
}

/* Enable UART1 RX interrupts + route id 82 to CPU0. Call after gic_init(), before
 * the scheduler starts (the CPU won't actually take the IRQ until a task runs with
 * interrupts enabled, so early bytes just sit in the FIFO). */
void uart1_rx_init(void)
{
    g_tty_q.sem = xSemaphoreCreateCounting(RING_SZ, 0); g_tty_q.head = g_tty_q.tail = 0;
    g_gui_q.sem = xSemaphoreCreateCounting(RING_SZ, 0); g_gui_q.head = g_gui_q.tail = 0;

    REG(UART_IDR) = 0xFFFFFFFFu;                  /* mask all UART irqs while configuring */
    REG(UART_ISR) = 0xFFFFFFFFu;                  /* clear any stale status */
    REG(UART_RXWM) = 1;                           /* fire as soon as 1 byte is buffered */

    GICD_IPRIORITYR(UART1_IRQ_ID) = 0xA0;         /* same band as the tick: API-callable ISR */
    GICD_ITARGETSR(UART1_IRQ_ID)  = 0x01;         /* deliver to CPU0 */
    GICD_ISENABLER(UART1_IRQ_ID / 32u) = 1u << (UART1_IRQ_ID % 32u);

    REG(UART_IER) = IXR_RTRIG | IXR_RTOUT;        /* rx trigger + rx timeout */
}

/* network-console input (netcon.c, task context): a received byte enters the SAME console
 * stream as a UART keystroke — line discipline, ^C/^Z and the raw editor behave identically
 * over TCP.
 *
 * INCLUDING THE FOCUS TOGGLE, which it used to ignore: netcon's own header promises bytes are
 * injected "as if typed on the UART", and they were not — a backtick over TCP went to the shell
 * as a literal '`' while the same byte on the wire flipped the console to the GUI lane. So the
 * GUI/desktop lane (pointer, keys) was reachable ONLY from the physical serial port. One console,
 * two transports (netcon.c): the transport must not change what a byte MEANS. */
void sh_inject(unsigned char c)
{
    extern int frtos_tty_sigint(void);
    extern int frtos_tty_sigtstp(void);
    rxq *q;
    if (c == FOCUS_TOGGLE) {                  /* flip focus, don't forward — exactly as the ISR does */
        g_focus ^= 1;
        if (g_focus) {
            g_focus_gen++;
            q = &g_gui_q;                     /* wake sentinel: byte 0 unblocks the input decoder */
            uint32_t n0 = (q->tail + 1u) % RING_SZ;
            if (n0 != q->head) { q->buf[q->tail] = 0; q->tail = n0; xSemaphoreGive(q->sem); }
        }
        return;
    }
    if (c == 3  && !g_focus) frtos_tty_sigint();       /* like the ISR fast path */
    if (c == 26 && !g_focus) frtos_tty_sigtstp();
    q = g_focus ? &g_gui_q : &g_tty_q;
    uint32_t nt = (q->tail + 1u) % RING_SZ;
    if (nt != q->head) {
        q->buf[q->tail] = c; q->tail = nt;
        xSemaphoreGive(q->sem);
    }
}

int con_tty_readc(void)             { return q_read(&g_tty_q, -1); }  /* shell console byte (blocking) */
int con_tty_readc_timeout(int ms)   { return q_read(&g_tty_q, ms); }
/* bytes buffered for the shell (raw-mode burst drain + XT_TTY_NREAD) */
int con_tty_avail(void)             { return (int)((g_tty_q.tail + RING_SZ - g_tty_q.head) % RING_SZ); }
/* block until shell input is available or the timeout lapses, WITHOUT consuming
 * (XT_TTY_INWAIT = poll(2)): take the counting semaphore, then give it straight
 * back so the byte's token survives for the eventual read. */
int con_tty_wait(int ms)
{
    if (con_tty_avail() > 0) return 1;
    TickType_t t = (ms < 0) ? portMAX_DELAY : pdMS_TO_TICKS((uint32_t)ms);
    if (xSemaphoreTake(g_tty_q.sem, t) != pdTRUE) return 0;
    xSemaphoreGive(g_tty_q.sem);
    return 1;
}
int con_gui_readc(void)           { return q_read(&g_gui_q, -1); }  /* desktop input byte (focus=desktop) */
int con_gui_readc_timeout(int ms) { return q_read(&g_gui_q, ms); }
#else
typedef int uart1_rx_translation_unit_not_empty;  /* keep ISO C happy on qemu builds */
#endif
