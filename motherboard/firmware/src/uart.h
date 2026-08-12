/* uart.h — see uart.c */
#ifndef UART_H
#define UART_H

#include <stdint.h>
#include "stm32f411.h"

/* USART2 (PA2/PA3) — the FPGA/Zynq control link and the ROM-bootloader pins */
void uart2_init(uint32_t baud);
int  uart2_write(const char *data, int len);    /* blocking, but only ever a FIFO wait */
int  uart2_read(char *data, int len);           /* non-blocking, from the rx ring */
int  uart2_readable(void);

#endif /* UART_H */
