/* vfs_procfs.c — the process table as files, mounted /OS/proc.
 *
 * Layout (a Linux-shaped subset — enough for toybox ps/top/killall, whose
 * /proc literals are patched to /OS/proc):
 *   /OS/proc/<pid>/stat      the do_task_stat line (real pid/comm/state,
 *                            plausible zeros for the accounting fields)
 *   /OS/proc/<pid>/status    Name/State/Pid/Uid/Gid, tab-separated
 *   /OS/proc/<pid>/cmdline   argv, NUL-joined
 *   /OS/proc/uptime          wall clock since boot
 *   /OS/proc/meminfo         static totals (tools want it to exist)
 *
 * Content is generated at OPEN into an allocated buffer (a moment-in-time
 * snapshot; the fd then reads in-memory via vf.data), freed at close. Opens
 * run in the fs task; the generators only read the kernel proc table.
 */
#include "vfs.h"
#include "frtos_os.h"
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
    struct { long sec, usec; } tv = { 0, 0 };
    _gettimeofday(&tv, 0);
    int cs = (int)(tv.usec / 10000);
    pfb o = { buf, 0, sz };
    for (int i = 0; i < 2; i++) {
        pfb_d(&o, (int)tv.sec); pfb_c(&o, '.');
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
    struct { long sec, usec; } t0, t1;
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

#ifdef XT_HW
/* Zynq PS XADC die temperature via the devcfg XADCIF FIFO (UG585 B.34, regs per
 * xadcps_hw.h).  ps7_init leaves the on-chip system monitor sampling the sensors
 * into DRP status regs (0x00 = temperature); pop any stale result, push a READ
 * of DRP 0x00 + a NOP to flush the 1-deep pipeline, read the 16-bit code, and
 * convert: T(C) = code*503.975/65536 - 273.15.  Returns milli-C or -1000000. */
#define XADC_MSTS   (*(volatile uint32_t *)0xF800710Cu)
#define XADC_CMDF   (*(volatile uint32_t *)0xF8007110u)
#define XADC_RDF    (*(volatile uint32_t *)0xF8007114u)
#define XADC_DFIFOE 0x00000400u        /* MSTS: read (data) FIFO empty */
static int xadc_temp_milliC(void)
{
    uint32_t to = 100000;
    while (!(XADC_MSTS & XADC_DFIFOE) && --to) (void)XADC_RDF;   /* drain stale */
    XADC_CMDF = (1u << 26) | (0x00u << 16);                      /* READ DRP 0x00 (temp) */
    XADC_CMDF = 0u;                                              /* NOP: flush pipeline  */
    to = 100000;
    while ((XADC_MSTS & XADC_DFIFOE) && --to) { }               /* wait for a result */
    if (XADC_MSTS & XADC_DFIFOE) return -1000000;               /* no data */
    uint32_t code = XADC_RDF & 0xFFFFu;
    return (int)(((int64_t)code * 503975) / 65536) - 273150;    /* -> milli-C */
}
#endif

/* /OS/proc/temp — board (I2C 0x49) and die (PS XADC) temperatures with a boot
 * timestamp, so a `while : ; do cat /OS/proc/temp; sleep 1; done` log can be
 * correlated against HDMI drops. */
static int pf_gen_temp(char *buf, int sz)
{
    pfb o = { buf, 0, sz };
    struct { long sec, usec; } tv = { 0, 0 };
    _gettimeofday(&tv, 0);
    int cs = (int)(tv.usec / 10000);
    pfb_s(&o, "time:     "); pfb_d(&o, (int)tv.sec); pfb_c(&o, '.');
    pfb_c(&o, (char)('0' + cs / 10)); pfb_c(&o, (char)('0' + cs % 10));
    pfb_s(&o, "  (s since boot)\n");
#ifdef XT_HW
    extern int hdmi_temp_i2c(void);
    int ie = hdmi_temp_i2c();
    int di = xadc_temp_milliC();
    pfb_s(&o, "i2c_ext:  ");
    if (ie <= -1000000) pfb_s(&o, "n/a (I2C error)");
    else { pfb_milliC(&o, ie); pfb_s(&o, " C   (sensor 0x49, board)"); }
    pfb_c(&o, '\n');
    pfb_s(&o, "xadc_int: ");
    if (di <= -1000000) pfb_s(&o, "n/a (XADC no data)");
    else { pfb_milliC(&o, di); pfb_s(&o, " C   (PS die)"); }
    pfb_c(&o, '\n');
#else
    (void)cs; pfb_s(&o, "no sensors on qemu\n");
#endif
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

static int pf_open(vfs_mount *m, const char *rel, int flags, vfs_file *f)
{
    (void)m;
    if (flags & VFS_O_ACCMODE) return -1;                 /* read-only fs */
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
    else if (!strcmp(rel, "/temp"))    len = pf_gen_temp(buf, PF_BUF);
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
        !strcmp(rel, "/temp")) { st->mode = XT_S_IFREG; return 0; }
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
        const char *fixed[] = { "uptime", "meminfo", "kmsg", "mounts", "video", "video-sii", "video-kick", "temp" };
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
