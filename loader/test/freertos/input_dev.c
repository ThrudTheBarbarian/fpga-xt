/*
 * input_dev.c — the input EVENT QUEUE behind /dev/input.
 *
 * WHY THIS EXISTS (RESPONSIBILITIES.md §2, docs/OS/gemd-plan.md M4).
 *
 * SYS_input (0x700) is a BLOCKING SYSCALL, not an fd. A window server cannot wait on input AND
 * on its client channels at the same time through it — it would have to poll one and block on
 * the other, or grow a thread per source. That is the exact shape of the problem M0 solved for
 * rendezvous, and it gets the exact same answer: make it an fd, and let poll() do the waiting.
 *
 * So input becomes a devfs node, `/OS/dev/input`, whose read() delivers `struct os_event`
 * records and whose poll() is honest about whether one is waiting. gemd's main loop then stays
 * ONE poll() over { listen fd, client channels, input fd } with no special case in it.
 *
 * AND THE KERNEL STILL KNOWS NOTHING ABOUT WINDOW SERVERS (§2). It does not "send input to the
 * gem service": it publishes events on a device, and whoever holds the fd reads them. Kernel-side
 * injection into a named service would have put window-server policy in the kernel, which §2
 * forbids and which this design deliberately refuses.
 *
 * THE PRODUCER IS SWAPPABLE, ON PURPOSE. Today the events come from `input_next_event()` in
 * sprite.c — the UART "GUI lane", a transitional hack (terminal mouse reports + arrow keys).
 * Tomorrow they arrive from an STM32F411 over SPI. Only `input_task()` below changes: the queue,
 * the device node and every consumer stay exactly as they are.
 *
 * The kernel keeps the HW cursor sprite (sprite.c's cursor_move, called by the decoder): pointer
 * motion is then free and tear-free, and no process has to draw a pointer.
 *
 * The old `-EINTR` swallow in sprite.c (a -4 return reported as a spurious OS_EV_TIMER) is moot
 * here and is NOT re-enshrined: the producer loops forever, so a lost wakeup reason costs a lap
 * of the loop and nothing else.
 */
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "xtsys.h"                 /* struct os_event, OS_EV_* */
#include "vfs.h"

extern int input_next_event(struct os_event *ev, int timeout_ms, int raw);   /* sprite.c: the decoder */

#define INPUT_QLEN 64              /* events. A burst of mouse motion is the worst case; a client
                                    * that stops reading loses the OLDEST events, never the queue. */

static QueueHandle_t g_q;
static int           g_raw;        /* pass-through to the decoder (emulator key grab) */
static int           g_started;
static int           g_lx, g_ly;   /* last pointer position seen (SYS_input's timeout contract) */

/* The producer. One decoder, one queue: every consumer (the fd below, and SYS_input) is a VIEW
 * on this, so there is exactly one thing draining the UART lane and no two-readers race. */
extern void klog(const char *);

/* A SECOND PRODUCER's door into the one queue (network input — input_udp.c). Same
 * drop-the-oldest overflow rule as the decoder: a stalled reader loses history, never
 * the queue. Safe from any task context; a no-op before the queue exists. */
int xt_input_inject(const struct os_event *ev)
{
    if (!g_q) return -1;
    g_lx = ev->mx; g_ly = ev->my;
    if (xQueueSend(g_q, ev, 0) != pdPASS) {
        struct os_event drop;
        xQueueReceive(g_q, &drop, 0);
        xQueueSend(g_q, ev, 0);
    }
    return 0;
}

static void input_task(void *arg)
{
    (void)arg;
    klog("input: decoder task running (/OS/dev/input is live)\r\n");
    for (;;) {
        struct os_event ev;
        memset(&ev, 0, sizeof ev);
        int r = input_next_event(&ev, -1, g_raw);
        if (r != 0 || ev.type == OS_EV_TIMER || ev.type == OS_EV_NONE) {
            /* -1 means "block forever", so a TIMER here means the decoder has nothing to give
             * (qemu has no input at all and returns immediately). Sleep rather than spin. */
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        g_lx = ev.mx; g_ly = ev.my;
        /* TEMP input-cadence probe: how many events does the DECODER produce per second?
         * Compare with gemd's per-second consumption to find where motion goes sparse. */
        { static uint32_t s_cnt, s_mot, s_t0;
          extern uint32_t xTaskGetTickCount(void);
          uint32_t now = xTaskGetTickCount();
          s_cnt++; if (ev.type == 5 /*OS_EV_MOTION*/) s_mot++;
          if (now - s_t0 >= 1000) {
              char b[80]; extern void klog(const char *);
              int n; (void)n;
              snprintf(b, sizeof b, "input: %u ev/s (%u motion)\r\n", (unsigned)s_cnt, (unsigned)s_mot);
              klog(b);
              s_cnt = 0; s_mot = 0; s_t0 = now;
          } }
        if (xQueueSend(g_q, &ev, 0) != pdPASS) {        /* full: drop the OLDEST and keep the newest —
                                                         * a stalled reader must not freeze the queue */
            struct os_event drop;
            xQueueReceive(g_q, &drop, 0);
            xQueueSend(g_q, &ev, 0);
        }
    }
}

void xt_input_pos(int *x, int *y) { if (x) *x = g_lx; if (y) *y = g_ly; }

void xt_input_start(void)                               /* idempotent: first open / first SYS_input */
{
    if (g_started) return;
    g_started = 1;
    g_q = xQueueCreate(INPUT_QLEN, sizeof(struct os_event));
    if (!g_q) { g_started = 0; return; }
    xTaskCreate(input_task, "input", 2048, 0, 3, 0);
}

void xt_input_set_raw(int raw) { g_raw = raw ? 1 : 0; }

int xt_input_avail(void)                                /* what poll() asks */
{
    if (!g_q) return 0;
    return (int)uxQueueMessagesWaiting(g_q);
}

/* 1 = got one, 0 = nothing within timeout_ms, -4 = -EINTR (killed / signalled while parked).
 *
 * A BLOCKING READ MUST HONOUR A KILL. Waiting "forever" in 100 ms chunks is not enough on its
 * own: the chunks must be punctuated by the block check, or `kill <pid>` on a process parked in
 * here does nothing at all — it stays in the queue, and (worse, for THIS device) it stays a
 * READER, quietly eating the events its replacement is waiting for. That is exactly what a
 * debugging `cat /OS/dev/input` did: unkillable, and it swallowed every click on the machine.
 * uart1_rx.c's q_read already does this; so does this. */
int xt_input_pop(struct os_event *ev, int timeout_ms)
{
    extern int xt_block_check(void);                    /* -4 when a kill/signal is pending */
    xt_input_start();
    if (!g_q) return 0;
    if (timeout_ms < 0) {
        for (;;) {
            if (xQueueReceive(g_q, ev, pdMS_TO_TICKS(100)) == pdPASS) return 1;
            if (xt_block_check() == -4) return -4;      /* a kill EXITS inside the check */
        }
    }
    return xQueueReceive(g_q, ev, pdMS_TO_TICKS(timeout_ms)) == pdPASS;
}

/* ---- the devfs node: /OS/dev/input ------------------------------------------------------- */

/* read() delivers WHOLE events, never a partial one. It blocks for the first (a device read that
 * returned 0 would mean EOF), then drains whatever else is queued in the same call — so a reader
 * that wakes on poll() empties the burst in one syscall instead of one per event. */
long xt_input_dev_read(vfs_file *f, void *buf, uint32_t n)
{
    if (!buf || n < sizeof(struct os_event)) return -1;
    xt_input_start();
    uint32_t got = 0;
    while (got + sizeof(struct os_event) <= n) {
        int wait = (got == 0 && !f->nonblock) ? -1 : 0;
        int r = xt_input_pop((struct os_event *)((char *)buf + got), wait);
        if (r == -4) return got ? (long)got : -4;       /* -EINTR: killed while parked */
        if (r != 1) break;
        got += (uint32_t)sizeof(struct os_event);
    }
    if (got == 0 && f->nonblock) return -11;            /* -EAGAIN, like every other nonblock chr read */
    return (long)got;
}

/* poll(): readable iff an event is actually queued. Without this the generic device rule ("always
 * ready") would make a poller spin and then BLOCK in read — the wedge this whole file exists to
 * avoid. */
long xt_input_dev_avail(vfs_file *f) { (void)f; return xt_input_avail(); }

/* ioctl(XT_INPUT_RAW): pass the emulator key-grab through to the decoder, where Enter/Space stop
 * being synthesised clicks and become keys. It is the ONE bit SYS_input carried that an fd cannot
 * carry per-read, and it is policy the reader owns — so it is a device control, not a kernel rule. */
long xt_input_dev_ioctl(vfs_file *f, unsigned req, void *arg)
{
    (void)f;
    if (req != XT_INPUT_RAW) return -1;
    xt_input_set_raw((int)(intptr_t)arg);
    return 0;
}
