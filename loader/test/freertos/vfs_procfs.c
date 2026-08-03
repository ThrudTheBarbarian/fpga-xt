/* vfs_procfs.c — the process table as files, mounted /OS/proc.
 *
 * Layout (a Linux-shaped subset — enough for toybox ps/top/killall, whose
 * /proc literals are patched to /OS/proc):
 *   /OS/proc/<pid>/stat      the do_task_stat line (real pid/comm/state,
 *                            plausible zeros for the accounting fields)
 *   /OS/proc/<pid>/status    Name/State/Pid/Uid/Gid, tab-separated
 *   /OS/proc/<pid>/cmdline   argv, NUL-joined
 *   /OS/proc/uptime          monotonic seconds since boot (global timer)
 *   /OS/proc/meminfo         static totals (tools want it to exist)
 *   /OS/proc/limits          fixed-size kernel pools: cur/max/high-water
 *   /OS/proc/cpu1            the second A9 (AMP): live ping + benchmark
 *   /OS/proc/cpuinfo         both A9s, Linux-shaped stanzas
 *
 * Content is generated at OPEN into an allocated buffer (a moment-in-time
 * snapshot; the fd then reads in-memory via vf.data), freed at close. Opens
 * run in the fs task; the generators only read the kernel proc table.
 */
#include "vfs.h"
#include "frtos_os.h"
#include "cpu1.h"
#include <stdint.h>
#include <string.h>

extern void *frtos_alloc(size_t, size_t, void *);
extern void  frtos_free(void *, void *);
extern int   _gettimeofday(void *tv, void *tz);

#define PF_MAXPROC 64      /* must match MAXPROC (frtos_os.c); frtos_proc_snap
                            * bounds-checks the index, so over-iterating is safe */
#define PF_BUF     768
#define PF_NETBUF  4096    /* /net/* connection tables can be long */

extern const char *const xt_procnet_leaves[];   /* NULL-terminated leaf names under /net */

/* ---- path parsing: "/<pid>/leaf", "/<pid>", "/uptime", ... ---------------- */
static int pf_num(const char *s, int *out)
{
    int v = 0, n = 0;
    while (s[n] >= '0' && s[n] <= '9') { v = v * 10 + (s[n] - '0'); n++; }
    if (!n) return -1;
    *out = v;
    return n;
}

/* find the table slot holding `pid`; fills the snapshot. -1 if not running */
static int pf_slot(int pid, char *comm, int commsz, char *cmdl, int cmdsz,
                   int *cmdlen, int *state)
{
    for (int i = 0; i < PF_MAXPROC; i++)
        if (frtos_proc_snap(i, comm, commsz, cmdl, cmdsz, cmdlen, state) == pid)
            return i;
    return -1;
}

/* ---- tiny append-formatter (the kernel is -nostdlib: no snprintf) --------- */
typedef struct { char *b; int n, cap; } pfb;
static void pfb_s(pfb *o, const char *s)
{ while (*s && o->n < o->cap - 1) o->b[o->n++] = *s++; o->b[o->n] = 0; }
static void pfb_c(pfb *o, char c)
{ if (o->n < o->cap - 1) { o->b[o->n++] = c; o->b[o->n] = 0; } }
static void pfb_d(pfb *o, int v)
{
    char t[12]; int k = 0;
    unsigned u = v < 0 ? (pfb_c(o, '-'), (unsigned)(-v)) : (unsigned)v;
    do { t[k++] = (char)('0' + u % 10); u /= 10; } while (u);
    while (k) pfb_c(o, t[--k]);
}

static void pfb_x8(pfb *o, uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    pfb_s(o, "0x");
    for (int i = 28; i >= 0; i -= 4) pfb_c(o, h[(v >> i) & 0xf]);
}

/* ---- content generators (into buf, returns length) ------------------------ */
static int pf_gen_stat(int pid, char *buf, int sz)
{
    char comm[32], cmdl[8];
    int st = 'S';
    if (pf_slot(pid, comm, sizeof comm, cmdl, sizeof cmdl, 0, &st) < 0) return -1;
    /* fields per proc(5)/do_task_stat; the accounting ones are honest zeros */
    pfb o = { buf, 0, sz };
    pfb_d(&o, pid); pfb_s(&o, " ("); pfb_s(&o, comm); pfb_s(&o, ") ");
    pfb_c(&o, (char)st);
    pfb_s(&o, " 1 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 0 20 0 1 0 0 "
              "4194304 128 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    return o.n;
}

static int pf_gen_status(int pid, char *buf, int sz)
{
    char comm[32], cmdl[8];
    int st = 'S';
    if (pf_slot(pid, comm, sizeof comm, cmdl, sizeof cmdl, 0, &st) < 0) return -1;
    pfb o = { buf, 0, sz };
    pfb_s(&o, "Name:\t"); pfb_s(&o, comm);
    pfb_s(&o, "\nState:\t"); pfb_c(&o, (char)st);
    pfb_s(&o, "\nPid:\t"); pfb_d(&o, pid);
    pfb_s(&o, "\nPPid:\t1\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\nVmRSS:\t128 kB\n");
    return o.n;
}

static int pf_gen_cmdline(int pid, char *buf, int sz)
{
    char comm[32];
    int len = 0, st;
    if (pf_slot(pid, comm, sizeof comm, buf, sz, &len, &st) < 0) return -1;
    return len;
}

static int pf_gen_comm(int pid, char *buf, int sz)
{
    char comm[32], cmdl[8];
    int st;
    if (pf_slot(pid, comm, sizeof comm, cmdl, sizeof cmdl, 0, &st) < 0) return -1;
    pfb o = { buf, 0, sz };
    pfb_s(&o, comm); pfb_c(&o, '\n');
    return o.n;
}

static int pf_gen_uptime(char *buf, int sz)
{
    /* MONOTONIC since boot — the raw global timer WITHOUT xt_wallclock_off(), so
     * SNTP setting the wall clock (gettimeofday jumping to real epoch) doesn't move
     * uptime. Linux /proc/uptime format: "<uptime> <idle>", both in seconds to 2dp.
     * We don't meter idle time; report it equal to uptime (a mostly-idle dev board)
     * — field 1 is the one every tool reads. */
    extern void gtimer_timeofday(uint32_t *, uint32_t *);
    uint32_t sec = 0, usec = 0;
    gtimer_timeofday(&sec, &usec);
    int cs = (int)(usec / 10000);
    pfb o = { buf, 0, sz };
    for (int i = 0; i < 2; i++) {
        pfb_d(&o, (int)sec); pfb_c(&o, '.');
        pfb_c(&o, (char)('0' + cs / 10)); pfb_c(&o, (char)('0' + cs % 10));
        pfb_c(&o, i ? '\n' : ' ');
    }
    return o.n;
}

/* /OS/proc/video — the display-pipeline health word (PL DIAG0 over GP0) + the
 * SiI9022's live registers.  DIAG0: [0]=mmcm1 lock (clk_sally/clk_sys),
 * [1]=mmcm2 lock (clk_pix), [2]=hdmi cfg done, [15:8]=clk_pix-alive counter,
 * [23:16]=mmcm2 UNLOCK EVENT count (falling lock edges — climbing = the pixel
 * clock is dropping out), [31:24]=vbeam frame counter.  Sampled twice ~50 ms
 * apart so the counters show motion in one cat. */
static int pf_gen_video(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
#ifdef XT_HW
    extern int hdmi_sii_read(int);
    volatile uint32_t *diag = (volatile uint32_t *)0x43C00400u;   /* XT_BLK_DIAG */
    uint32_t a = *diag;
    struct { long long sec, usec; } t0, t1;          /* time_t is 64-bit here — must not undersize */
    _gettimeofday(&t0, 0);
    do { _gettimeofday(&t1, 0); }
    while ((t1.sec - t0.sec) * 1000000 + (t1.usec - t0.usec) < 50000);
    uint32_t b = *diag;
    pfb_s(&o, "mmcm1_lock:    "); pfb_d(&o, (int)(b & 1)); pfb_c(&o, '\n');
    pfb_s(&o, "mmcm2_lock:    "); pfb_d(&o, (int)((b >> 1) & 1)); pfb_s(&o, "  (clk_pix)\n");
    pfb_s(&o, "hdmi_cfg:      "); pfb_d(&o, (int)((b >> 2) & 1)); pfb_s(&o, "  (dead bit: PL configurator retired, ties 0)\n");
    pfb_s(&o, "mmcm2_unlocks: "); pfb_d(&o, (int)((b >> 16) & 0xFF)); pfb_c(&o, '\n');
    pfb_s(&o, "pix_alive:     "); pfb_d(&o, (int)((a >> 8) & 0xFF));
    pfb_s(&o, " -> ");            pfb_d(&o, (int)((b >> 8) & 0xFF)); pfb_s(&o, "  (50ms)\n");
    pfb_s(&o, "frames:        "); pfb_d(&o, (int)((a >> 24) & 0xFF));
    pfb_s(&o, " -> ");            pfb_d(&o, (int)((b >> 24) & 0xFF)); pfb_s(&o, "  (50ms, ~+3)\n");
    pfb_s(&o, "(SiI9022 regs moved to /OS/proc/video-sii — I2C reads are a\n"
              " blank-trigger suspect and must not ride along with the PL diag)\n");
#else
    pfb_s(&o, "no video pipeline on qemu\n");
#endif
    return o.n;
}

/* /OS/proc/video-sii — the transmitter's registers, SEPARATE from the PL diag:
 * reading the SiI over I2C is itself a suspect for triggering the 2 s monitor
 * re-acquire, so it must be possible to read one without the other. */
static int pf_gen_video_sii(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
#ifdef XT_HW
    extern int hdmi_sii_read(int);
    pfb_s(&o, "sii[0x1A]:     "); pfb_d(&o, hdmi_sii_read(0x1A)); pfb_s(&o, "  (want 1: HDMI out, TMDS on)\n");
    pfb_s(&o, "sii[0x3D]:     "); pfb_d(&o, hdmi_sii_read(0x3D)); pfb_s(&o, "  (irq/hotplug status)\n");
#else
    pfb_s(&o, "no SiI9022 on qemu\n");
#endif
    return o.n;
}

/* /OS/proc/video-kick — reading it re-runs the SiI9022 output enable: if the
 * picture comes back, the transmitter had dropped its config; if not, look at
 * /OS/proc/video's mmcm/frame counters (the PL side). */
static int pf_gen_video_kick(char *buf, int sz)
{
    extern void hdmi_reinit(void);
    hdmi_reinit();
    pfb o = { buf, 0, sz };
    pfb_s(&o, "SiI9022 output re-enabled\n");
    return o.n;
}

/* /OS/proc/video-sleep — toggle the clk_pix BUFGCE gate (gp0_ctrl[5]).  Reading
 * it flips display power: awake → gate clk_pix off (the whole pixel domain +
 * DDR scan-out idles; screen dark); asleep → clk_pix back on + SiI re-acquire.
 * MMCM #2 stays locked throughout, so wake is clean. */
static int pf_gen_video_sleep(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
#ifdef XT_HW
    volatile uint32_t *ctrl = (volatile uint32_t *)0x43C00300u;   /* GP0 CTRL_GP0 */
    if (*ctrl & 0x20u) {                              /* asleep -> wake */
        *ctrl &= ~0x20u; __asm__ volatile("dsb");
        extern void hdmi_reinit(void);
        hdmi_reinit();                                /* clk_pix back -> SiI re-acquire */
        pfb_s(&o, "clk_pix running — display awake (SiI re-enabled)\n");
    } else {                                          /* awake -> sleep */
        *ctrl |= 0x20u; __asm__ volatile("dsb");
        pfb_s(&o, "clk_pix gated — display asleep (pixel domain + scan-out idle)\n");
    }
#else
    pfb_s(&o, "no video plane on qemu\n");
#endif
    return o.n;
}

static int pf_gen_meminfo(char *buf, int sz)
{
    /* the DDR arena truth: pool pages handed out vs available (heap grows up,
     * page frontier grows down — free includes the unclaimed gap between) */
    extern uint32_t vm_pages_free(void), vm_pages_inuse(void);
    uint32_t freek  = vm_pages_free()  * 4u;
    uint32_t usedk  = vm_pages_inuse() * 4u;
    pfb o = { buf, 0, sz };
    pfb_s(&o, "MemTotal:       "); pfb_d(&o, (int)(freek + usedk)); pfb_s(&o, " kB\n");
    pfb_s(&o, "MemFree:        "); pfb_d(&o, (int)freek); pfb_s(&o, " kB\n");
    pfb_s(&o, "MemAvailable:   "); pfb_d(&o, (int)freek); pfb_s(&o, " kB\n");
    pfb_s(&o, "Buffers:             0 kB\nCached:              0 kB\n"
              "SwapTotal:           0 kB\nSwapFree:            0 kB\n");
    return o.n;
}

/* print milli-degrees C as "[-]DD.DDD" */
static void pfb_milliC(pfb *o, int m)
{
    if (m < 0) { pfb_c(o, '-'); m = -m; }
    pfb_d(o, m / 1000); pfb_c(o, '.');
    int f = m % 1000;
    pfb_c(o, (char)('0' + f / 100));
    pfb_c(o, (char)('0' + (f / 10) % 10));
    pfb_c(o, (char)('0' + f % 10));
}
/* pad with spaces until the field started at `start_n` fills `w` columns */
static void pfb_pad(pfb *o, int start_n, int w) { while (o->n - start_n < w) pfb_c(o, ' '); }
static void pfb_2d(pfb *o, int v) { pfb_c(o, (char)('0' + (v / 10) % 10)); pfb_c(o, (char)('0' + v % 10)); }
/* monotonic seconds -> "[Nd ]HH:MM:SS" */
static void pfb_uptime_hms(pfb *o, uint32_t sec)
{
    uint32_t d = sec / 86400; sec %= 86400;
    uint32_t h = sec / 3600;  sec %= 3600;
    uint32_t m = sec / 60,    s = sec % 60;
    if (d) { pfb_d(o, (int)d); pfb_s(o, "d "); }
    pfb_2d(o, (int)h); pfb_c(o, ':'); pfb_2d(o, (int)m); pfb_c(o, ':'); pfb_2d(o, (int)s);
}
/* Unix epoch (s) -> "YYYY-MM-DD HH:MM:SS UTC".  Self-contained civil-from-days
 * (Hinnant) so we need no libc time/tz support, which this minimal libc lacks. */
static void pfb_datetime(pfb *o, long long epoch)
{
    long long days = epoch / 86400;
    int tod = (int)(epoch % 86400);
    long long z = days + 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);                       /* [0, 146096] */
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; /* [0, 399] */
    long long y = (long long)yoe + era * 400;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);            /* [0, 365] */
    unsigned mp = (5 * doy + 2) / 153;                                 /* [0, 11] */
    unsigned d = doy - (153 * mp + 2) / 5 + 1;                         /* [1, 31] */
    unsigned m = mp < 10 ? mp + 3 : mp - 9;                            /* [1, 12] */
    y += (m <= 2);
    pfb_d(o, (int)y); pfb_c(o, '-'); pfb_2d(o, (int)m); pfb_c(o, '-'); pfb_2d(o, (int)d);
    pfb_c(o, ' '); pfb_2d(o, tod / 3600); pfb_c(o, ':');
    pfb_2d(o, (tod / 60) % 60); pfb_c(o, ':'); pfb_2d(o, tod % 60); pfb_s(o, " UTC");
}

#ifdef XT_HW
/* Zynq PS XADC die temperature via the devcfg XADCIF FIFO (UG585 B.16 / UG480).
 * ps7_init leaves the interface disabled and the XADC in reset, so enable it once
 * (release reset, turn on the arbiter with full FIFO thresholds); the XADC's
 * default mode then samples temp + supplies into the DRP status regs.  DRP 0x00
 * = temperature; T(C) = code*503.975/65536 - 273.15. */
#define XADC_CFG    (*(volatile uint32_t *)0xF8007100u)
#define XADC_CMDF   (*(volatile uint32_t *)0xF8007110u)
#define XADC_RDF    (*(volatile uint32_t *)0xF8007114u)
#define XADC_MCTL   (*(volatile uint32_t *)0xF8007118u)
/* Read one DRP register: 3 commands (READ, READ, NOOP), pop 3 — never an empty
 * FIFO (which SLVERRs).  Read twice to settle the SPI-like pipeline. */
static unsigned xadc_rd(unsigned addr)
{
    unsigned c = (1u << 26) | ((addr & 0x3FFu) << 16);
    XADC_CMDF = c; XADC_CMDF = c; XADC_CMDF = 0u;
    for (volatile int i = 0; i < 20000; i++) { }
    (void)XADC_RDF; (void)XADC_RDF;
    return XADC_RDF & 0xFFFFu;
}
/* Write one DRP register: WRITE + NOOP = 2 commands, pop 2 (balanced). */
static void xadc_wr(unsigned addr, unsigned data)
{
    XADC_CMDF = (2u << 26) | ((addr & 0x3FFu) << 16) | (data & 0xFFFFu);
    XADC_CMDF = 0u;
    for (volatile int i = 0; i < 20000; i++) { }
    (void)XADC_RDF; (void)XADC_RDF;
}
static void xadc_init_once(void)
{
    static int done = 0;
    if (done) return;
    done = 1;
    XADC_MCTL = 0x00000000u;                               /* release reset */
    /* ENABLE | CFIFOTH=F | DFIFOTH=F | WEDGE | REDGE | TCKRATE=11 (DCLK=PCLK/16,
     * not the /2 floor which is far too fast for the DRP) | IGAP=0x14.  A wrong
     * interface clock/edge/gap latches every DRP read one bit off. */
    XADC_CFG  = 0x80000000u | (0xFu << 20) | (0xFu << 16)
              | (1u << 13) | (1u << 12) | (3u << 8) | 0x14u;
    for (volatile int i = 0; i < 100000; i++) { }
    xadc_wr(0x42, 0x0400u);        /* CFR2: ADCCLK = DCLK / 4 (reset floor was 0) */
    for (volatile int i = 0; i < 800000; i++) { }          /* settle + conversions */
}
int xadc_temp_milliC(void)                             /* called by the temp-monitor task */
{
    xadc_init_once();
    unsigned code = xadc_rd(0x00);                     /* DRP 0x00 = on-chip temperature */
    if (!code) return -1000000;                        /* 0 = not sampling */
    return (int)(((int64_t)code * 503975) / 65536) - 273150;   /* T = code*503.975/65536 - 273.15 */
}
#endif

/* Peak-hold temperatures in milli-C, sampled by the temp-monitor task (main.c)
 * so excursions are caught even when nobody is watching /OS/proc/temp.
 * -1000000 = no sample yet.  Plain ints: aligned 32-bit r/w is atomic on the A9,
 * and a momentary skew between a value and its peak is harmless here. */
int g_temp_brd = -1000000, g_temp_brd_peak = -1000000;   /* I2C 0x49 (board) */
int g_temp_die = -1000000, g_temp_die_peak = -1000000;   /* PS XADC (die)   */

/* /OS/proc/temp — board (I2C 0x49) + die (PS XADC) temps with a boot timestamp,
 * so a `while : ; do cat /OS/proc/temp; sleep 1; done` log lines up with HDMI
 * drops.  Columns aligned: labels to the ':' , values to the '('. */
/* /OS/proc/cpuinfo — both A9s, in the shape Linux uses (one stanza per
 * processor, blank-line separated) but with the fields that are actually true
 * here.  MIDR/SCTLR/ACTLR for CPU1 are values CPU1 read of ITSELF and published
 * through the mailbox, not values CPU0 assumed on its behalf — the distinction
 * matters, because "we set the MMU bit" and "the MMU is on" were not the same
 * thing more than once during bring-up. */
static void pf_cpu_stanza(pfb *o, int n, uint32_t midr, uint32_t sctlr,
                          uint32_t actlr, uint32_t mpidr, const char *state)
{
    pfb_s(o, "processor\t: "); pfb_d(o, n); pfb_c(o, '\n');
    pfb_s(o, "model name\t: ARMv7 Processor (Cortex-A9)\n");
    /* Read from the ARM PLL, NOT from configCPU_CLOCK_HZ. The constant is what
     * we ASKED for; this is what the silicon is doing. They diverged during the
     * 666 -> 766 MHz change and a divergence silently mis-scales gettimeofday
     * and the scheduler tick, so print both and let the mismatch be visible. */
    {
        extern uint32_t cpu_hz_actual(void);
        extern uint32_t cpu_hz_configured(void);
        uint32_t hz = cpu_hz_actual(), want = cpu_hz_configured();
        pfb_s(o, "cpu MHz\t\t: "); pfb_d(o, (int)(hz / 1000000u));
        pfb_c(o, '.'); {
            unsigned frac = (hz % 1000000u) / 10000u;     /* two places */
            pfb_c(o, (char)('0' + frac / 10)); pfb_c(o, (char)('0' + frac % 10));
        }
        if (hz / 1000000u != want / 1000000u) {
            pfb_s(o, "  (MISMATCH: configCPU_CLOCK_HZ says ");
            pfb_d(o, (int)(want / 1000000u)); pfb_s(o, " MHz)");
        }
        pfb_c(o, '\n');
    }
    pfb_s(o, "CPU implementer\t: 0x"); {
        static const char h[] = "0123456789abcdef";
        pfb_c(o, h[(midr >> 28) & 0xf]); pfb_c(o, h[(midr >> 24) & 0xf]); }
    pfb_c(o, '\n');
    pfb_s(o, "CPU architecture: 7\n");
    pfb_s(o, "CPU variant\t: 0x"); pfb_d(o, (int)((midr >> 20) & 0xf)); pfb_c(o, '\n');
    pfb_s(o, "CPU part\t: 0x"); {
        static const char h[] = "0123456789abcdef";
        pfb_c(o, h[(midr >> 12) & 0xf]); pfb_c(o, h[(midr >> 8) & 0xf]);
        pfb_c(o, h[(midr >> 4) & 0xf]); }
    pfb_c(o, '\n');
    pfb_s(o, "CPU revision\t: "); pfb_d(o, (int)(midr & 0xf)); pfb_c(o, '\n');
    pfb_s(o, "MPIDR\t\t: "); pfb_x8(o, mpidr); pfb_c(o, '\n');
    pfb_s(o, "SCTLR\t\t: "); pfb_x8(o, sctlr);
    pfb_s(o, "  mmu="); pfb_s(o, (sctlr & 1u) ? "on" : "OFF");
    pfb_s(o, " dcache="); pfb_s(o, (sctlr & (1u << 2)) ? "on" : "OFF");
    pfb_s(o, " icache="); pfb_s(o, (sctlr & (1u << 12)) ? "on" : "OFF");
    pfb_s(o, " bpred="); pfb_s(o, (sctlr & (1u << 11)) ? "on" : "OFF");
    pfb_c(o, '\n');
    pfb_s(o, "ACTLR\t\t: "); pfb_x8(o, actlr);
    pfb_s(o, "  smp="); pfb_s(o, (actlr & (1u << 6)) ? "on" : "OFF");
    pfb_c(o, '\n');
    pfb_s(o, "state\t\t: "); pfb_s(o, state); pfb_c(o, '\n');
}

static int pf_gen_cpuinfo(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
    cpu1_mbox *m = cpu1_box();
    uint32_t midr, sctlr;
    __asm__ volatile("mrc p15, 0, %0, c0, c0, 0" : "=r"(midr));
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));

    pf_cpu_stanza(&o, 0, midr, sctlr, cpu1_actlr(), 0x80000000u, "running (kernel)");
    pfb_c(&o, '\n');

    if (cpu1_alive()) {
        pf_cpu_stanza(&o, 1, m->midr, m->sctlr, m->actlr, m->mpidr, "running (AMP)");
        pfb_s(&o, "beats\t\t: "); pfb_d(&o, (int)m->heartbeat);
        pfb_s(&o, " +"); pfb_d(&o, (int)cpu1_heartbeat_delta(2000)); pfb_c(&o, '\n');
    } else {
        pfb_s(&o, "processor\t: 1\nstate\t\t: down (see /OS/proc/cpu1)\n");
    }
    pfb_c(&o, '\n');
    pfb_s(&o, "SCU\t\t: "); pfb_x8(&o, cpu1_scu_ctrl());
    pfb_s(&o, "  enabled="); pfb_s(&o, (cpu1_scu_ctrl() & 1u) ? "yes" : "no");
    pfb_c(&o, '\n');
    return o.n;
}

/* The second A9 (see cpu1.h).  Reading this file does not just print counters:
 * it PINGS CPU1 and BENCHMARKS it live, so a core that died five minutes ago
 * cannot masquerade as a running one behind a stale heartbeat.  The ping's
 * answer is one CPU0 never computed, and the benchmark is the same integer loop
 * progs/memprobe.c runs on CPU0 — so the two ns/iter figures are directly
 * comparable, which is the number the software-6502 investigation needs. */
static int pf_gen_cpu1(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
    cpu1_mbox *m = cpu1_box();
    uint32_t arg[4] = { 0, 0, 0, 0 }, res[4] = { 0, 0, 0, 0 };
    int p;

    /* If CPU1 is not up, RETRY the release on this read.  A core that missed
     * its wake at boot should not need a reboot to recover — and while this is
     * being brought up it means an experiment costs an ssh round-trip instead
     * of a bitstream load. */
    int retried = 0;
    if (!cpu1_alive()) { cpu1_retry(); retried = 1; }

    pfb_s(&o, "state   : "); p = o.n;
    pfb_s(&o, cpu1_alive() ? (retried ? "up (released by this read)" : "up") : "down");
    pfb_pad(&o, p, 28); pfb_s(&o, "(second Cortex-A9, AMP)\n");

    pfb_s(&o, "scu     : "); p = o.n;
    pfb_s(&o, "ctrl "); pfb_x8(&o, cpu1_scu_ctrl());
    pfb_s(&o, " actlr "); pfb_x8(&o, cpu1_actlr());
    pfb_pad(&o, p, 28); pfb_s(&o, "(SCU bit0 = on, ACTLR bit6 = SMP)\n");

    { uint32_t d[5]; cpu1_debug(d);
      pfb_s(&o, "release : "); p = o.n;
      pfb_s(&o, "pen armed "); pfb_x8(&o, d[0]);
      pfb_s(&o, " -> final "); pfb_x8(&o, d[1]);
      pfb_pad(&o, p, 28); pfb_s(&o, "(sentinel here = BootROM rearmed it)\n");
      pfb_s(&o, "rstctrl : "); p = o.n;
      pfb_x8(&o, d[2]); pfb_s(&o, " held "); pfb_x8(&o, d[3]);
      pfb_s(&o, " -> "); pfb_x8(&o, d[4]);
      pfb_pad(&o, p, 28); pfb_s(&o, "(A9_CPU_RST_CTRL; held must show bits 1+5)\n"); }

    /* Everything below is reported even when CPU0 declared CPU1 down — a core
     * that woke late, or woke and then faulted, leaves its evidence in the
     * mailbox, and hiding it behind the `up` flag is exactly how a late boot
     * gets misread as a dead one. */
    pfb_s(&o, "magic   : "); p = o.n; pfb_x8(&o, m->magic);
    pfb_pad(&o, p, 28);
    pfb_s(&o, m->magic == (uint32_t)CPU1_MAGIC ? "(CPU1 reached cpu1_main)\n"
                                               : "(never reached cpu1_main)\n");

    pfb_s(&o, "mpidr   : "); p = o.n; pfb_x8(&o, m->mpidr);
    pfb_pad(&o, p, 28); pfb_s(&o, "(affinity 1 = really CPU1)\n");

    pfb_s(&o, "beats   : "); p = o.n; pfb_d(&o, (int)m->heartbeat);
    pfb_s(&o, " +"); pfb_d(&o, (int)cpu1_heartbeat_delta(2000));
    pfb_pad(&o, p, 28); pfb_s(&o, "(idle counter, and its 2 ms delta)\n");

    pfb_s(&o, "fault   : "); p = o.n;
    if (!m->fault_kind) pfb_s(&o, "none");
    else { pfb_s(&o, "kind "); pfb_d(&o, (int)m->fault_kind);
           pfb_s(&o, " pc "); pfb_x8(&o, m->fault_pc);
           pfb_s(&o, " spsr "); pfb_x8(&o, m->fault_spsr);
           pfb_s(&o, " dfsr "); pfb_x8(&o, m->fault_dfsr);
           pfb_s(&o, " dfar "); pfb_x8(&o, m->fault_dfar); }
    pfb_pad(&o, p, 28); pfb_s(&o, "(first fault only)\n");

    if (!cpu1_alive()) return o.n;      /* the command channel is not armed */

    arg[0] = 0x12345678;
    pfb_s(&o, "ping    : "); p = o.n;
    if (cpu1_call(CPU1_CMD_PING, arg, res, 10000) == 0)
        pfb_s(&o, res[0] == (0x12345678u ^ 0xA5A5A5A5u) ? "ok" : "WRONG ANSWER");
    else
        pfb_s(&o, "TIMED OUT");
    pfb_pad(&o, p, 28); pfb_s(&o, "(live round-trip, this read)\n");

    /* ~200k iterations is a couple of ms on an A9 — long enough to measure,
     * short enough that the busy-wait in cpu1_call stays a diagnostic and not
     * a stall.  ticks are PERIPHCLK (CPU/2 = 333.33 MHz) = exactly 3 ns. */
    arg[0] = 200000;
    pfb_s(&o, "bench   : "); p = o.n;
    if (cpu1_call(CPU1_CMD_BENCH, arg, res, 100000) == 0 && res[0]) {
        uint64_t ns100 = ((uint64_t)res[0] * 300ULL) / 200000ULL;   /* ns/iter x100 */
        pfb_d(&o, (int)(ns100 / 100)); pfb_c(&o, '.');
        pfb_2d(&o, (int)(ns100 % 100)); pfb_s(&o, " ns/iter");
    } else {
        pfb_s(&o, "TIMED OUT");
    }
    pfb_pad(&o, p, 28); pfb_s(&o, "(200k-iteration integer loop)\n");
    return o.n;
}

static int pf_gen_temp(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
    struct { long long sec, usec; } tv = { 0, 0 };   /* time_t is 64-bit here — must not undersize */
    _gettimeofday(&tv, 0);
    int p;
    pfb_s(&o, "time    : "); p = o.n;
    if (tv.sec > 1000000000LL) {                     /* real epoch (clock synced) -> human date */
        pfb_datetime(&o, tv.sec);
        pfb_pad(&o, p, 28); pfb_s(&o, "(wall clock)\n");
    } else {                                         /* pre-sync: seconds since boot */
        int cs = (int)(tv.usec / 10000);
        pfb_d(&o, (int)tv.sec); pfb_c(&o, '.');
        pfb_c(&o, (char)('0' + cs / 10)); pfb_c(&o, (char)('0' + cs % 10));
        pfb_pad(&o, p, 28); pfb_s(&o, "(s since boot)\n");
    }
    /* Always-monotonic uptime (independent of the wall-clock/SNTP line above) so a
     * temp log still shows how long the board has been up after the clock syncs. */
    { extern void gtimer_timeofday(uint32_t *, uint32_t *);
      uint32_t up_s = 0, up_u = 0; gtimer_timeofday(&up_s, &up_u);
      pfb_s(&o, "uptime  : "); p = o.n;
      pfb_uptime_hms(&o, up_s);
      pfb_pad(&o, p, 28); pfb_s(&o, "(since boot, monotonic)\n"); }
#ifdef XT_HW
    extern int g_temp_brd, g_temp_brd_peak, g_temp_die, g_temp_die_peak;
    pfb_s(&o, "i2c_ext : "); p = o.n;
    if (g_temp_brd <= -1000000) pfb_s(&o, "n/a");
    else { pfb_milliC(&o, g_temp_brd); pfb_s(&o, " C   peak ");
           pfb_milliC(&o, g_temp_brd_peak); pfb_s(&o, " C"); }
    pfb_pad(&o, p, 28); pfb_s(&o, "(sensor 0x49, board)\n");
    pfb_s(&o, "xadc_int: "); p = o.n;
    if (g_temp_die <= -1000000) pfb_s(&o, "n/a");
    else { pfb_milliC(&o, g_temp_die); pfb_s(&o, " C   peak ");
           pfb_milliC(&o, g_temp_die_peak); pfb_s(&o, " C"); }
    pfb_pad(&o, p, 28); pfb_s(&o, "(PS die)\n");
#else
    pfb_s(&o, "no sensors on qemu\n");
#endif
    return o.n;
}

/* /OS/proc/limits — current vs compile-time-max use of each fixed-size kernel pool,
 * plus a peak high-water mark where the claim site tracks one ("-" = untracked).
 * One row per pool; max "-" means there is no single system-wide cap (see note). */
static void lim_row(pfb *o, const char *name, int cur, int max, int hwm, const char *note)
{
    int p = o->n;
    pfb_s(o, name); pfb_pad(o, p, 14);
    p = o->n; pfb_d(o, cur);                              pfb_pad(o, p, 8);
    p = o->n; if (max < 0) pfb_c(o, '-'); else pfb_d(o, max); pfb_pad(o, p, 8);
    p = o->n; if (hwm < 0) pfb_c(o, '-'); else pfb_d(o, hwm); pfb_pad(o, p, 8);
    if (note) pfb_s(o, note);
    pfb_c(o, '\n');
}
static int pf_gen_limits(char *buf, int sz)
{
    xt_limits_t L;
    frtos_limits(&L);
    pfb o = { buf, 0, sz };
    pfb_s(&o, "resource      cur     max     hwm\n");
    lim_row(&o, "processes",   L.proc_cur, L.proc_max, L.proc_hwm, 0);
    lim_row(&o, "pipes",       L.pipe_cur, L.pipe_max, L.pipe_hwm, 0);
    lim_row(&o, "prog-images", L.prog_cur, L.prog_max, -1, "(loaded ELF cache)");
    lim_row(&o, "open-fds",    L.fd_cur,   -1,         -1, "(explicit; stdio implicit)");
    /* fds are a per-process array, not a global pool; annotate the real cap */
    pfb_s(&o, "                            per-proc cap ");
    pfb_d(&o, L.fd_cap); pfb_s(&o, ", busiest proc "); pfb_d(&o, L.fd_busiest);
    pfb_c(&o, '\n');
    return o.n;
}

/* ---- driver ops ------------------------------------------------------------ */
static long pf_read(vfs_file *f, void *buf, uint32_t n)
{
    uint32_t avail = f->size > f->pos ? f->size - f->pos : 0;
    if (n > avail) n = avail;
    memcpy(buf, (const uint8_t *)f->data + f->pos, n);
    f->pos += n;
    return (long)n;
}

static long pf_lseek(vfs_file *f, long off, int whence)
{
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0) return -1;
    f->pos = (uint32_t)np;
    return np;
}

static void pf_close(vfs_file *f)
{
    if (f->priv) { frtos_free(f->priv, 0); f->priv = 0; }
}

/* /proc/kmsg is writable ONLY in the `dmesg -c` sense: any write CLEARS the ring. The
 * bytes are ignored — this is a control knob, not a log-injection path (that is SYS_klog). */
static long pf_kmsg_write(vfs_file *f, const void *buf, uint32_t n)
{
    (void)f; (void)buf;
    extern void klog_clear(void);
    klog_clear();
    return (long)n;
}

static int pf_open(vfs_mount *m, const char *rel, int flags, vfs_file *f)
{
    (void)m;
    if ((flags & VFS_O_ACCMODE) && !strcmp(rel, "/kmsg")) {   /* dmesg -c: write = clear */
        f->data = 0; f->priv = 0; f->size = 0; f->pos = 0;
        f->read = 0; f->write = pf_kmsg_write; f->lseek = pf_lseek; f->close = pf_close;
        return 0;
    }
    if (flags & VFS_O_ACCMODE) return -1;                 /* read-only fs otherwise */
    if (!strcmp(rel, "/kmsg")) {                          /* dmesg: the live klog buffer, in place */
        extern int klog_snapshot(const char **);
        const char *lp; int klen = klog_snapshot(&lp);
        f->data = (void *)lp; f->priv = 0;                /* static kernel buffer — don't free */
        f->size = (uint32_t)klen; f->pos = 0;
        f->read = pf_read; f->write = 0; f->lseek = pf_lseek; f->close = pf_close;
        return 0;
    }
    /* /net/* can list many connections — give those generators a bigger buffer */
    int cap = (!strncmp(rel, "/net/", 5)) ? PF_NETBUF : PF_BUF;
    char *buf = (char *)frtos_alloc(cap, 16, 0);
    if (!buf) return -1;
    int len = -1, pid, k;
    if (!strcmp(rel, "/uptime"))       len = pf_gen_uptime(buf, PF_BUF);
    else if (!strcmp(rel, "/meminfo")) len = pf_gen_meminfo(buf, PF_BUF);
    else if (!strcmp(rel, "/video"))   len = pf_gen_video(buf, PF_BUF);
    else if (!strcmp(rel, "/video-sii")) len = pf_gen_video_sii(buf, PF_BUF);
    else if (!strcmp(rel, "/video-kick")) len = pf_gen_video_kick(buf, PF_BUF);
    else if (!strcmp(rel, "/video-sleep")) len = pf_gen_video_sleep(buf, PF_BUF);
    else if (!strcmp(rel, "/temp"))    len = pf_gen_temp(buf, PF_BUF);
    else if (!strcmp(rel, "/limits"))  len = pf_gen_limits(buf, PF_BUF);
    else if (!strcmp(rel, "/cpu1"))    len = pf_gen_cpu1(buf, PF_BUF);
    else if (!strcmp(rel, "/cpuinfo")) len = pf_gen_cpuinfo(buf, PF_BUF);
    else if (!strcmp(rel, "/mounts"))  { extern int vfs_mounts_str(char *, int); len = vfs_mounts_str(buf, PF_BUF); }
    else if (!strncmp(rel, "/net/", 5)) { extern int xt_procnet(const char *, char *, int); len = xt_procnet(rel + 5, buf, cap); }
    else if (rel[0] == '/' && (k = pf_num(rel + 1, &pid)) > 0) {
        const char *leaf = rel + 1 + k;
        if (!strcmp(leaf, "/stat"))         len = pf_gen_stat(pid, buf, PF_BUF);
        else if (!strcmp(leaf, "/status"))  len = pf_gen_status(pid, buf, PF_BUF);
        else if (!strcmp(leaf, "/cmdline")) len = pf_gen_cmdline(pid, buf, PF_BUF);
        else if (!strcmp(leaf, "/comm"))    len = pf_gen_comm(pid, buf, PF_BUF);
    }
    if (len < 0) { frtos_free(buf, 0); return -1; }
    f->data = buf; f->priv = buf;                         /* close frees */
    f->size = (uint32_t)len; f->pos = 0;
    f->read = pf_read; f->write = 0; f->lseek = pf_lseek; f->close = pf_close;
    return 0;
}

static int pf_stat(vfs_mount *m, const char *rel, struct xt_stat *st)
{
    (void)m;
    char comm[32], cmdl[8];
    int pid, k, cst;
    st->size = 0; st->mtime = 0;
    if (rel[0] == 0 || (rel[0] == '/' && rel[1] == 0)) { st->mode = XT_S_IFDIR; return 0; }
    if (!strcmp(rel, "/uptime") || !strcmp(rel, "/meminfo") || !strcmp(rel, "/kmsg") || !strcmp(rel, "/mounts") ||
        !strcmp(rel, "/video")  || !strcmp(rel, "/video-sii") || !strcmp(rel, "/video-kick") ||
        !strcmp(rel, "/video-sleep") ||
        !strcmp(rel, "/temp") || !strcmp(rel, "/limits") ||
        !strcmp(rel, "/cpu1") || !strcmp(rel, "/cpuinfo")) { st->mode = XT_S_IFREG; return 0; }
    if (!strcmp(rel, "/net")) { st->mode = XT_S_IFDIR; return 0; }
    if (!strncmp(rel, "/net/", 5)) {
        for (int i = 0; xt_procnet_leaves[i]; i++)
            if (!strcmp(rel + 5, xt_procnet_leaves[i])) { st->mode = XT_S_IFREG; return 0; }
        return -1;
    }
    if (rel[0] == '/' && (k = pf_num(rel + 1, &pid)) > 0) {
        const char *leaf = rel + 1 + k;
        if (pf_slot(pid, comm, sizeof comm, cmdl, sizeof cmdl, 0, &cst) < 0) return -1;
        if (!leaf[0]) { st->mode = XT_S_IFDIR; return 0; }
        if (!strcmp(leaf, "/stat") || !strcmp(leaf, "/status") ||
            !strcmp(leaf, "/cmdline") || !strcmp(leaf, "/comm")) {
            st->mode = XT_S_IFREG;
            return 0;
        }
    }
    return -1;
}

static int pf_readdir(vfs_mount *m, const char *rel, int index,
                      char *name, int nsz, unsigned *mode)
{
    (void)m;
    char comm[32], cmdl[8];
    int pid, k, cst;
    if (rel[0] == 0 || (rel[0] == '/' && rel[1] == 0)) {  /* root: pids then files */
        int emitted = 0;
        for (int i = 0; i < PF_MAXPROC; i++) {
            int p = frtos_proc_snap(i, comm, sizeof comm, cmdl, sizeof cmdl, 0, &cst);
            if (p <= 0) continue;
            if (emitted++ == index) {
                pfb o = { name, 0, nsz };
                pfb_d(&o, p);
                if (mode) *mode = XT_S_IFDIR;
                return 1;
            }
        }
        const char *fixed[] = { "uptime", "meminfo", "kmsg", "mounts", "video", "video-sii", "video-kick", "video-sleep", "temp", "limits", "cpu1", "cpuinfo" };
        int fi = index - emitted;
        if (fi >= 0 && fi < (int)(sizeof fixed / sizeof fixed[0])) {
            pfb o = { name, 0, nsz };
            pfb_s(&o, fixed[fi]);
            if (mode) *mode = XT_S_IFREG;
            return 1;
        }
        fi -= (int)(sizeof fixed / sizeof fixed[0]);
        if (fi == 0) {                                   /* the net/ subdir */
            pfb o = { name, 0, nsz };
            pfb_s(&o, "net");
            if (mode) *mode = XT_S_IFDIR;
            return 1;
        }
        return 0;
    }
    if (!strcmp(rel, "/net")) {                          /* /net leaves */
        int c = 0; while (xt_procnet_leaves[c]) c++;
        if (index < 0 || index >= c) return 0;
        pfb o = { name, 0, nsz };
        pfb_s(&o, xt_procnet_leaves[index]);
        if (mode) *mode = XT_S_IFREG;
        return 1;
    }
    if (rel[0] == '/' && (k = pf_num(rel + 1, &pid)) > 0 && !rel[1 + k]) {
        const char *leaf[] = { "stat", "status", "cmdline", "comm" };
        if (index < 0 || index >= 4) return 0;
        if (pf_slot(pid, comm, sizeof comm, cmdl, sizeof cmdl, 0, &cst) < 0) return -1;
        pfb o = { name, 0, nsz };
        pfb_s(&o, leaf[index]);
        if (mode) *mode = XT_S_IFREG;
        return 1;
    }
    return -1;
}

static vfs_fs procfs_fs = {
    .name = "procfs", .open = pf_open,
    .stat = pf_stat, .readdir = pf_readdir,
};

void vfs_procfs_init(void) { vfs_register_fs(&procfs_fs); }
