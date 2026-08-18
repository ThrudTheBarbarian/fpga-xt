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
 *   6502 basic                  full power-cycle reset, BASIC on (media stays mounted)
 *   6502 nobasic                full power-cycle reset, BASIC off (OPTION held for you)
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
/* streaming per-instruction trace (fidelity core only): a 4096-entry HW ring that
 * STOPS THE WORLD (halts the 6502) when full and raises flush_req; the kernel drains
 * every entry then handshakes to resume — no instruction is ever lost. See the
 * 4-phase drain in stream_trace() below. */
#define DBG_STRM_CTRL  (DBG + 0x60)     /* W: [0]=strm_en (1=capture; rising edge resets ring) [1]=drain_done */
#define DBG_STRM_STAT  (DBG + 0x64)     /* R: [0]=flush_req (ring full + core halted; drain now) */
#define DBG_STRM_WPTR  (DBG + 0x68)     /* R: [12:0]=count of valid entries (4096 when full) */
#define DBG_STRM_RADDR (DBG + 0x6C)     /* W: [11:0]=ring read address */
#define DBG_STRM_RDLO  (DBG + 0x70)     /* R: entry[31:0]  = PC(0..15) | A<<16 | X<<24 */
#define DBG_STRM_RDHI  (DBG + 0x74)     /* R: entry[63:32] = Y | SP<<8 | P<<16 | IR<<24 */
#define CTRL_SALLYRST  (GP0 + 0x31Cul)
/* 6502 RAM peek through the ANTIC DMA BRAM port (no extra port, no CDC -- see
 * fpga_xt_top.sv).  OVL_BASE = {en, 15'b0, addr16}; while en=1 the DMA port
 * reads mem[addr] instead of ANTIC's fetch, so THE XL PLANE GLITCHES for the
 * duration and OVL_BASE must be cleared afterwards. */
#define OVL_BASE       (GP0 + 0x204ul)
#define OVL_DATA       (GP0 + 0x418ul)   /* [7:0] = byte, [31:16] = addr echo */

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

/* ---- wall clock (A9 global timer via SYS_gettimeofday, same as blitbench) ---- */
static long long now_us(void)
{
    unsigned tv[3];                                   /* {tv_sec lo, tv_sec hi, tv_usec} */
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
}

/* ============================================================================
 * streaming-trace capture buffer  (`6502 trace <secs>`)
 * ----------------------------------------------------------------------------
 * The program is freestanding (no libc -> no malloc), so the big buffer comes
 * from shm objects: each caps at 16 MB (SHM_MAXPG), so we chain up to 8 of them
 * = 128 MB, treated as ONE logical RING of 8-byte {lo,hi} entries.  When the
 * ring wraps we overwrite the OLDEST entry, so a long run always keeps the crash
 * TAIL; the dump walks oldest->newest.  Falls back to fewer chunks (down to one
 * 16 MB / ~2 M entries) if the pool can't give us all 8 — never fails outright.
 * ==========================================================================*/
#define CHUNK_BYTES  (16u << 20)                 /* 16 MB — the per-object shm ceiling */
#define CHUNK_ENTS   (CHUNK_BYTES / 8u)          /* 2 097 152 eight-byte entries / chunk */
#define MAX_CHUNKS   8                           /* 8 x 16 MB = 128 MB ring cap */

static unsigned      *g_chunk[MAX_CHUNKS];       /* mapped 16 MB shm segments */
static int            g_nchunks;
static unsigned long  g_capents;                 /* g_nchunks * CHUNK_ENTS */
static unsigned long  g_written;                 /* monotonic count of appended entries */

/* grab as many 16 MB shm chunks as the pool will give, up to MAX_CHUNKS */
static int cap_alloc(void)
{
    for (g_nchunks = 0; g_nchunks < MAX_CHUNKS; g_nchunks++) {
        int id = sys_shm_create(CHUNK_BYTES, 0);          /* 0 = classic pool-backed */
        if (id < 0) break;
        void *p = sys_shm_map(id);
        if (!p) break;
        g_chunk[g_nchunks] = (unsigned *)p;
    }
    g_capents = (unsigned long)g_nchunks * CHUNK_ENTS;
    return g_nchunks;
}

/* append one 8-byte entry to the ring (overwrites oldest once full) */
static void cap_put(unsigned lo, unsigned hi)
{
    unsigned long pos = g_written % g_capents;
    unsigned *e = g_chunk[pos / CHUNK_ENTS] + (pos % CHUNK_ENTS) * 2;
    e[0] = lo; e[1] = hi;
    g_written++;
}

/* drain the HW ring's current window into the capture buffer (steps b/c) */
static void cap_drain_window(void)
{
    unsigned long n = rd(DBG_STRM_WPTR) & 0x1FFFul;       /* 0..4096 valid entries */
    for (unsigned long i = 0; i < n; i++) {
        wr(DBG_STRM_RADDR, i);
        unsigned lo = (unsigned)rd(DBG_STRM_RDLO);
        unsigned hi = (unsigned)rd(DBG_STRM_RDHI);
        cap_put(lo, hi);
    }
}

/* dump the ring oldest->newest as raw LE 8-byte entries; returns entries written */
static unsigned long cap_dump(const char *path)
{
    unsigned long count = (g_written < g_capents) ? g_written : g_capents;
    unsigned long start = (g_written < g_capents) ? 0 : (g_written % g_capents);
    int fd = (int)sys_open(path, 0x0241 /* O_WRONLY|O_CREAT|O_TRUNC */);
    if (fd < 0) { on = 0; os("6502 trace: cannot open "); os(path); oc('\n'); flush(2); return 0; }
    /* write in <=256 KB spans; runs never cross a chunk boundary, and the ring
     * wrap coincides with a chunk boundary (g_capents is a multiple of CHUNK_ENTS),
     * so this walks contiguous physical memory in chronological order. */
    unsigned long done = 0;
    while (done < count) {
        unsigned long pos = (start + done) % g_capents;
        unsigned long ci  = pos / CHUNK_ENTS;
        unsigned long off = pos % CHUNK_ENTS;             /* entry index within chunk */
        unsigned long run = CHUNK_ENTS - off;             /* to chunk end */
        if (run > count - done) run = count - done;       /* to logical end */
        if (run > 32768) run = 32768;                     /* <=256 KB per write */
        sys_write(fd, g_chunk[ci] + off * 2, (unsigned)(run * 8));
        done += run;
    }
    sys_close(fd);
    return count;
}

/* wait for flush_req==want, bailing at the wall-clock deadline; returns 1 if the
 * bit reached `want`, 0 if the deadline hit first (only checked for want==1). */
static int wait_flush(int want, long long deadline)
{
    unsigned long spins = 0;
    for (;;) {
        int f = (int)(rd(DBG_STRM_STAT) & 1u);
        if (f == want) return 1;
        if (want && (++spins & 0x3FF) == 0 && now_us() >= deadline) return 0;
        if (!want && ++spins > 4000000ul) return 1;       /* handshake bail-out */
    }
}

/* `6502 trace <secs> [path]` — long-running streaming trace.  Selects the fidelity
 * core if it isn't already active (streaming only exists there), captures for <secs>
 * of wall-clock time draining every stop-the-world window, then dumps oldest->newest.
 * NOTE: draining is stop-the-world (the 6502 is frozen while we read each window over
 * the register port), so EMULATED game-time advances slower than wall-clock — pick
 * <secs> generously (the ring still keeps the crash tail whatever the rate). */
static void stream_trace(unsigned long secs, const char *path)
{
    if (!cap_alloc()) { on = 0; os("6502 trace: out of memory (shm)\n"); flush(2); sys_exit(1); }

    on = 0; os("6502 trace: "); odec((unsigned long)g_nchunks * 16); os(" MB ring (");
    odec(g_capents); os(" entries)\n"); flush(1);

    /* fidelity core only — cold-boot onto it if we're on turbo */
    if (!(rd(CTRL_SALLYRST) & 2ul)) {
        wr(CTRL_SALLYRST, 2ul | 1ul); wr(CTRL_SALLYRST, 2ul);
        on = 0; os("6502 trace: switched to fidelity core (cold-booted)\n"); flush(1);
    }

    long long deadline = now_us() + (long long)secs * 1000000ll;
    wr(DBG_STRM_CTRL, 1);                             /* strm_en=1: rising edge resets the ring */

    while (now_us() < deadline) {
        if (!wait_flush(1, deadline)) break;          /* (a) flush_req, or time up */
        cap_drain_window();                           /* (b)(c) drain all valid entries */
        wr(DBG_STRM_CTRL, 3);                         /* (d) drain_done=1 -> resume + reset ring */
        wait_flush(0, deadline);                      /* (e) flush_req clears */
        wr(DBG_STRM_CTRL, 1);                         /* (f) drain_done=0 -> ready for next */
    }

    wr(DBG_STRM_CTRL, 0);                             /* stop capturing */
    cap_drain_window();                               /* (4) drain the final partial window */

    unsigned long n = cap_dump(path);
    on = 0; os("6502 trace: wrote "); odec(n); os(" entries (");
    odec(n * 8); os(" bytes) to "); os(path); oc('\n'); flush(1);
}

/* `6502 dtrace <secs> [path]` — the CONTINUOUS trace.  Unlike `trace` above this
 * NEVER halts the core: the PL streams entries straight to a DDR ring
 * (hdl/xt_trace_axi.sv) and we only read the ring afterwards.  That is the whole
 * point — the stop-the-world drain in `trace` freezes the 6502 while the virtual
 * SIO drive keeps clocking bytes at it, so any title that is LOADING while you
 * watch it fails with LOAD ERROR and the trace you get describes the failure you
 * caused.  This one can watch a load.
 *
 * The ring is XT_SHM_CONTIG (the PL is a DMA engine with no MMU) and the kernel
 * resolves the id to a physical base itself — see SYS_trace_ring. */
#define DTR_CTRL   (DBG + 0x84ul)
#define DTR_WROTE  (DBG + 0x90ul)
#define DTR_DROPS  (DBG + 0x94ul)

static void ddr_trace(unsigned long secs, const char *path)
{
    /* plv is a BUDGET and the desktop's window surfaces are CONTIG too, so 64 MB
     * is often unavailable.  Take the largest ring we can get rather than
     * failing outright -- a shorter trace still answers the question, and the
     * size is REPORTED so nobody mistakes a small ring for a complete capture. */
    unsigned long want = 64ul << 20;
    int id = -1;
    while (want >= (4ul << 20)) {
        id = sys_shm_create((unsigned)want, XT_SHM_CONTIG);
        if (id >= 0) break;
        want >>= 1;
    }
    if (id < 0) { on = 0; os("6502 dtrace: no contiguous shm (plv budget)\n"); flush(2); sys_exit(1); }
    unsigned char *ring = (unsigned char *)sys_shm_map(id);
    if (!ring) { on = 0; os("6502 dtrace: map failed\n"); flush(2); sys_exit(1); }

    /* fidelity core only — the tap lives in xt6502f_debug */
    if (!(rd(CTRL_SALLYRST) & 2ul)) {
        wr(CTRL_SALLYRST, 2ul | 1ul); wr(CTRL_SALLYRST, 2ul);
        on = 0; os("6502 dtrace: switched to fidelity core (cold-booted)\n"); flush(1);
    }

    long rsz = sys_trace_ring(id, 1);
    if (rsz <= 0) { on = 0; os("6502 dtrace: arm failed\n"); flush(2); sys_exit(1); }
    on = 0; os("6502 dtrace: ring "); odec((unsigned long)rsz >> 20); os(" MB, capturing ");
    odec(secs); os("s (core NOT halted)\n"); flush(1);

    long long deadline = now_us() + (long long)secs * 1000000ll;
    while (now_us() < deadline) sys_nanosleep(50000);   /* 50 ms; the PL does the work */

    /* Read the counters BEFORE disarming.  They describe the capture, and a tool
     * that reads them afterwards is at the mercy of what the RTL does while
     * parked -- which is exactly how the first capture wrote an empty file. */
    unsigned long wrote = rd(DTR_WROTE);
    unsigned long drops = rd(DTR_DROPS);
    sys_trace_ring(id, 0);

    /* If the ring wrapped, the oldest surviving entry is at wrote % ring. Dump
     * oldest -> newest so the file reads chronologically either way. */
    unsigned long n     = (wrote < (unsigned long)rsz) ? wrote : (unsigned long)rsz;
    unsigned long start = (wrote < (unsigned long)rsz) ? 0ul : (wrote % (unsigned long)rsz);
    int fd = (int)sys_open(path, 0x0241 /* O_WRONLY|O_CREAT|O_TRUNC */);
    if (fd < 0) { on = 0; os("6502 dtrace: cannot open output\n"); flush(2); sys_exit(1); }
    if (start + n <= (unsigned long)rsz) {
        sys_write(fd, ring + start, n);
    } else {                                          /* wrapped: tail then head */
        unsigned long first = (unsigned long)rsz - start;
        sys_write(fd, ring + start, first);
        sys_write(fd, ring, n - first);
    }
    sys_close(fd);

    on = 0; os("6502 dtrace: "); odec(n); os(" bytes ("); odec(n / 8);
    os(" entries) to "); os(path); os("  DROPS="); odec(drops);
    os(drops ? "  *** TRACE HAS GAPS ***\n" : "  (complete)\n");
    flush(1);
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
    line("  6502 reset              pulse SALLYRST (raw debugger reset; CONSOL untouched)");
    line("  6502 basic              power-cycle reset, BASIC enabled (media stays mounted)");
    line("  6502 nobasic            power-cycle reset, BASIC disabled (OPTION held across coldstart)");
    line("  6502 run [--turbo] [--hold] <file.xex>   cold-boot + run a standalone .xex (as xexload)");
    line("  6502 break $A           break before executing the instruction at $A");
    line("  6502 break off");
    line("  6502 breakreset on|off  break at the reset vector");
    line("  6502 watch $A [r|w|rw]  data watchpoint (default rw)");
    line("  6502 watch off");
    line("  6502 trace on|off       legacy trace ring: enable/disable");
    line("  6502 trace dump [N]     dump the last N ring entries oldest->newest (default 32)");
    line("  6502 trace <secs> [path]  stream a stop-the-world per-instruction trace to a file");
    line("                          (fidelity core; up to 128 MB ring keeps the crash tail; default /6502trace.bin)");
    line("  6502 dump $A [N]        hex-dump N bytes of GUEST memory (default 256)");
    line("                          (peeks via ANTIC's DMA port: the picture glitches while it runs)");
    line("  6502 diag               debug-block self-observability");
    line("  6502 PC=$A A=.. X=.. Y=.. SP=.. P=.. [go]   inject registers");
    line("");
    line("cores:  fid   = xt6502f real 1x, all 256 opcodes cycle-exact + interrupts (default)");
    line("        turbo = xt6502  ~56x, documented ISA + xtc accel (opt-in)");
    line("note:   halt/step/break/watch/trace/diag/commit follow the ACTIVE core (cpu_sel);");
    line("        both cores have full in-fabric debug + register inject.");
}

void _app_entry(int argc, char **argv)
{
    if (argc < 2) { status(); sys_exit(0); }
    const char *cmd = argv[1];
    if (streq(cmd, "dtrace")) {
        unsigned long secs = (argc >= 3) ? parse_num(argv[2]) : 20ul;
        const char *path = (argc >= 4) ? argv[3] : "/6502trace.bin";
        if (!secs) { on = 0; os("usage: 6502 dtrace <secs> [path]\n"); flush(2); sys_exit(2); }
        ddr_trace(secs, path);
        sys_exit(0);
    }

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

    /* full power-cycle reset with explicit BASIC state (SYS_xl_reset): fresh OS
     * image + RAM scrub via the reset stub, mounted media KEPT (a mounted disk
     * reboots).  `nobasic` holds OPTION across the coldstart; the kernel releases
     * it automatically once the XL OS has sampled it. */
    if (streq(cmd, "basic") || streq(cmd, "nobasic")) {
        int basic = streq(cmd, "basic");
        long rc = sys_xl_reset(basic);
        on = 0;
        if (rc == 0) {
            os("6502 cold reset, BASIC ");
            os(basic ? "on\n" : "off (OPTION held across coldstart)\n");
        } else os("6502 reset failed\n");
        flush(rc == 0 ? 1 : 2);
        sys_exit(rc == 0 ? 0 : 1);
    }

    if (streq(cmd, "reset")) {
        /* Preserve EVERYTHING except the reset strobe (bit 0) — the mask used
         * to be `& 2ul`, which kept the core select but silently dropped bit 2,
         * the ANTIC timing-machine AUTHORITY bit.  Any `6502 reset` therefore
         * moved the realm back onto the legacy ANTIC without saying so, and
         * ACID800 sweeps that reset between tests measured the wrong hardware.
         * xl_boot.c has always used `& ~1u`; match it. */
        unsigned long sel = rd(CTRL_SALLYRST) & ~1ul;
        wr(CTRL_SALLYRST, sel | 1ul); wr(CTRL_SALLYRST, sel);
        if (rd(DBG_CFG) & 2u) poll_halt();       /* halt_at_reset armed -> wait */
        status(); sys_exit(0);
    }

    if (streq(cmd, "run")) {                     /* cold-boot + run a standalone .xex */
        int flags = 0, ai = 2;                   /* bit0 = turbo, bit1 = hold (as xexload) */
        for (; ai < argc; ai++) {
            if (streq(argv[ai], "--turbo") || streq(argv[ai], "-t"))     flags |= 1;
            else if (streq(argv[ai], "--hold") || streq(argv[ai], "-h")) flags |= 2;
            else break;
        }
        if (ai >= argc) { on = 0; os("usage: 6502 run [--turbo] [--hold] <file.xex>\n"); flush(2); sys_exit(2); }
        long rc = sys_xexload(argv[ai], flags);
        if (rc != 0) { on = 0; os("6502 run: failed\n"); flush(2); sys_exit(1); }
        sys_exit(0);
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
        /* streaming trace: a bare NUMBER means SECONDS of stop-the-world capture to a
         * file (catches a crash 20-60s in).  The legacy "dump the last N ring entries"
         * form now lives under 'trace dump [N]'. */
        if (argc >= 3 && !streq(argv[2], "dump")) {
            unsigned long secs = parse_num(argv[2]);
            const char *path = (argc >= 4) ? argv[3] : "/6502trace.bin";   /* SD root (has room) */
            if (!secs) { on = 0; os("usage: 6502 trace <secs> [path]\n"); flush(2); sys_exit(2); }
            stream_trace(secs, path);
            sys_exit(0);
        }
        /* dump the last N (default 32) instructions, oldest->newest */
        int have_n = (argc >= 4);                    /* 'trace dump [N]' */
        unsigned long n = have_n ? parse_num(argv[3]) : 32;
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

    /* 6502 dump $ADDR [N] -- bulk read of GUEST memory.
     *
     * The one-byte-at-a-time `mem 43C00204 8000xxxx; mem 43C00418` recipe is
     * fine for a couple of bytes and useless for a couple of hundred: every
     * byte costs an ssh round trip and a process spawn.  Comparing CONTENT
     * against a reference emulator -- a player/missile table, a screen bitmap --
     * needs hundreds of bytes at once, so the loop belongs here.
     *
     * The peek hijacks ANTIC's DMA port, so the picture glitches while this
     * runs and OVL_BASE is ALWAYS cleared before returning, on every path. */
    if (streq(cmd, "dump")) {
        if (argc < 3) { on = 0; os("usage: 6502 dump $ADDR [N]\n"); flush(2); sys_exit(2); }
        unsigned long a0 = parse_num(argv[2]) & 0xFFFF;
        unsigned long n  = (argc >= 4) ? parse_num(argv[3]) : 256;
        if (!n) n = 1;
        if (n > 0x10000) n = 0x10000;
        on = 0;
        for (unsigned long i = 0; i < n; i++) {
            unsigned long a = (a0 + i) & 0xFFFF;
            if ((i & 15) == 0) { ohex(a, 4); os(": "); }
            wr(OVL_BASE, 0x80000000ul | a);
            unsigned long d = rd(OVL_DATA);
            ohex(d & 0xFF, 2);
            /* Flush EVERY line: the output buffer is small, and a 256-byte dump
             * silently lost everything past ~57 bytes before this. */
            if ((i & 15) == 15) { oc('\n'); flush(1); } else oc(' ');
        }
        if (n & 15) { oc('\n'); flush(1); }
        wr(OVL_BASE, 0);                 /* release the DMA port */
        flush(1);
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
                       "breakreset on|off|reset|basic|nobasic|watch $A [r|w|rw]|watch off|dump $A [N]|diag|"
                       "trace on|off|dump [N]|<secs> [path]|"
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
