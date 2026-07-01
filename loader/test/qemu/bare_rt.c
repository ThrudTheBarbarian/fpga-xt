/* bare_rt — ARM semihosting I/O for the qemu testbeds. (Freestanding libc bits
 * + the bump allocator are in bare_libc.c, used only by the -nostdlib bare-metal
 * tests; the FreeRTOS build uses newlib instead.) */
#include "bare_rt.h"

#ifdef XT_HW_UART
/* Real hardware: poll the Zynq UART1 FIFO (0xE0001000, configured by ps7_init).
 * The testbed installs its own SVC vector, so ARM semihosting — which qemu
 * intercepts ABOVE the guest — isn't available on metal; talk to the UART. */
#define UART1_BASE 0xE0001000u
#define UART_SR    (*(volatile unsigned int *)(UART1_BASE + 0x2Cu))
#define UART_FIFO  (*(volatile unsigned int *)(UART1_BASE + 0x30u))
#define SR_TXFULL  0x10u
#define SR_RXEMPTY 0x02u
static void u_putc(char c) { while (UART_SR & SR_TXFULL) { } UART_FIFO = (unsigned char)c; }
void puts0(const char *s) { while (*s) { if (*s == '\n') u_putc('\r'); u_putc(*s++); } }
/* sh_readc lives in uart1_rx.c on HW: interrupt-driven + blocking (no busy-wait). */
void sh_exit(int code) { (void)code; puts0("\n[testbed halted — power-cycle]\n"); for (;;) { } }
/* host filesystem is a qemu-semihosting facility — unavailable on real metal. */
long hostfs_open(const char *p) { (void)p; return -1; }
long hostfs_len(long h) { (void)h; return -1; }
long hostfs_read(long h, void *b, long n) { (void)h; (void)b; (void)n; return -1; }
void hostfs_close(long h) { (void)h; }
#else
static long sh(long op, void *arg)
{
    register long r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = arg;
    __asm__ volatile("svc 0x123456" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}
void puts0(const char *s) { sh(0x04 /*SYS_WRITE0*/, (void *)s); }
int  sh_readc(void) { return (int)sh(0x07 /*SYS_READC*/, (void *)0); }
void sh_exit(int code) { long b[2] = { 0x20026, code }; sh(0x20 /*EXIT_EXTENDED*/, b); for (;;) {} }

/* host filesystem over ARM semihosting (qemu reads the HOST fs) — lets the test
 * harness run binaries from a host folder without rebuilding the romfs. */
long hostfs_open(const char *path)
{
    long n = 0; while (path[n]) n++;
    long a[3] = { (long)path, 1 /*"rb"*/, n };
    return sh(0x01 /*SYS_OPEN*/, a);
}
long hostfs_len(long h) { long a = h; return sh(0x0C /*SYS_FLEN*/, &a); }
long hostfs_read(long h, void *buf, long len)
{
    long a[3] = { h, (long)buf, len };
    long notread = sh(0x06 /*SYS_READ*/, a);     /* returns bytes NOT read (0 = all) */
    return notread < 0 ? -1 : len - notread;
}
void hostfs_close(long h) { long a = h; sh(0x02 /*SYS_CLOSE*/, &a); }
#endif

void putu(unsigned v)
{
    char t[12]; int n = 0;
    if (!v) { puts0("0"); return; }
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    char o[12]; int i = 0; while (n) o[i++] = t[--n]; o[i] = 0; puts0(o);
}

void rt_write(const char *b, int n)
{
    char t[256]; int i = 0;
    while (n-- > 0 && i < (int)sizeof(t) - 1) t[i++] = *b++;
    t[i] = 0; puts0(t);
}
