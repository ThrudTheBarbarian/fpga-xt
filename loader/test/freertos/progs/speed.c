/* speed.c — /bin/speed: the SALLY turbo multiplier (the old PS-REPL `speed`).
 *   speed            print the effective 6502 clock multiplier
 *   speed <N>        set it; N must be one of 1 2 4 7 8 14 28 56
 * Writes XT_CTRL_SPEED (GP0 0x43C0_0304), which the fabric mirrors to the 6502
 * $D4CA; the register read-back is the *effective* multiplier (the HW snaps an
 * out-of-set value to 1). "PS does config": the multiplier lives here, not in a
 * bitstream. */
#include <stdint.h>
#include "usys.h"

#define CTRL_SPEED 0x43C00304ul

static const unsigned VALID[] = { 1, 2, 4, 7, 8, 14, 28, 56 };

static unsigned parse_dec(const char *s)
{
    unsigned v = 0;
    for (; *s >= '0' && *s <= '9'; s++) v = v * 10 + (unsigned)(*s - '0');
    return v;
}

/* decimal of v into out (max 3 digits for our range), returns length */
static int dec(char *out, unsigned v)
{
    char tmp[4]; int t = 0;
    if (v == 0) tmp[t++] = '0';
    while (v) { tmp[t++] = (char)('0' + v % 10); v /= 10; }
    for (int i = 0; i < t; i++) out[i] = tmp[t - 1 - i];
    return t;
}

static void emit_speed(unsigned m)
{
    char line[16]; int n = 0;
    line[n++] = 's'; line[n++] = 'p'; line[n++] = 'd'; line[n++] = ' ';
    n += dec(line + n, m);
    line[n++] = 'x'; line[n++] = '\n';
    sys_write(1, line, (unsigned)n);
}

void _app_entry(int argc, char **argv)
{
    if (argc >= 2) {
        unsigned n = parse_dec(argv[1]);
        int ok = 0;
        for (unsigned i = 0; i < sizeof VALID / sizeof VALID[0]; i++) if (VALID[i] == n) ok = 1;
        if (!ok) {
            static const char u[] = "usage: speed [N]   N in {1 2 4 7 8 14 28 56}\n";
            sys_write(2, u, sizeof u - 1);
            sys_exit(2);
        }
        sys_devmem(CTRL_SPEED, n, 1);               /* aligned word poke */
    }
    unsigned eff = (unsigned)(sys_devmem(CTRL_SPEED, 0, 0) & 0xFF);
    emit_speed(eff);
    sys_exit(0);
}
