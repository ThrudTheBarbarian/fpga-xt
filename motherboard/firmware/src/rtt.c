/* rtt.c — console over SWD, no wires.
 *
 * A clean-room implementation of the RTT control-block layout that debuggers
 * (including the Black Magic Probe's `monitor rtt`) look for: the probe scans
 * target RAM for the ID string, then reads and writes the ring buffers over
 * the debug AP while the CPU keeps running.  Nothing is linked in from SEGGER;
 * only the on-the-wire structure is shared, which is what interoperability
 * requires.
 *
 * We need this because the board has no free debug UART: J17 brings out SWDIO,
 * SWCLK and NRST but leaves SWO unconnected, and PB3 — the TRACESWO pin — is
 * spent on USART1_RX for the SIO port.  RTT costs zero pins.
 *
 * Writes are non-blocking and drop on overflow, so a board running with no
 * debugger attached never stalls in a printf.
 */
#include "rtt.h"

#include <stddef.h>
#include <stdint.h>

#include "stm32f411.h"

#define UP_SIZE     4096
#define DOWN_SIZE   128

typedef struct {
    const char       *name;
    char             *buffer;
    unsigned          size;
    unsigned          wr;                   /* written by target */
    volatile unsigned rd;                   /* written by host   */
    unsigned          flags;
} rtt_up_t;

typedef struct {
    const char       *name;
    char             *buffer;
    unsigned          size;
    volatile unsigned wr;                   /* written by host   */
    unsigned          rd;                   /* written by target */
    unsigned          flags;
} rtt_down_t;

typedef struct {
    char       id[16];
    int        max_up;
    int        max_down;
    rtt_up_t   up[1];
    rtt_down_t down[1];
} rtt_cb_t;

#define RTT_MODE_SKIP   0U                  /* drop writes that do not fit */

static char s_up_buf[UP_SIZE];
static char s_down_buf[DOWN_SIZE];

/* The ID must be exactly "SEGGER RTT" padded with NULs to 16 bytes — that is
 * the sequence probes search for.  Deliberately assembled at runtime in
 * rtt_init() so a half-initialised block is never discovered by a probe that
 * happens to scan during startup.
 */
__attribute__((aligned(4), used))
rtt_cb_t _SEGGER_RTT = {
    .id       = { 0 },
    .max_up   = 1,
    .max_down = 1,
    .up   = {{ "Terminal", s_up_buf,   UP_SIZE,   0, 0, RTT_MODE_SKIP }},
    .down = {{ "Terminal", s_down_buf, DOWN_SIZE, 0, 0, RTT_MODE_SKIP }},
};

void rtt_init(void)
{
    static const char id[] = "SEGGER RTT";

    _SEGGER_RTT.up[0].wr   = 0;
    _SEGGER_RTT.up[0].rd   = 0;
    _SEGGER_RTT.down[0].wr = 0;
    _SEGGER_RTT.down[0].rd = 0;

    dsb();                                  /* buffers valid before the ID */
    for (unsigned i = 0; i < sizeof id - 1; i++)
        _SEGGER_RTT.id[i] = id[i];
    dsb();
}

/* Free space in the up buffer.  One slot is always left empty so that
 * wr == rd unambiguously means "empty".
 */
static unsigned up_space(void)
{
    unsigned rd = _SEGGER_RTT.up[0].rd;
    unsigned wr = _SEGGER_RTT.up[0].wr;

    if (rd > wr)
        return rd - wr - 1U;
    return UP_SIZE - 1U - (wr - rd);
}

int rtt_write(const char *data, int len)
{
    if (len <= 0)
        return 0;

    uint32_t pm = irq_save();

    unsigned space = up_space();
    unsigned n     = (unsigned)len > space ? space : (unsigned)len;
    unsigned wr    = _SEGGER_RTT.up[0].wr;

    for (unsigned i = 0; i < n; i++) {
        s_up_buf[wr] = data[i];
        if (++wr == UP_SIZE)
            wr = 0;
    }

    dsb();                                  /* data lands before the pointer */
    _SEGGER_RTT.up[0].wr = wr;

    irq_restore(pm);
    return (int)n;
}

int rtt_read(char *data, int len)
{
    if (len <= 0)
        return 0;

    uint32_t pm = irq_save();

    unsigned wr = _SEGGER_RTT.down[0].wr;
    unsigned rd = _SEGGER_RTT.down[0].rd;
    int      n  = 0;

    while (rd != wr && n < len) {
        data[n++] = s_down_buf[rd];
        if (++rd == DOWN_SIZE)
            rd = 0;
    }

    _SEGGER_RTT.down[0].rd = rd;

    irq_restore(pm);
    return n;
}

int rtt_readable(void)
{
    unsigned wr = _SEGGER_RTT.down[0].wr;
    unsigned rd = _SEGGER_RTT.down[0].rd;

    return wr >= rd ? (int)(wr - rd) : (int)(DOWN_SIZE - rd + wr);
}

int rtt_attached(void)
{
    /* A host that has read anything, or has drained us, has clearly attached.
     * Not authoritative — just good enough to decide whether to bother
     * buffering a banner. */
    return _SEGGER_RTT.up[0].rd != 0 || _SEGGER_RTT.down[0].wr != 0;
}
