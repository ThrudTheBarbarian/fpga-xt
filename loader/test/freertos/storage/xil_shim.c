/*
 * xil_shim.c — bare-loader implementations of the Xilinx BSP primitives that
 * xsdps + FatFs link against. The loader is -nostdlib bare-BSP, so it provides
 * these itself instead of pulling in the full standalone BSP.
 *
 * xsdps is driven in POLLED mode, so the interrupt-wrap functions are referenced
 * (link) but never called — they're stubs.
 */
#include "xil_types.h"

static inline u32 rd32(UINTPTR a) { return *(volatile u32 *)a; }

/* timing — A9 global timer, free-running at PERIPHCLK = CPU/2 = 333 MHz */
void usleep(unsigned long us)
{
    volatile u32 *lo = (volatile u32 *)0xF8F00200u;
    u32 s = *lo, ticks = (u32)us * 333u;
    while ((u32)(*lo - s) < ticks) { }
}

/* D-cache maintenance by MVA (CP15, 32-byte lines) — for xsdps DMA buffers */
void Xil_DCacheFlushRange(INTPTR adr, u32 len)
{
    UINTPTR a = (UINTPTR)adr & ~31u, e = (UINTPTR)adr + len;
    for (; a < e; a += 32u) __asm__ volatile("mcr p15,0,%0,c7,c14,1" :: "r"(a));  /* DCCIMVAC clean+inval */
    __asm__ volatile("dsb");
}
void Xil_DCacheInvalidateRange(INTPTR adr, u32 len)
{
    if (len == 0u) return;
    UINTPTR a = (UINTPTR)adr, end = (UINTPTR)adr + len;
    /* Unaligned head/tail lines hold bytes OUTSIDE [adr,end) that may be dirty
     * (e.g. saved return addresses on the stack). Plain invalidate would discard
     * them -> corruption. clean+invalidate those partial lines (preserves them);
     * invalidate only the fully-covered middle. (Matches Xilinx Xil_DCacheInvalidateRange.) */
    if (a & 31u) {
        UINTPTR la = a & ~31u;
        __asm__ volatile("mcr p15,0,%0,c7,c14,1" :: "r"(la));    /* DCCIMVAC clean+inval */
        a = la + 32u;
    }
    if (end & 31u) {
        UINTPTR le = end & ~31u;
        __asm__ volatile("mcr p15,0,%0,c7,c14,1" :: "r"(le));    /* DCCIMVAC clean+inval */
        end = le;
    }
    for (; a < end; a += 32u) __asm__ volatile("mcr p15,0,%0,c7,c6,1" :: "r"(a));  /* DCIMVAC inval */
    __asm__ volatile("dsb");
}

/* asserts disabled */
u32 Xil_AssertStatus;
void Xil_Assert(const char *file, s32 line) { (void)file; (void)line; }

/* event polling (xsdps cmd/xfer completion). Returns 0 (XST_SUCCESS) / 1 (XST_FAILURE). */
u32 Xil_WaitForEvent(UINTPTR RegAddr, u32 EventMask, u32 Event, u32 Timeout)
{
    do {
        if ((rd32(RegAddr) & EventMask) == Event) return 0u;
        usleep(1);
    } while (Timeout--);
    return 1u;
}
u32 Xil_WaitForEvents(UINTPTR EventsRegAddr, u32 EventsMask, u32 WaitEvents,
                      u32 Timeout, u32 *Events)
{
    do {
        u32 v = rd32(EventsRegAddr) & EventsMask;
        if (v & WaitEvents) { if (Events) *Events = v; return 0u; }
        usleep(1);
    } while (Timeout--);
    if (Events) *Events = 0u;
    return 1u;
}

/* interrupt wrap — polled mode: linked, never called */
int  XConfigInterruptCntrl(UINTPTR p) { (void)p; return 0; }
int  XConnectToInterruptCntrl(u32 id, void *h, void *cb, UINTPTR p) { (void)id; (void)h; (void)cb; (void)p; return 0; }
void XEnableIntrId(u32 id, UINTPTR p) { (void)id; (void)p; }
void XDisableIntrId(u32 id, UINTPTR p) { (void)id; (void)p; }
void XRegisterInterruptHandler(void *h, UINTPTR p) { (void)h; (void)p; }
void Xil_ExceptionInit(void) { }
void Xil_ExceptionEnable(void) { }

/* string helpers FatFs/xsdps use that the loader's bare_libc lacks */
char *strchr(const char *s, int c)
{
    for (; *s; s++) if (*s == (char)c) return (char *)s;
    return (c == 0) ? (char *)s : (char *)0;
}
char *strrchr(const char *s, int c)
{
    const char *last = (c == 0) ? s : (const char *)0;
    for (; *s; s++) if (*s == (char)c) last = s;
    return (char *)last;
}
