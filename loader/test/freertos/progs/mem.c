/* mem.c — /bin/mem: peek/poke a physical cell (the old Lua-shell mr/mw).
 *   mem [-b|-h|-w] <addr>          read : prints "<addr>: <val>"
 *   mem [-b|-h|-w] <addr> <value>  write: writes <value>, prints the read-back
 * -b/-h/-w select a byte/half/word access (default word). addr/value are hex
 * (leading 0x optional). The kernel does the SIZED access via SYS_devmem in PL1,
 * so an unaligned Device cell (the SALLY ROM window $43C0_xxxx, sub-word GP0
 * regs) reads/writes without an alignment fault, and the M7-gated plane band
 * stays reachable. DEBUG tool — no bounds check; a wild address faults the
 * caller, not the kernel. */
#include <stdint.h>
#include "usys.h"

static unsigned long parse_hex(const char *s)
{
    unsigned long v = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    for (; *s; s++) {
        int d;
        char c = *s;
        if      (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        v = (v << 4) | (unsigned)d;
    }
    return v;
}

/* write "0x" + `digits` hex nibbles of v into out; NUL-terminates; returns out */
static char *hexn(char *out, unsigned long v, int digits)
{
    static const char h[] = "0123456789ABCDEF";
    out[0] = '0'; out[1] = 'x';
    for (int i = 0; i < digits; i++) out[2 + i] = h[(v >> ((digits - 1 - i) * 4)) & 0xF];
    out[2 + digits] = 0;
    return out;
}

static void usage(void)
{
    static const char u[] = "usage: mem [-b|-h|-w] <addr> [<value>]   (hex; -b/-h/-w = byte/half/word, default word)\n";
    sys_write(2, u, sizeof u - 1);
    sys_exit(2);
}

void _app_entry(int argc, char **argv)
{
    int size = 4;                                   /* default word */
    int i = 1;
    if (i < argc && argv[i][0] == '-') {
        switch (argv[i][1]) {
        case 'b': size = 1; break;
        case 'h': size = 2; break;
        case 'w': size = 4; break;
        default:  usage();
        }
        i++;
    }
    int npos = argc - i;                            /* remaining positional args */
    if (npos < 1 || npos > 2) usage();

    unsigned long addr  = parse_hex(argv[i]);
    int           write = (npos == 2);
    unsigned long val   = write ? parse_hex(argv[i + 1]) : 0;

    long r = sys_devmem_sz(addr, val, write, size);

    int digits = size * 2;                          /* 2/4/8 hex nibbles */
    unsigned long mask = (size == 4) ? 0xFFFFFFFFul : (size == 2) ? 0xFFFFul : 0xFFul;
    char ab[11], vb[11], line[24];
    hexn(ab, addr, 8);
    hexn(vb, (unsigned long)r & mask, digits);
    int n = 0;
    for (const char *p = ab; *p; p++) line[n++] = *p;
    line[n++] = ':'; line[n++] = ' ';
    for (const char *p = vb; *p; p++) line[n++] = *p;
    line[n++] = '\n';
    sys_write(1, line, (unsigned)n);
    sys_exit(0);
}
