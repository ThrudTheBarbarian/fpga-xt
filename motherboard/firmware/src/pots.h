/* pots.h — see pots.c */
#ifndef POTS_H
#define POTS_H

#include <stdint.h>

/* POKEY POT0..POT7 order: two pots per controller port, ports left to right. */
enum {
    POT_ILL_A = 0, POT_ILL_B,
    POT_IL_A,      POT_IL_B,
    POT_IR_A,      POT_IR_B,
    POT_IRR_A,     POT_IRR_B,
    POT_COUNT
};

void     pots_init(void);
void     pots_poll(void);                       /* non-blocking state machine */
uint8_t  pots_value(int pot);                   /* 0..228, POKEY scale */
uint32_t pots_micros(int pot);                  /* raw charge time */
uint32_t pots_frames(void);                     /* completed sweeps */
void     pots_calibrate(uint32_t min_us, uint32_t max_us);
void     pots_calibration(uint32_t *min_us, uint32_t *max_us);

#endif /* POTS_H */
