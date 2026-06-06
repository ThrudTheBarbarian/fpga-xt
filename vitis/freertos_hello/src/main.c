/* freertos_hello/src/main.c — minimal FreeRTOS bring-up proof for the A9.
 *
 * Goal: prove the freertos BSP links, the scheduler starts, the
 * SCU/GIC tick fires, and tasks preempt — the smallest thing that means
 * "FreeRTOS is up and running on the device".  The working bare-metal app
 * (vitis/xtos) is left untouched; this is JTAG-loaded separately against
 * the platform's freertos domain.
 *
 * Output goes out BOTH ways:
 *   * raw UART1 writes (0xE0001000), independent of the BSP STDOUT mapping —
 *     guaranteed to appear even if the freertos domain's stdout isn't wired
 *     to ps7_uart_1 (the mute-board failure mode from the standalone bring-up).
 *   * xil_printf(), which only shows if STDOUT *is* mapped — a free check
 *     that the domain stdout config took.
 *
 * What "pass" looks like on the serial console (UART1, on-SOM FTDI):
 *   [rtos] FreeRTOS bring-up <date> <time>
 *   [rtos] heartbeat 0 (tick=...)      <- ~1 s apart, proves vTaskDelay/tick
 *   [rtos] counter alive c=5           <- 4x faster, proves preemption
 *   ...
 */

#include "FreeRTOS.h"
#include "task.h"

#include <stdint.h>
#include "xil_printf.h"

/* --- raw UART1, bypassing BSP STDOUT (see xtos/src/main.c) ---------------- */
static void uart1_raw_puts(const char *s)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    u[0x00 / 4] = (1u << 1) | (1u << 4);         /* TXRES + TXEN */
    while (*s) {
        while (u[0x2C / 4] & 0x10u) { }          /* spin while TX FIFO full */
        u[0x30 / 4] = (uint32_t)(unsigned char)*s++;
    }
}

/* PS_USER_LED1 (MIO0) — PS-software liveness, independent of UART. */
static void ps_led1_init(void)
{
    volatile uint32_t *g = (volatile uint32_t *)0xE000A000u;
    g[0x204 / 4] |= 0x1u;                         /* MIO0 -> output      */
    g[0x208 / 4] |= 0x1u;                         /* MIO0 -> out-enable  */
}
static void ps_led1_set(int on)
{
    volatile uint32_t *g = (volatile uint32_t *)0xE000A000u;
    uint32_t d = g[0x040 / 4];
    g[0x040 / 4] = on ? (d | 0x1u) : (d & ~0x1u);
}

/* ------------------------------------------------------------------------- */
static void heartbeat_task(void *arg)
{
    (void)arg;
    unsigned n = 0;
    for (;;) {
        /* freertos_stdout is mapped to UART1, so xil_printf reaches the console
         * directly — no raw-UART path (its TX-FIFO reset would corrupt
         * concurrent xil_printf output from the other task). */
        xil_printf("[rtos] heartbeat %u (tick=%u)\r\n",
                   n, (unsigned)xTaskGetTickCount());
        ps_led1_set((int)(n & 1u));               /* visible 1 Hz blink */
        n++;
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

static void counter_task(void *arg)
{
    (void)arg;
    unsigned c = 0;
    for (;;) {
        c++;
        if ((c % 5u) == 0u)                        /* every ~1.25 s */
            xil_printf("[rtos] counter alive c=%u\r\n", c);
        vTaskDelay(pdMS_TO_TICKS(250));            /* 4x the heartbeat rate */
    }
}

int main(void)
{
    ps_led1_init();
    ps_led1_set(1);
    uart1_raw_puts("\r\n[rtos] FreeRTOS bring-up " __DATE__ " " __TIME__ "\r\n");
    xil_printf("[rtos] (xil_printf path) STDOUT is mapped\r\n");

    /* configMINIMAL_STACK_SIZE is words; *4 gives generous room for printf. */
    xTaskCreate(heartbeat_task, "hb", configMINIMAL_STACK_SIZE * 4,
                NULL, tskIDLE_PRIORITY + 1, NULL);
    xTaskCreate(counter_task, "ct", configMINIMAL_STACK_SIZE * 4,
                NULL, tskIDLE_PRIORITY + 1, NULL);

    vTaskStartScheduler();

    /* Only reached if the kernel couldn't start (e.g. heap exhausted). */
    uart1_raw_puts("[rtos] FATAL: scheduler returned\r\n");
    for (;;) { }
    return 0;
}

/* --- FreeRTOS hooks the Xilinx default FreeRTOSConfig.h references --------
 * The Xilinx freertos default config enables stack-overflow checking and
 * the malloc-failed hook, so these must be defined or the link fails. */
void vApplicationMallocFailedHook(void)
{
    uart1_raw_puts("[rtos] FATAL: malloc failed\r\n");
    for (;;) { }
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task;
    uart1_raw_puts("[rtos] FATAL: stack overflow in task: ");
    uart1_raw_puts(name ? name : "?");
    uart1_raw_puts("\r\n");
    for (;;) { }
}
