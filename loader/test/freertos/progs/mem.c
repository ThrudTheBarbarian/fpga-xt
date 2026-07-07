/* mem.c — /bin/mem: peek/poke a 32-bit physical word (the old Lua-shell mr/mw).
 *   mem <addr>          read : prints "<addr>: <val>"
 *   mem <addr> <value>  write: writes <value>, prints the read-back
 * addr/value are hex (leading 0x optional). The kernel does the access via
 * SYS_devmem (its MMU is identity-mapped and reaches GP0 / DDR / peripherals).
 * DEBUG tool — no bounds check; a bad address faults the caller, not the kernel. */
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

/* write "0xXXXXXXXX" into out[0..9], NUL at out[10]; returns out */
static char *hex8(char *out, unsigned long v)
{
    static const char h[] = "0123456789ABCDEF";
    out[0] = '0'; out[1] = 'x';
    for (int i = 0; i < 8; i++) out[2 + i] = h[(v >> ((7 - i) * 4)) & 0xF];
    out[10] = 0;
    return out;
}

void _app_entry(int argc, char **argv)
{
    if (argc < 2 || argc > 3) {
        static const char u[] = "usage: mem <addr> [<value>]   (hex; 2 args read, 3 args write)\n";
        sys_write(2, u, sizeof u - 1);
        sys_exit(2);
    }
    unsigned long addr  = parse_hex(argv[1]);
    int           write = (argc == 3);
    unsigned long val   = write ? parse_hex(argv[2]) : 0;

    long r = sys_devmem(addr, val, write);

    char ab[11], vb[11], line[24];
    hex8(ab, addr);
    hex8(vb, (unsigned long)r);   /* ARM32: long is 32-bit, matches the poked word */
    int n = 0;
    for (const char *p = ab; *p; p++) line[n++] = *p;
    line[n++] = ':'; line[n++] = ' ';
    for (const char *p = vb; *p; p++) line[n++] = *p;
    line[n++] = '\n';
    sys_write(1, line, (unsigned)n);
    sys_exit(0);
}
