/*
 * FreeRTOSConfig.h — Cortex-A9 (Zynq-7000) config for the qemu testbed.
 * Mirrors the hardware's Xilinx config; the tick/GIC seams point at our own
 * glue (zynq.c) instead of the BSP's portZynq7000.c.
 */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* --- Cortex-A9 GIC wiring (standard Zynq MPCore addresses) -------------- */
#define configINTERRUPT_CONTROLLER_BASE_ADDRESS          0xF8F01000UL /* GIC distributor */
#define configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET  (-0xF00)     /* -> 0xF8F00100 CPU i/f */
#define configUNIQUE_INTERRUPT_PRIORITIES                32
#define configMAX_API_CALL_INTERRUPT_PRIORITY           18

/* our tick glue (zynq.c) — replaces the BSP's portZynq7000.c */
void vConfigureTickInterrupt(void);
void vClearTickInterrupt(void);
#define configSETUP_TICK_INTERRUPT()  vConfigureTickInterrupt()
#define configCLEAR_TICK_INTERRUPT()  vClearTickInterrupt()

/* --- kernel behaviour --------------------------------------------------- */
#define configUSE_PREEMPTION            1
#define configUSE_TASK_FPU_SUPPORT      1   /* port requires 1 or 2; VFP enabled in xt_boot.S */
#define configTASK_RETURN_ADDRESS       NULL
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configCPU_CLOCK_HZ             666666666UL   /* periph timer = /2 */
#define configTICK_RATE_HZ            ((TickType_t)1000)
#define configMAX_PRIORITIES           8
#define configMINIMAL_STACK_SIZE      ((unsigned short)512)
#define configTOTAL_HEAP_SIZE         ((size_t)(2 * 1024 * 1024))
#define configMAX_TASK_NAME_LEN        16
#define configUSE_16_BIT_TICKS         0
#define configIDLE_SHOULD_YIELD        1
#define configUSE_MUTEXES              1
#define configUSE_RECURSIVE_MUTEXES    1
#define configUSE_COUNTING_SEMAPHORES  1
#define configQUEUE_REGISTRY_SIZE      8
#define configUSE_TASK_NOTIFICATIONS   1
#define configSUPPORT_STATIC_ALLOCATION 1   /* spawned tasks use static stacks (stackguard.c) */
#define configSUPPORT_DYNAMIC_ALLOCATION 1

/* hooks / checks */
#define configCHECK_FOR_STACK_OVERFLOW 2
#define configUSE_MALLOC_FAILED_HOOK   0
#define configGENERATE_RUN_TIME_STATS  0

/* timers */
#define configUSE_TIMERS               1
#define configTIMER_TASK_PRIORITY      (configMAX_PRIORITIES - 1)
#define configTIMER_QUEUE_LENGTH       10
#define configTIMER_TASK_STACK_DEPTH   (configMINIMAL_STACK_SIZE * 2)

/* API inclusions */
#define INCLUDE_vTaskPrioritySet       1
#define INCLUDE_uxTaskPriorityGet      1
#define INCLUDE_vTaskDelete            1
#define INCLUDE_vTaskSuspend           1
#define INCLUDE_vTaskDelayUntil        1
#define INCLUDE_vTaskDelay             1
#define INCLUDE_xTaskGetSchedulerState 1
#define INCLUDE_eTaskGetState          1
#define INCLUDE_xTaskGetCurrentTaskHandle 1

/* assert */
extern void vAssertCalled(const char *file, int line);
#define configASSERT(x) if ((x) == 0) vAssertCalled(__FILE__, __LINE__)

/* T2-b: swap the per-process address space (TTBR0) on every context switch */
#define traceTASK_SWITCHED_IN()  do { extern void xtos_vm_on_switch(void); xtos_vm_on_switch(); } while (0)

#endif /* FREERTOS_CONFIG_H */
