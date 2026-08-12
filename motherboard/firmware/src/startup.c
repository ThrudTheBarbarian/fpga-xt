/* startup.c — vector table, reset entry, and default handlers.
 *
 * Written in C rather than assembly: the reset path is short enough that the
 * only thing needing care is not touching .data/.bss before they exist, which
 * `__attribute__((naked))` plus a hand-set stack pointer covers.
 */
#include <stdint.h>
#include "stm32f411.h"

extern uint32_t _data_load, _data_start, _data_end;
extern uint32_t _bss_start, _bss_end;
extern uint32_t _stack_top;

extern int  main(void);
extern void clock_init(void);
void reset_handler(void);
void default_handler(void);
void fault_handler(void);                       /* fault.c */

/* Every vector is a weak alias to default_handler, so a module that wants an
 * interrupt just defines the matching symbol and the linker picks it up.
 */
#define WEAK_ALIAS(name) \
    void name(void) __attribute__((weak, alias("default_handler")))

WEAK_ALIAS(nmi_handler);
WEAK_ALIAS(mpu_fault_handler);
WEAK_ALIAS(svc_handler);
WEAK_ALIAS(debugmon_handler);
WEAK_ALIAS(pendsv_handler);
WEAK_ALIAS(systick_handler);

WEAK_ALIAS(wwdg_handler);
WEAK_ALIAS(pvd_handler);
WEAK_ALIAS(tamp_stamp_handler);
WEAK_ALIAS(rtc_wkup_handler);
WEAK_ALIAS(flash_handler);
WEAK_ALIAS(rcc_handler);
WEAK_ALIAS(exti0_handler);
WEAK_ALIAS(exti1_handler);
WEAK_ALIAS(exti2_handler);
WEAK_ALIAS(exti3_handler);
WEAK_ALIAS(exti4_handler);
WEAK_ALIAS(dma1_stream0_handler);
WEAK_ALIAS(dma1_stream1_handler);
WEAK_ALIAS(dma1_stream2_handler);
WEAK_ALIAS(dma1_stream3_handler);
WEAK_ALIAS(dma1_stream4_handler);
WEAK_ALIAS(dma1_stream5_handler);
WEAK_ALIAS(dma1_stream6_handler);
WEAK_ALIAS(adc_handler);
WEAK_ALIAS(exti9_5_handler);
WEAK_ALIAS(tim1_brk_tim9_handler);
WEAK_ALIAS(tim1_up_tim10_handler);
WEAK_ALIAS(tim1_trg_com_tim11_handler);
WEAK_ALIAS(tim1_cc_handler);
WEAK_ALIAS(tim2_handler);
WEAK_ALIAS(tim3_handler);
WEAK_ALIAS(tim4_handler);
WEAK_ALIAS(i2c1_ev_handler);
WEAK_ALIAS(i2c1_er_handler);
WEAK_ALIAS(i2c2_ev_handler);
WEAK_ALIAS(i2c2_er_handler);
WEAK_ALIAS(spi1_handler);
WEAK_ALIAS(spi2_handler);
WEAK_ALIAS(usart1_handler);
WEAK_ALIAS(usart2_handler);
WEAK_ALIAS(exti15_10_handler);
WEAK_ALIAS(rtc_alarm_handler);
WEAK_ALIAS(otg_fs_wkup_handler);
WEAK_ALIAS(dma1_stream7_handler);
WEAK_ALIAS(sdio_handler);
WEAK_ALIAS(tim5_handler);
WEAK_ALIAS(spi3_handler);
WEAK_ALIAS(dma2_stream0_handler);
WEAK_ALIAS(dma2_stream1_handler);
WEAK_ALIAS(dma2_stream2_handler);
WEAK_ALIAS(dma2_stream3_handler);
WEAK_ALIAS(dma2_stream4_handler);
WEAK_ALIAS(otg_fs_handler);
WEAK_ALIAS(dma2_stream5_handler);
WEAK_ALIAS(dma2_stream6_handler);
WEAK_ALIAS(dma2_stream7_handler);
WEAK_ALIAS(usart6_handler);
WEAK_ALIAS(i2c3_ev_handler);
WEAK_ALIAS(i2c3_er_handler);
WEAK_ALIAS(fpu_handler);
WEAK_ALIAS(spi4_handler);
WEAK_ALIAS(spi5_handler);

typedef void (*vector_t)(void);

__attribute__((section(".isr_vector"), used))
const vector_t vector_table[] = {
    (vector_t)&_stack_top,
    reset_handler,
    nmi_handler,
    fault_handler,              /* HardFault    */
    fault_handler,              /* MemManage    */
    fault_handler,              /* BusFault     */
    fault_handler,              /* UsageFault   */
    0, 0, 0, 0,
    svc_handler,
    debugmon_handler,
    0,
    pendsv_handler,
    systick_handler,

    /* external interrupts, RM0383 table 38 */
    wwdg_handler,               /*  0 */
    pvd_handler,
    tamp_stamp_handler,
    rtc_wkup_handler,
    flash_handler,
    rcc_handler,
    exti0_handler,
    exti1_handler,
    exti2_handler,
    exti3_handler,
    exti4_handler,              /* 10 */
    dma1_stream0_handler,
    dma1_stream1_handler,
    dma1_stream2_handler,
    dma1_stream3_handler,
    dma1_stream4_handler,
    dma1_stream5_handler,
    dma1_stream6_handler,
    adc_handler,
    0, 0, 0, 0,                 /* CAN1 — not on F411 */
    exti9_5_handler,            /* 23 */
    tim1_brk_tim9_handler,
    tim1_up_tim10_handler,
    tim1_trg_com_tim11_handler,
    tim1_cc_handler,
    tim2_handler,               /* 28 */
    tim3_handler,
    tim4_handler,
    i2c1_ev_handler,
    i2c1_er_handler,
    i2c2_ev_handler,
    i2c2_er_handler,
    spi1_handler,               /* 35 */
    spi2_handler,
    usart1_handler,
    usart2_handler,
    0,                          /* USART3 — not on F411 */
    exti15_10_handler,          /* 40 */
    rtc_alarm_handler,
    otg_fs_wkup_handler,
    0, 0, 0, 0,
    dma1_stream7_handler,       /* 47 */
    0,
    sdio_handler,               /* 49 */
    tim5_handler,
    spi3_handler,
    0, 0, 0, 0,
    dma2_stream0_handler,       /* 56 */
    dma2_stream1_handler,
    dma2_stream2_handler,
    dma2_stream3_handler,
    dma2_stream4_handler,
    0, 0, 0, 0, 0, 0,
    otg_fs_handler,             /* 67 */
    dma2_stream5_handler,
    dma2_stream6_handler,
    dma2_stream7_handler,
    usart6_handler,             /* 71 */
    i2c3_ev_handler,
    i2c3_er_handler,
    0, 0, 0, 0, 0, 0,
    fpu_handler,                /* 81 */
    0, 0,
    spi4_handler,               /* 84 */
    spi5_handler,
};

__attribute__((naked, noreturn)) void reset_handler(void)
{
    /* The core loads SP from vector[0], but a debugger that jumps straight to
     * reset_handler does not, so set it explicitly before touching memory.
     */
    __asm__ volatile ("ldr sp, =_stack_top");

    /* FPU on before any C runs: the compiler emits VFP instructions in code
     * built with -mfloat-abi=hard, and a fault here would be baffling. */
    CPACR |= (3UL << 20) | (3UL << 22);         /* CP10/CP11 full access */
    dsb();
    isb();

    for (uint32_t *s = &_data_load, *d = &_data_start; d < &_data_end; )
        *d++ = *s++;
    for (uint32_t *d = &_bss_start; d < &_bss_end; )
        *d++ = 0;

    SCB->VTOR = (uint32_t)vector_table;

    clock_init();
    main();

    for (;;)
        wfi();
}

void default_handler(void)
{
    /* Spin, leaving the active vector readable in ICSR so a debugger can say
     * which one it was.  Deliberately not BKPT or WFI — see park() in fault.c
     * for why both break the debug port here. */
    for (;;)
        __asm__ volatile ("nop" ::: "memory");
}
