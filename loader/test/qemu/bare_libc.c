/* bare_libc — freestanding libc bits + bump allocator for the -nostdlib
 * bare-metal testbeds (make test/qemu/kernel). The FreeRTOS build uses newlib
 * instead, so it does NOT compile this file. */
#include "bare_rt.h"

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
