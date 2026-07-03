/* net_libc.c — the three libc bits lwIP's core leans on that the -nostdlib
 * kernel doesn't carry: strncmp/atoi (dhcp/netif option parsing) and newlib's
 * _ctype_ classification table (the <ctype.h> macros index it at c+1). */
#include <stddef.h>

int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
        if (!*a) return 0;
    }
    return 0;
}

int atoi(const char *s)
{
    int v = 0, neg = 0;
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return neg ? -v : v;
}

/* newlib layout: _U 01, _L 02, _N 04, _S 010, _P 020, _C 040, _X 0100, _B 0200 */
#define U 0x01
#define L 0x02
#define N 0x04
#define S 0x08
#define P 0x10
#define C 0x20
#define X 0x40
#define B 0x80
const char _ctype_[257] = {
    0,
    C, C, C, C, C, C, C, C, C, C|S, C|S, C|S, C|S, C|S, C, C,           /* 00-0f */
    C, C, C, C, C, C, C, C, C, C, C, C, C, C, C, C,                     /* 10-1f */
    S|B, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P,                   /* 20-2f */
    N, N, N, N, N, N, N, N, N, N, P, P, P, P, P, P,                     /* 30-3f */
    P, U|X, U|X, U|X, U|X, U|X, U|X, U, U, U, U, U, U, U, U, U,         /* 40-4f */
    U, U, U, U, U, U, U, U, U, U, U, P, P, P, P, P,                     /* 50-5f */
    P, L|X, L|X, L|X, L|X, L|X, L|X, L, L, L, L, L, L, L, L, L,         /* 60-6f */
    L, L, L, L, L, L, L, L, L, L, L, P, P, P, P, C,                     /* 70-7f */
    /* 80-ff: zero */
};

/* xemacps_pcs.c's USX error path (never taken on a Zynq-7000 GEM — no
 * high-speed PCS) calls exit(); satisfy the link. */
void exit(int code) { (void)code; for (;;) ; }

/* minimal snprintf for mdns's conflict-rename ("%s-%d"): %s %d %u %c only */
int snprintf(char *out, size_t cap, const char *fmt, ...)
{
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);
    size_t o = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') { if (o + 1 < cap) out[o] = *fmt; o++; continue; }
        fmt++;
        if (*fmt == 's') {
            const char *s = __builtin_va_arg(ap, const char *);
            for (; s && *s; s++) { if (o + 1 < cap) out[o] = *s; o++; }
        } else if (*fmt == 'd' || *fmt == 'u') {
            int v = __builtin_va_arg(ap, int);
            unsigned u = (unsigned)v;
            char t[12]; int i = 0;
            if (*fmt == 'd' && v < 0) { if (o + 1 < cap) out[o] = '-'; o++; u = (unsigned)-v; }
            do { t[i++] = (char)('0' + u % 10); u /= 10; } while (u);
            while (i) { if (o + 1 < cap) out[o] = t[--i]; o++; }
        } else if (*fmt == 'c') {
            char c = (char)__builtin_va_arg(ap, int);
            if (o + 1 < cap) out[o] = c; o++;
        } else {
            if (o + 1 < cap) out[o] = *fmt; o++;
        }
    }
    if (cap) out[o < cap ? o : cap - 1] = 0;
    __builtin_va_end(ap);
    return (int)o;
}
