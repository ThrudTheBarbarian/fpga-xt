/* dbg6502.c — /bin/6502: the in-fabric 6502 debugger front-end (docs/OS/6502-debug.md).
 *
 *   6502 status                 dump PC A X Y SP P (flags) + halted/icnt
 *   6502 halt                   run to the next instruction boundary, then freeze
 *   6502 go                     release / run
 *   6502 step [N]               execute N instructions (default 1) then freeze
 *   6502 break $DE34            arm a PC breakpoint (halts before executing it)
 *   6502 break off              disarm the breakpoint
 *   6502 breakreset on|off      halt at the reset-vector fetch on the next SALLYRST
 *   6502 reset                  pulse SALLYRST (halts at reset if breakreset is on)
 *   6502 PC=$200 SP=$FF ...     write registers while halted (REG: PC A X Y SP P)
 *   6502 PC=$4000 SP=$FF go     write registers, then run
 *
 * Talks to the GP0 DEBUG block (0x43C0_0800) via SYS_devmem — aligned words, so
 * plain sys_devmem is fine.  Register read-back is coherent only when halted. */
#include <stdint.h>
#include "usys.h"

#define GP0            0x43C00000ul
#define DBG            (GP0 + 0x800ul)
#define DBG_HALT       (DBG + 0x00)
#define DBG_GO         (DBG + 0x04)
#define DBG_STEP       (DBG + 0x08)
#define DBG_CFG        (DBG + 0x0C)     /* [0]=bkpt_en [1]=halt_at_reset */
#define DBG_BKPT       (DBG + 0x10)
#define DBG_COMMIT     (DBG + 0x14)
#define DBG_WPC        (DBG + 0x18)
#define DBG_WAXYS      (DBG + 0x1C)
#define DBG_WPSH       (DBG + 0x20)
#define DBG_STAT       (DBG + 0x24)     /* [0]halted [1]bkpt_hit [2]stepping [3]running */
#define DBG_PC         (DBG + 0x28)
#define DBG_AXYS       (DBG + 0x2C)
#define DBG_PSH        (DBG + 0x30)
#define DBG_ICNT       (DBG + 0x34)
#define DBG_TRC_CTRL   (DBG + 0x3C)     /* [0]=enable [1]=break_on_full */
#define DBG_TRC_WPTR   (DBG + 0x40)     /* [11:0]=wptr [16]=wrapped */
#define DBG_TRC_IDX    (DBG + 0x44)     /* set read index */
#define DBG_TRC_PC     (DBG + 0x48)
#define DBG_TRC_AXYS   (DBG + 0x4C)
#define DBG_TRC_P      (DBG + 0x50)
#define DBG_WP         (DBG + 0x54)     /* [15:0]=watchpoint address */
#define DBG_WPCFG      (DBG + 0x58)     /* [0]=en [1]=on_write [2]=on_read */
#define DBG_DIAG       (DBG + 0x5C)     /* [1:0]cfg_s [2]bkpt_seen [3]wp_seen [4]wp_was_hit [31:16]bkpt_s */
#define CTRL_SALLYRST  (GP0 + 0x31Cul)

static unsigned long rd(unsigned long a)            { return (unsigned long)sys_devmem(a, 0, 0); }
static void          wr(unsigned long a, unsigned long v) { sys_devmem(a, v, 1); }

/* ---- tiny string / number helpers (freestanding) ---- */
static int streq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == *b; }

static unsigned long parse_num(const char *s)       /* $hex, 0xhex, or decimal */
{
    unsigned long v = 0; int hex = 0;
    if (*s == '$') { s++; hex = 1; }
    else if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { s += 2; hex = 1; }
    for (; *s; s++) {
        char c = *s; int d;
        if      (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        if (!hex && d > 9) break;
        v = hex ? (v << 4) + d : v * 10 + d;
    }
    return v;
}

/* output buffer */
static char  ob[256]; static int on;
static void  oc(char c) { if (on < (int)sizeof ob) ob[on++] = c; }
static void  os(const char *s) { while (*s) oc(*s++); }
static void  ohex(unsigned long v, int digits)
{ static const char h[] = "0123456789ABCDEF"; oc('$');
  for (int i = digits - 1; i >= 0; i--) oc(h[(v >> (i * 4)) & 0xF]); }
static void  odec(unsigned long v)
{ char t[12]; int n = 0; if (!v) { oc('0'); return; }
  while (v) { t[n++] = '0' + v % 10; v /= 10; } while (n) oc(t[--n]); }
static void  flush(int fd) { sys_write(fd, ob, on); on = 0; }

/* spin-poll DBG_STAT until halted (bit0). Bounded so a runaway never wedges. */
static int poll_halt(void)
{
    for (long i = 0; i < 2000000; i++) if (rd(DBG_STAT) & 1u) return 1;
    return 0;
}

static void status(void)
{
    unsigned long st = rd(DBG_STAT), pc = rd(DBG_PC) & 0xFFFF;
    unsigned long ax = rd(DBG_AXYS), ps = rd(DBG_PSH), ic = rd(DBG_ICNT);
    unsigned A = ax & 0xFF, X = (ax >> 8) & 0xFF, Y = (ax >> 16) & 0xFF;
    unsigned Slo = (ax >> 24) & 0xFF, Shi = (ps >> 8) & 0xF, P = ps & 0xFF;
    static const char fl[8] = { 'N','V','-','B','D','I','Z','C' };  /* bit 7..0 */

    on = 0;
    os("6502 ");
    os((st & 1) ? "HALTED " : (st & 8) ? "RUN    " : "?      ");
    if (st & 2) os("(bkpt) ");
    os(" PC="); ohex(pc, 4);
    os("  A=");  ohex(A, 2);
    os(" X=");   ohex(X, 2);
    os(" Y=");   ohex(Y, 2);
    os(" SP=");  ohex((Shi << 8) | Slo, 3);
    os("  P=");  ohex(P, 2); os(" [");
    for (int i = 7; i >= 0; i--) {
        char c = fl[7 - i];
        oc((P >> i) & 1 ? c : (c >= 'A' && c <= 'Z' ? c + 32 : c));
    }
    os("]  icnt="); odec(ic); oc('\n');
    flush(1);
}

/* one help line (the 256-byte ob can't hold the whole screen, so flush per line) */
static void line(const char *s) { on = 0; os(s); oc('\n'); flush(1); }

static void help(void)
{
    line("6502 - control + debug the emulated 6502 (turbo xt6502 / fidelity xt6502f)");
    line("");
    line("  6502                    status: halt state, PC/regs, icnt");
    line("  6502 status");
    line("  6502 core [turbo|fid]   show or switch the active CPU core (cold-boots the OS on it)");
    line("  6502 halt               halt at the next instruction boundary");
    line("  6502 go                 resume");
    line("  6502 step [N]           single-step N instructions (default 1)");
    line("  6502 reset              cold-reset the 6502 realm");
    line("  6502 break $A           break before executing the instruction at $A");
    line("  6502 break off");
    line("  6502 breakreset on|off  break at the reset vector");
    line("  6502 watch $A [r|w|rw]  data watchpoint (default rw)");
    line("  6502 watch off");
    line("  6502 trace [on|off|N]   trace ring: enable/disable, or dump the last N");
    line("  6502 diag               debug-block self-observability");
    line("  6502 PC=$A A=.. X=.. Y=.. SP=.. P=.. [go]   inject registers");
    line("");
    line("cores:  turbo = xt6502  ~56x, documented ISA + xtc accel (default)");
    line("        fid   = xt6502f real 1x, all 256 opcodes cycle-exact + interrupts");
    line("note:   halt/step/break/watch/trace/diag target the turbo debugger for now;");
    line("        the fidelity core's own debug slots are wired next.");
}

void _app_entry(int argc, char **argv)
{
    if (argc < 2) { status(); sys_exit(0); }
    const char *cmd = argv[1];

    if (streq(cmd, "-h") || streq(cmd, "--help") || streq(cmd, "help")) { help(); sys_exit(0); }

    if (streq(cmd, "status")) { status(); sys_exit(0); }

    /* select the active CPU core (cpu_sel = CTRL_SALLYRST bit1) and cold-boot the OS on it */
    if (streq(cmd, "core")) {
        if (argc >= 3) {
            int fid   = streq(argv[2], "fid") || streq(argv[2], "fidelity");
            int turbo = streq(argv[2], "turbo");
            if (!fid && !turbo) { on = 0; os("usage: 6502 core [turbo|fid]\n"); flush(2); sys_exit(2); }
            unsigned long sel = fid ? 2ul : 0ul;      /* bit1 = cpu_sel */
            wr(CTRL_SALLYRST, sel | 1ul);             /* hold the 6502 realm in reset + select */
            wr(CTRL_SALLYRST, sel);                   /* release -> cold-boot on the selected core */
            on = 0; os("6502 core -> ");
            os(fid ? "fidelity (real 1x, cycle-exact)\n" : "turbo (~56x)\n"); flush(1);
        } else {
            unsigned long s = rd(CTRL_SALLYRST);
            on = 0; os("6502 core = "); os((s & 2ul) ? "fidelity\n" : "turbo\n"); flush(1);
        }
        sys_exit(0);
    }

    if (streq(cmd, "halt")) { wr(DBG_HALT, 1); poll_halt(); status(); sys_exit(0); }

    if (streq(cmd, "go"))   { wr(DBG_GO, 1);
        on = 0; os("6502 running\n"); flush(1); sys_exit(0); }

    if (streq(cmd, "step")) {
        unsigned long n = (argc >= 3) ? parse_num(argv[2]) : 1;
        if (!n) n = 1;
        wr(DBG_STEP, n); poll_halt(); status(); sys_exit(0);
    }

    if (streq(cmd, "reset")) {
        wr(CTRL_SALLYRST, 1); wr(CTRL_SALLYRST, 0);
        if (rd(DBG_CFG) & 2u) poll_halt();       /* halt_at_reset armed -> wait */
        status(); sys_exit(0);
    }

    if (streq(cmd, "break")) {
        unsigned long cfg = rd(DBG_CFG);
        if (argc >= 3 && streq(argv[2], "off")) { wr(DBG_CFG, cfg & ~1ul);
            on = 0; os("6502 breakpoint off\n"); flush(1); }
        else if (argc >= 3) {
            wr(DBG_BKPT, parse_num(argv[2]) & 0xFFFF);
            wr(DBG_CFG, cfg | 1ul);
            on = 0; os("6502 break at "); ohex(rd(DBG_BKPT) & 0xFFFF, 4); oc('\n'); flush(1);
        }
        sys_exit(0);
    }

    if (streq(cmd, "breakreset")) {
        unsigned long cfg = rd(DBG_CFG);
        int on2 = (argc >= 3 && streq(argv[2], "on"));
        wr(DBG_CFG, on2 ? (cfg | 2ul) : (cfg & ~2ul));
        on = 0; os("6502 breakreset "); os(on2 ? "on\n" : "off\n"); flush(1);
        sys_exit(0);
    }

    if (streq(cmd, "trace")) {
        if (argc >= 3 && streq(argv[2], "on"))  { wr(DBG_TRC_CTRL, rd(DBG_TRC_CTRL) | 1ul);
            on = 0; os("6502 trace on\n"); flush(1); sys_exit(0); }
        if (argc >= 3 && streq(argv[2], "off")) { wr(DBG_TRC_CTRL, rd(DBG_TRC_CTRL) & ~1ul);
            on = 0; os("6502 trace off\n"); flush(1); sys_exit(0); }
        /* dump the last N (default 32) instructions, oldest->newest */
        unsigned long n = (argc >= 3) ? parse_num(argv[2]) : 32;
        if (n > 4096) n = 4096; if (!n) n = 1;
        unsigned long w  = rd(DBG_TRC_WPTR);
        unsigned long wp = w & 0xFFF;
        unsigned long avail = (w & (1ul << 16)) ? 4096 : wp;    /* wrapped -> full */
        if (n > avail) n = avail;
        if (!avail) { on = 0; os("6502 trace: empty (enable with '6502 trace on')\n"); flush(1); sys_exit(0); }
        for (unsigned long i = 0; i < n; i++) {
            unsigned long idx = (wp + 4096 - n + i) & 0xFFF;
            wr(DBG_TRC_IDX, idx);
            unsigned long pc = rd(DBG_TRC_PC) & 0xFFFF;
            unsigned long ax = rd(DBG_TRC_AXYS);
            unsigned long ps = rd(DBG_TRC_P);
            on = 0;
            os("  "); ohex(pc, 4);
            os(" A=");  ohex(ax & 0xFF, 2);
            os(" X=");  ohex((ax >> 8) & 0xFF, 2);
            os(" Y=");  ohex((ax >> 16) & 0xFF, 2);
            os(" SP="); ohex((((ps >> 8) & 0xF) << 8) | ((ax >> 24) & 0xFF), 3);
            os(" P=");  ohex(ps & 0xFF, 2);
            oc('\n'); flush(1);
        }
        sys_exit(0);
    }

    if (streq(cmd, "watch")) {
        if (argc >= 3 && streq(argv[2], "off")) {
            wr(DBG_WPCFG, 0); on = 0; os("6502 watch off\n"); flush(1); sys_exit(0);
        }
        if (argc >= 3) {
            unsigned long cfg = 1;                     /* enable */
            const char *m = (argc >= 4) ? argv[3] : "rw";
            /* mode: r / w / rw (default). bit1=on_write bit2=on_read */
            int wantr = 0, wantw = 0;
            for (const char *p = m; *p; p++) { if (*p=='r'||*p=='R') wantr=1; if (*p=='w'||*p=='W') wantw=1; }
            if (!wantr && !wantw) { wantr = wantw = 1; }
            if (wantw) cfg |= 2; if (wantr) cfg |= 4;
            wr(DBG_WP, parse_num(argv[2]) & 0xFFFF);
            wr(DBG_WPCFG, cfg);
            on = 0; os("6502 watch "); os(wantr&&wantw?"rw":wantw?"w":"r");
            os(" @ "); ohex(rd(DBG_WP) & 0xFFFF, 4); oc('\n'); flush(1);
        }
        sys_exit(0);
    }

    if (streq(cmd, "diag")) {
        unsigned long d = rd(DBG_DIAG);
        on = 0;
        os("6502 diag: cfg_s="); ohex(d & 3, 1);
        os(" bkpt_seen="); oc((d>>2)&1 ? '1':'0');
        os(" wp_seen=");   oc((d>>3)&1 ? '1':'0');
        os(" wp_hit=");    oc((d>>4)&1 ? '1':'0');
        os("  bkpt_s=");   ohex((d>>16) & 0xFFFF, 4);
        oc('\n'); flush(1);
        sys_exit(0);
    }

    /* register-assignment form: PC=.. A=.. X=.. Y=.. SP=.. P=.. [go] */
    {
        int did_assign = 0, do_go = 0;
        unsigned long pc = rd(DBG_PC) & 0xFFFF;
        unsigned long ax = rd(DBG_AXYS);
        unsigned long ps = rd(DBG_PSH);
        for (int i = 1; i < argc; i++) {
            const char *t = argv[i];
            if (streq(t, "go")) { do_go = 1; continue; }
            /* find '=' */
            const char *e = t; while (*e && *e != '=') e++;
            if (*e != '=') {
                on = 0; os("6502: unknown '"); os(t); os("'\n"); flush(2); sys_exit(2);
            }
            unsigned long v = parse_num(e + 1);
            /* reg name = t..e */
            int L = (int)(e - t);
            if      (L == 2 && t[0] == 'P' && t[1] == 'C') pc = v & 0xFFFF;
            else if (L == 1 && t[0] == 'A') ax = (ax & ~0xFFul)        | (v & 0xFF);
            else if (L == 1 && t[0] == 'X') ax = (ax & ~0xFF00ul)      | ((v & 0xFF) << 8);
            else if (L == 1 && t[0] == 'Y') ax = (ax & ~0xFF0000ul)    | ((v & 0xFF) << 16);
            else if (L == 1 && t[0] == 'P') ps = (ps & ~0xFFul)        | (v & 0xFF);
            else if ((L == 2 && t[0] == 'S' && t[1] == 'P') || (L == 1 && t[0] == 'S')) {
                ax = (ax & ~0xFF000000ul) | ((v & 0xFF) << 24);         /* SP low */
                ps = (ps & ~0xF00ul)      | (((v >> 8) & 0xF) << 8);    /* SP high nibble */
            } else {
                on = 0; os("6502: bad reg '"); os(t); os("'\n"); flush(2); sys_exit(2);
            }
            did_assign = 1;
        }
        if (!did_assign) {
            on = 0; os("usage: 6502 status|core [turbo|fid]|halt|go|step [N]|break $A|break off|"
                       "breakreset on|off|reset|watch $A [r|w|rw]|watch off|diag|trace on|off|N|"
                       "REG=VAL...   (6502 -h for details)\n");
            flush(2); sys_exit(2);
        }
        wr(DBG_WPC, pc); wr(DBG_WAXYS, ax); wr(DBG_WPSH, ps);
        wr(DBG_COMMIT, 1);
        poll_halt();                                 /* commit fetch+decodes then halts */
        if (do_go) { wr(DBG_GO, 1); on = 0; os("6502 running\n"); flush(1); }
        else status();
        sys_exit(0);
    }
}
