/*
 * main.c — Stage 1: prove the REAL Xilinx FreeRTOS kernel + Cortex-A9 port run
 * under qemu-system-arm -M xilinx-zynq-a9 with our GIC/timer glue. Two tasks
 * alternate via vTaskDelay (real scheduler, real tick); after a few rounds it
 * declares PASS and exits.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "bare_rt.h"   /* puts0/putu via semihosting */

extern void gic_init(void);

static volatile int a_count, b_count;

static void taskA(void *p)
{
    (void)p;
    for (;;) {
        puts0("  [A] tick "); putu((unsigned)++a_count); puts0("\n");
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

static void taskB(void *p)
{
    (void)p;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(150));
        puts0("  [B] tock "); putu((unsigned)++b_count); puts0("\n");
        if (b_count >= 3 && a_count >= 3) {
            puts0(a_count && b_count ? "RESULT: PASS\n" : "RESULT: FAIL\n");
            sh_exit(0);
        }
    }
}

int main(void)
{
    puts0("=== real Xilinx FreeRTOS on qemu xilinx-zynq-a9 (Stage 1) ===\n");

    gic_init();

    if (xTaskCreate(taskA, "A", configMINIMAL_STACK_SIZE, NULL, 2, NULL) != pdPASS ||
        xTaskCreate(taskB, "B", configMINIMAL_STACK_SIZE, NULL, 2, NULL) != pdPASS) {
        puts0("xTaskCreate failed\n"); sh_exit(1);
    }

    puts0("starting scheduler...\n");
    vTaskStartScheduler();

    puts0("scheduler returned (heap?)\n"); sh_exit(1);
    return 0;
}
