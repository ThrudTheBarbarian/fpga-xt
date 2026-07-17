/* scale.c — /bin/scale: the XL plane integer scale (the old PS-REPL `scale`).
 *   scale            print the effective XL-plane scale
 *   scale <N>        set it; N = 0..7  (0 keeps the bitstream default)
 * Writes gp0_ctrl[3:1] (XT_CTRL_GP0, GP0 0x43C0_0300) — a read-modify-write that
 * preserves the other control bits (bars, DMACTL-blank, video-sleep). "PS does
 * config": the scale is a runtime register, not a re-bitstream. */
#include <stdint.h>
#include "usys.h"

#define CTRL_GP0   0x43C00300ul
#define SCALE_MASK 0x0Eu                            /* bits [3:1] */

static unsigned parse_dec(const char *s)
{
    unsigned v = 0;
    for (; *s >= '0' && *s <= '9'; s++) v = v * 10 + (unsigned)(*s - '0');
    return v;
}

static void emit_scale(unsigned s)
{
    char line[16]; int n = 0;
    line[n++] = 's'; line[n++] = 'c'; line[n++] = 'l'; line[n++] = ' ';
    line[n++] = (char)('0' + (s & 7));
    if (s == 0) { const char *d = " (default)"; for (const char *p = d; *p; p++) line[n++] = *p; }
    line[n++] = '\n';
    sys_write(1, line, (unsigned)n);
}

void _app_entry(int argc, char **argv)
{
    if (argc >= 2) {
        unsigned n = parse_dec(argv[1]);
        if (n > 7) {
            static const char u[] = "usage: scale [N]   N = 0..7 (0 = bitstream default)\n";
            sys_write(2, u, sizeof u - 1);
            sys_exit(2);
        }
        unsigned v = (unsigned)(sys_devmem(CTRL_GP0, 0, 0) & 0xFF);
        v = (v & ~SCALE_MASK) | ((n & 7u) << 1);
        sys_devmem(CTRL_GP0, v, 1);                 /* aligned word RMW poke */
    }
    unsigned eff = (unsigned)(sys_devmem(CTRL_GP0, 0, 0) & 0xFF);
    emit_scale((eff & SCALE_MASK) >> 1);
    sys_exit(0);
}
