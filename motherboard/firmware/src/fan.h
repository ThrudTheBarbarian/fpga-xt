/* fan.h — see fan.c */
#ifndef FAN_H
#define FAN_H

#include <stdint.h>

void     fan_init(void);
void     fan_poll(void);                        /* call from the main loop */
void     fan_tach_input(int on);                /* release PC9 for MCO2 */
void     fan_set_duty(uint16_t per_mille);      /* open loop, 0..1000 */
void     fan_set_target_rpm(uint16_t rpm);      /* 0 disables the PID */
uint32_t fan_rpm(void);
uint16_t fan_duty(void);
uint16_t fan_target_rpm(void);
int      fan_closed_loop(void);

/* Thermal mode: the A9 pushes the Zynq's XADC junction temperature over the
 * SPI link and this drives the RPM setpoint.  Fails to full duty if the
 * temperature goes stale — see fan.c. */
void     fan_set_temperature(uint8_t celsius);  /* called from the SPI ISR */
void     fan_set_thermal(int on);
int      fan_thermal(void);
uint8_t  fan_temperature(void);
uint32_t fan_temp_age_ms(void);

#endif /* FAN_H */
