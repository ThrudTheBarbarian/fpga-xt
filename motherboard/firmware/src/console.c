/* console.c — one console, two transports.
 *
 * Output goes to every attached transport; input is taken from whichever one
 * has a character.  That means the same REPL answers the developer on the
 * Black Magic Probe (RTT over SWD) and the Zynq on USART2, with no mode
 * switch and no duplicated command table.
 *
 * The formatter is hand-rolled so the firmware links with -nostdlib: nothing
 * here needs a heap, a file table, or a syscall layer.
 */
#include "console.h"

#include <stdarg.h>
#include <stdint.h>

#include "rtt.h"
#include "uart.h"

static int s_uart_enabled;

void console_init(uint32_t uart_baud)
{
    rtt_init();
    if (uart_baud) {
        uart2_init(uart_baud);
        s_uart_enabled = 1;
    }
}

void console_write(const char *data, int len)
{
    rtt_write(data, len);
    if (s_uart_enabled)
        uart2_write(data, len);
}

void console_putc(char c)
{
    console_write(&c, 1);
}

void console_puts(const char *s)
{
    int n = 0;
    while (s[n])
        n++;
    console_write(s, n);
}

int console_getc(void)
{
    char c;

    if (rtt_read(&c, 1) == 1)
        return (unsigned char)c;
    if (s_uart_enabled && uart2_read(&c, 1) == 1)
        return (unsigned char)c;
    return -1;
}

/* ------------------------------------------------------------- formatting -*/

static void emit_pad(char pad, int n)
{
    while (n-- > 0)
        console_putc(pad);
}

static void emit_num(uint32_t v, unsigned base, int is_signed, int neg,
                     int width, char pad, int upper)
{
    static const char lower[] = "0123456789abcdef";
    static const char upperd[] = "0123456789ABCDEF";
    const char *digits = upper ? upperd : lower;
    char buf[12];
    int  n = 0;

    (void)is_signed;

    do {
        buf[n++] = digits[v % base];
        v /= base;
    } while (v);

    if (neg && pad == '0') {                /* -0007, not 000-7 */
        console_putc('-');
        width--;
        neg = 0;
    }
    if (neg)
        n++;

    emit_pad(pad, width - n);

    if (neg) {
        console_putc('-');
        n--;
    }
    while (n-- > 0)
        console_putc(buf[n]);
}

void console_vprintf(const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            console_putc(*fmt);
            continue;
        }

        fmt++;
        char pad   = ' ';
        int  width = 0;
        int  left  = 0;

        if (*fmt == '-') {
            left = 1;
            fmt++;
        }
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l' || *fmt == 'z')  /* 32-bit target: long == int */
            fmt++;

        if (left)
            pad = ' ';                      /* zero-padding a left-aligned field
                                             * is meaningless; ignore it */

        switch (*fmt) {
        case 'd': {
            int32_t v = va_arg(ap, int32_t);
            emit_num(v < 0 ? (uint32_t)(-v) : (uint32_t)v, 10, 1, v < 0,
                     left ? 0 : width, pad, 0);
            break;
        }
        case 'u':
            emit_num(va_arg(ap, uint32_t), 10, 0, 0, left ? 0 : width, pad, 0);
            break;
        case 'x':
            emit_num(va_arg(ap, uint32_t), 16, 0, 0, left ? 0 : width, pad, 0);
            break;
        case 'X':
            emit_num(va_arg(ap, uint32_t), 16, 0, 0, left ? 0 : width, pad, 1);
            break;
        case 'p':
            console_puts("0x");
            emit_num((uint32_t)va_arg(ap, void *), 16, 0, 0, 8, '0', 0);
            break;
        case 'c':
            console_putc((char)va_arg(ap, int));
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s)
                s = "(null)";
            int n = 0;
            while (s[n])
                n++;
            if (left) {
                console_write(s, n);
                emit_pad(' ', width - n);
            } else {
                emit_pad(' ', width - n);
                console_write(s, n);
            }
            break;
        }
        case '%':
            console_putc('%');
            break;
        case '\0':
            return;
        default:
            console_putc('%');
            console_putc(*fmt);
            break;
        }
    }
}

void console_printf(const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    console_vprintf(fmt, ap);
    va_end(ap);
}
