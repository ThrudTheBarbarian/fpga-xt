/* freqcount.h — see freqcount.c */
#ifndef FREQCOUNT_H
#define FREQCOUNT_H

#include <stdint.h>

void     freqcount_init(void);                  /* PA0 = TIM5_CH1 edge counter */
uint32_t freqcount_measure(void);               /* Hz; blocks for the gate time */
uint32_t freqcount_selftest(unsigned edges);    /* should return `edges`        */
int         freqcount_select(const char *name); /* "d12" | "e5" | "a0"          */
const char *freqcount_pin(void);
const char *freqcount_where(void);

#endif /* FREQCOUNT_H */
