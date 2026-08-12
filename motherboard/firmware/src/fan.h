/* fan.h — see fan.c */
#ifndef FAN_H
#define FAN_H

#include <stdint.h>

void     fan_init(void);
void     fan_poll(void);                        /* call from the main loop */
void     fan_set_duty(uint16_t per_mille);      /* open loop, 0..1000 */
void     fan_set_target_rpm(uint16_t rpm);      /* 0 disables the PID */
uint32_t fan_rpm(void);
uint16_t fan_duty(void);
uint16_t fan_target_rpm(void);
int      fan_closed_loop(void);

#endif /* FAN_H */
