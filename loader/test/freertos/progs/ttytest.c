/* ttytest.c — raw-mode tty regression (bare usys). Scripted under qemu:
 * the line AFTER `ttytest` on stdin must be `xyz` — raw mode reads it a byte
 * at a time (no line buffering, echo off), then cooked mode is restored and
 * the NEXT line (`end`) must arrive whole. Exit 0 + "ttytest: all PASS". */
#include "usys.h"

static void w(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }

static int fails;
static void expect(const char *what, int ok)
{
    w(ok ? "  [PASS] " : "  [FAIL] ");
    w(what);
    w("\n");
    if (!ok) fails++;
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    struct xt_ttymode m;

    expect("GETMODE on stdin", sys_ioctl(0, XT_TTY_GETMODE, &m) == 0);
    expect("boot mode is cooked+echo", m.canon == 1 && m.echo == 1);

    m.canon = 0; m.echo = 0;                         /* enter raw, no echo */
    expect("SETMODE raw", sys_ioctl(0, XT_TTY_SETMODE, &m) == 0);
    expect("GETMODE reflects raw", sys_ioctl(0, XT_TTY_GETMODE, &m) == 0 &&
                                   m.canon == 0 && m.echo == 0);

    /* "xyz\n" byte-at-a-time: each 1-byte read must return exactly 1 byte
     * without waiting for a full line */
    char c = 0; int ok = 1;
    static const char want[4] = { 'x', 'y', 'z', '\n' };
    for (int i = 0; i < 4; i++) {
        if (sys_read(0, &c, 1) != 1 || c != want[i]) { ok = 0; break; }
    }
    expect("raw single-byte reads deliver x y z NL", ok);

    m.canon = 1; m.echo = 1;                         /* back to cooked */
    expect("SETMODE cooked", sys_ioctl(0, XT_TTY_SETMODE, &m) == 0);

    char line[8];
    long n = sys_read(0, line, sizeof line);         /* next scripted line: "end" */
    expect("cooked read returns the whole line", n == 4 &&
           line[0] == 'e' && line[1] == 'n' && line[2] == 'd' && line[3] == '\n');

    if (fails) { w("ttytest: FAILURES\n"); sys_exit(1); }
    w("ttytest: all PASS\n");
    sys_exit(0);
}
