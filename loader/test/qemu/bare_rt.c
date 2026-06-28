/* bare_rt — see bare_rt.h. Freestanding; no libc. */
#include "bare_rt.h"

/* ---- freestanding libc bits the loader / kernel need ------------------- */
void *memcpy(void *d, const void *s, size_t n)
{ unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, size_t n)
{ unsigned char *a = d; while (n--) *a++ = (unsigned char)c; return d; }
void *memmove(void *d, const void *s, size_t n)
{ unsigned char *a = d; const unsigned char *b = s;
  if (a < b) while (n--) *a++ = *b++;
  else { a += n; b += n; while (n--) *--a = *--b; } return d; }
int strcmp(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return (unsigned char)*a - (unsigned char)*b; }
int memcmp(const void *a, const void *b, size_t n)
{ const unsigned char *x = a, *y = b; for (; n--; x++, y++) if (*x != *y) return *x - *y; return 0; }
size_t strlen(const char *s) { const char *p = s; while (*p) p++; return (size_t)(p - s); }

/* ---- ARM semihosting --------------------------------------------------- */
static long sh(long op, void *arg)
{
    register long r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = arg;
    __asm__ volatile("svc 0x123456" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}
void puts0(const char *s) { sh(0x04 /*SYS_WRITE0*/, (void *)s); }
void sh_exit(int code) { long b[2] = { 0x20026, code }; sh(0x20 /*EXIT_EXTENDED*/, b); for (;;) {} }

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

/* ---- bump allocator over the linker-defined arena ---------------------- */
extern char _heap_start[], _heap_end[];
static char *g_hp;
void *bump(size_t size, size_t align, void *u)
{
    (void)u;
    if (!g_hp) g_hp = _heap_start;
    uintptr_t a = ((uintptr_t)g_hp + align - 1) & ~(uintptr_t)(align - 1);
    char *p = (char *)a;
    if (p + size > _heap_end) return NULL;
    g_hp = p + size;
    return p;
}
