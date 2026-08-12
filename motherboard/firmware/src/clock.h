/* clock.h — see clock.c */
#ifndef CLOCK_H
#define CLOCK_H

#include <stdint.h>

void        clock_init(void);                   /* called from reset_handler */
uint32_t    clock_millis(void);
uint32_t    clock_cycles(void);                 /* DWT cycle counter, wraps  */
void        clock_delay_us(uint32_t us);
void        clock_delay_ms(uint32_t ms);
uint32_t    clock_reset_cause(void);            /* raw RCC_CSR at boot       */
const char *clock_reset_cause_str(void);
int         clock_on_hse(void);                 /* 0 = fell back to HSI      */
void        clock_reboot(void);                 /* system reset, no return   */

#endif /* CLOCK_H */
