/*
 * gemclient.c — the client half of the GEM transport.
 *
 * The split it enforces (RESPONSIBILITIES.md §5, and it is the whole design):
 *
 *   - CONTROL crosses the channel: window ops, damage rects. Tiny, and it is the only thing
 *     gemd ever hears from an app.
 *   - PIXELS never do. The app draws into its OWN backing store with its own VDI, at full
 *     speed, with ZERO IPC — then posts one damage rect saying "this rect of my surface is
 *     new". gemd is never told *why* it changed, and it never draws an app's content.
 *
 * TRANSPORT ONLY, and NOT an app-facing API: an app sees the AES (wind_create, wind_open,
 * wind_content, …), whose signatures do not change one character under gemd. gem/aes/window.c
 * calls into here; nothing else should. In M1 gemtext called this directly — that was
 * scaffolding for one client, and M2 removed it.
 */
#include <string.h>
#include <stdio.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include "gemclient.h"
#include "usys.h"

/* xg_now_ms — milliseconds since an arbitrary fixed point, for XG's toolkit (the event recorder
 * stamps captures with it; animation and double-click timing want the same clock).  Only
 * DIFFERENCES are meaningful.  Same split the rest of the host build uses: over the POSIX shim the
 * raw XTOS trap is not available to a CLIENT — libSystem's own __syscall resolves first and traps
 * SIGSYS on an XTOS call number — so ask POSIX there and keep the trap for the board. */
#ifdef GEM_HOST
#include <sys/time.h>
#include <time.h>
int xg_now_ms(void) {
    struct timeval tv; gettimeofday(&tv, 0);
    return (int)((long long)tv.tv_sec * 1000ll + tv.tv_usec / 1000);
}
#else
int xg_now_ms(void) {
    unsigned tv[4] = {0,0,0,0};                 /* four words: see gemd_us — a 16-byte writer */
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (int)((long long)tv[0] * 1000ll + tv[2] / 1000);
}
#endif

/* xg_now_utc — the wall clock for XG's XGDate.currentDate, as UTC civil components:
 *     out7 = { year, month(1..12), day, hour, minute, second, microsecond }
 * Components rather than an epoch count because that is what the toolkit wants and epoch
 * milliseconds do not fit its 32-bit int.  The civil conversion is done HERE, in integer arithmetic
 * (Hinnant's civil_from_days), so the target does not need a gmtime: the board's libc is not the
 * host's, and this file is compiled into libGEM for both. */
static void xg_civil_from_days(int z, int *y, int *m, int *d) {
    z += 719468;
    int era = (z >= 0 ? z : z - 146096) / 146097;
    int doe = z - era * 146097;
    int yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    int yy  = yoe + era * 400;
    int doy = doe - (365*yoe + yoe/4 - yoe/100);
    int mp  = (5*doy + 2) / 153;
    int dd  = doy - (153*mp + 2)/5 + 1;
    int mm  = mp + (mp < 10 ? 3 : -9);
    if (mm <= 2) yy++;
    *y = yy; *m = mm; *d = dd;
}
void xg_now_utc(int *out7) {
    long secs = 0, usecs = 0;
#ifdef GEM_HOST
    { struct timeval tv; gettimeofday(&tv, 0); secs = (long)tv.tv_sec; usecs = (long)tv.tv_usec; }
#else
    { unsigned tv[4] = {0,0,0,0};
      __syscall(SYS_gettimeofday, (long)tv, 0, 0);
      secs = (long)tv[0]; usecs = (long)tv[2]; }
#endif
    long days = secs / 86400, rem = secs % 86400;
    if (rem < 0) { rem += 86400; days--; }                 /* floor, so pre-1970 lands right */
    int y = 1970, m = 1, d = 1;
    xg_civil_from_days((int)days, &y, &m, &d);
    out7[0] = y; out7[1] = m; out7[2] = d;
    out7[3] = (int)(rem / 3600); out7[4] = (int)((rem % 3600) / 60); out7[5] = (int)(rem % 60);
    out7[6] = (int)usecs;
}

/* xg_local_offset_minutes — the host's current UTC offset, DST already applied by whoever owns the
 * rules.  The BOARD has no timezone database and no notion of local time, so it answers 0 (UTC) —
 * honestly, rather than inventing an offset.  A tz-aware XTOS would replace this one function. */
int xg_local_offset_minutes(void) {
#ifdef GEM_HOST
    time_t t = time(0);
    struct tm l;
    localtime_r(&t, &l);
    return (int)(l.tm_gmtoff / 60);
#else
    return 0;                            /* XTOS runs on UTC */
#endif
}

/* xg_listdir — a portable directory listing for XG's toolkit file panel (GEM has no OS file
 * selector).  Writes one "t\tsize\tname\n" line per entry into buf (t = 'd' for a directory, 'f' for
 * a file; size is bytes, 0 for directories), dot-entries skipped.  Returns the entry count, or -1 if
 * the directory can't be opened.
 * Lives here because gemclient.c is compiled into libGEM on BOTH the host and the arm9 build, so the
 * struct-dirent layout is whatever each platform's headers say — the XG client never sees it. */
int xg_listdir(const char *path, char *buf, int cap) {
    DIR *d = opendir(path);
    if (!d) return -1;
    int n = 0, off = 0;
    struct dirent *de;
    while ((de = readdir(d)) != 0 && off < cap - 300) {
        const char *nm = de->d_name;
        if (nm[0] == '.' && (nm[1] == 0 || (nm[1] == '.' && nm[2] == 0))) continue;   /* skip . and .. */
        char full[1024];
        snprintf(full, sizeof full, "%s/%s", path, nm);
        struct stat st;
        int ok = (stat(full, &st) == 0);
        int isdir = ok && S_ISDIR(st.st_mode);
        long long sz = (ok && !isdir) ? (long long)st.st_size : 0;
        off += snprintf(buf + off, cap - off, "%c\t%lld\t%s\n", isdir ? 'd' : 'f', sz, nm);
        n++;
    }
    closedir(d);
    return n;
}

/* File operations for XG's toolkit file panel (rename/delete/copy), 1 on success, 0 on failure. */
int xg_unlink(const char *path)              { return unlink(path) == 0 ? 1 : 0; }
int xg_rename(const char *a, const char *b)  { return rename(a, b) == 0 ? 1 : 0; }
int xg_copyfile(const char *a, const char *b) {
    FILE *in = fopen(a, "rb"); if (!in) return 0;
    FILE *out = fopen(b, "wb"); if (!out) { fclose(in); return 0; }
    char buf[8192]; size_t n; int ok = 1;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) { if (fwrite(buf, 1, n, out) != n) { ok = 0; break; } }
    fclose(in); fclose(out);
    return ok;
}

/* How long gem_connect() will WAIT for the "gem" service to appear before giving up — and
 * giving up is now FATAL (wind_client_attach exits): on XTOS there is no single-process mode
 * to fall back to. The wait exists because a program started ALONGSIDE gemd -- the desktop,
 * out of 99-Desktop -- races it at boot, and the loser of that race must not lose.
 *
 * It is deliberately the CLIENT's problem and not gemd's: gemd does not spawn the desktop and
 * must never know what a desktop is (§2, §4). The boot script starts both; whoever comes up
 * second just waits. A program that WANTS to fail fast sets the wait to 0.
 *
 * The default is not 0, because "gemd is still coming up" and "gemd is not there" must not look
 * the same to an app launched a moment too early. */
#define GEM_CONNECT_WAIT_DEFAULT_MS 2000
static int g_wait_ms = GEM_CONNECT_WAIT_DEFAULT_MS;
void gem_connect_set_wait(int ms) { g_wait_ms = ms; }

int gem_connect(void)
{
    int waited = 0;
    for (;;) {
        int fd = sys_svc_connect(GEM_SERVICE);
        if (fd >= 0) return fd;                /* connected */
        if (waited >= g_wait_ms) return fd;    /* gave up: there is no gemd. The caller FAILS. */
        sys_nanosleep(50000);                  /* usec: 50 ms */
        waited += 50;
    }
}

/* A failed write means gemd is dying. It is not fatal HERE: the next read returns EOF, and EOF
 * is the one true death signal (a channel must never have SIGPIPE semantics). */
int gem_send(int fd, const gem_msg *m)
{
    return (sys_write(fd, m, (unsigned)GEM_MSG_SZ) == GEM_MSG_SZ) ? 0 : -1;
}

int gem_recv(int fd, gem_msg *m)
{
    char *p = (char *)m;
    int got = 0;
    while (got < GEM_MSG_SZ) {                 /* a channel is a byte stream: a record can split */
        long r = sys_read(fd, p + got, (unsigned)(GEM_MSG_SZ - got));
        if (r <= 0) return -1;                 /* EOF: gemd is gone. Nothing works after this. */
        got += (int)r;
    }
    return 0;
}

int gem_await(int fd, int op, gem_msg *m)
{
    for (;;) {
        if (gem_recv(fd, m) != 0) return -1;
        if (m->w[0] == op) return 0;
        if (m->w[0] == GEM_WIND_ERROR) return -1;
        /* NOT discarded (M4): a window handshake is not a quiet moment any more — the pointer is
         * live and an event can land inside it. Anything else goes to the AES's client queue,
         * because a dropped button-up is a drag that never ends. */
        wind_client_stray(m);
    }
}

uint32_t *gem_surf_map(int surf_id)
{
    /* The surface is XT_SHM_OWNED and gemd granted it to US — against the pid the KERNEL reports
     * for this channel, not one we claimed in a message. No other client can map it. */
    return (uint32_t *)sys_shm_map(surf_id);
}

void gem_surf_unmap(int fd, int surf_id)
{
    if (surf_id < 0) return;
    sys_shm_unmap(surf_id);                    /* our ref. gemd holds its own, so a composite in
                                                * flight stays valid (§11: refcount, no handshake) */
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_SURF_DROP;
    m.u[0] = (uint32_t)surf_id;
    gem_send(fd, &m);
}

void gem_damage_rect(int fd, int wh, int surf_id, uint32_t surf_gen, int x, int y, int w, int h)
{
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_DAMAGE;
    m.w[1] = (int16_t)wh;
    m.w[2] = (int16_t)x; m.w[3] = (int16_t)y;
    m.w[4] = (int16_t)w; m.w[5] = (int16_t)h;
    m.u[0] = (uint32_t)surf_id;
    m.u[1] = surf_gen;
    m.u[2] = 0;      /* retire_seq — set in ONE place so no caller can forget it. Dead in phase 1
                      * (§14); phase 2's queued blitter makes "I posted damage" stop meaning "my
                      * pixels are in memory", and adding the field then breaks every client. */
    gem_send(fd, &m);
}
