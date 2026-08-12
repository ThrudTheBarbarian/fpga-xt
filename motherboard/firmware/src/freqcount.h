/* freqcount.h — see freqcount.c */
#ifndef FREQCOUNT_H
#define FREQCOUNT_H

#include <stdint.h>

void     freqcount_init(void);                  /* PA0 = TIM5_CH1 edge counter */
uint32_t freqcount_measure(void);               /* Hz; blocks for the gate time */
uint32_t freqcount_selftest(unsigned edges);    /* should return `edges`        */

#endif /* FREQCOUNT_H */
