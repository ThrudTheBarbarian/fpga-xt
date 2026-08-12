/* console.h — see console.c */
#ifndef CONSOLE_H
#define CONSOLE_H

#include <stdarg.h>
#include <stdint.h>

void console_init(uint32_t uart_baud);          /* 0 = RTT only */
void console_write(const char *data, int len);
void console_putc(char c);
void console_puts(const char *s);
int  console_getc(void);                        /* -1 when nothing pending */
void console_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void console_vprintf(const char *fmt, va_list ap);

#endif /* CONSOLE_H */
