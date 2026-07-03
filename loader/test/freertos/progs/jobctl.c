/* jobctl.c — /bin/fg, /bin/bg, /bin/jobs (one binary, dispatched on argv[0]).
 *
 * Job control without process groups: ^Z stops the foreground job (kernel
 * stop_park; waitpid reports it and the shell reprompts). These pick it up:
 *   jobs        list stopped processes (state T in /OS/proc)
 *   bg [PID]    resume one in the background (XT_SIGCONT)
 *   fg [PID]    resume one and wait for it — the kernel doesn't enforce wait
 *               parentage, so fg's waitpid puts the job back on the foreground
 *               stack and ^C/^Z work on it again
 * PID defaults to the most recently started stopped job (highest pid).
 * Bare usys — tiny, no libc. */
#include "usys.h"

static void w(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }
static void werr(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(2, s, n); }

static void wnum(int v)
{
    char b[12]; int i = 11; b[i] = 0;
    if (!v) b[--i] = '0';
    while (v > 0 && i > 0) { b[--i] = (char)('0' + v % 10); v /= 10; }
    w(b + i);
}

static int parse_num(const char *s)
{
    int v = 0;
    if (!s || !*s) return -1;
    for (; *s; s++) { if (*s < '0' || *s > '9') return -1; v = v * 10 + (*s - '0'); }
    return v;
}

/* /OS/proc/<pid>/stat is "pid (comm) S ..." — comm + state out, 1 on success */
static int read_stat(int pid, char *comm, int csz, char *state)
{
    char path[48], buf[128];
    int i = 0;
    const char *pfx = "/OS/proc/";
    while (pfx[i]) { path[i] = pfx[i]; i++; }
    { char nb[12]; int k = 11; nb[k] = 0;
      int v = pid; if (!v) nb[--k] = '0';
      while (v > 0) { nb[--k] = (char)('0' + v % 10); v /= 10; }
      for (; nb[k]; k++) path[i++] = nb[k]; }
    const char *sfx = "/stat";
    for (int k = 0; sfx[k]; k++) path[i++] = sfx[k];
    path[i] = 0;

    int fd = sys_open(path, 0);
    if (fd < 0) return 0;
    long n = sys_read(fd, buf, sizeof buf - 1);
    sys_close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;

    char *o = 0, *c = 0;
    for (i = 0; buf[i]; i++) { if (buf[i] == '(' && !o) o = buf + i; if (buf[i] == ')') c = buf + i; }
    if (!o || !c || c < o) return 0;
    int k = 0;
    for (char *q = o + 1; q < c && k < csz - 1; q++) comm[k++] = *q;
    comm[k] = 0;
    *state = (c[1] == ' ') ? c[2] : '?';
    return 1;
}

/* the most recently started stopped job = the highest pid in state T */
static int find_stopped(void)
{
    struct xt_dirent de;
    int best = 0;
    for (int idx = 0; sys_readdir("/OS/proc", idx, &de) == 1; idx++) {
        int pid = parse_num(de.name);
        if (pid <= 0) continue;
        char comm[32], st;
        if (read_stat(pid, comm, sizeof comm, &st) && st == 'T' && pid > best) best = pid;
    }
    return best;
}

void _app_entry(int argc, char **argv)
{
    const char *me = argv[0];
    for (const char *q = me; *q; q++) if (*q == '/') me = q + 1;   /* basename */
    int is_fg = (me[0] == 'f'), is_bg = (me[0] == 'b');

    if (!is_fg && !is_bg) {                                        /* jobs */
        struct xt_dirent de;
        int any = 0;
        for (int idx = 0; sys_readdir("/OS/proc", idx, &de) == 1; idx++) {
            int pid = parse_num(de.name);
            if (pid <= 0) continue;
            char comm[32], st;
            if (!read_stat(pid, comm, sizeof comm, &st) || st != 'T') continue;
            w("["); wnum(pid); w("]  Stopped\t"); w(comm); w("\n");
            any = 1;
        }
        if (!any) w("no stopped jobs\n");
        sys_exit(0);
    }

    int pid = (argc > 1) ? parse_num(argv[1]) : find_stopped();
    if (pid <= 0) {
        werr(is_fg ? "fg: no stopped job\n" : "bg: no stopped job\n");
        sys_exit(1);
    }
    if (sys_kill(pid, 18) != 0) {                                  /* XT_SIGCONT */
        werr("no such process\n");
        sys_exit(1);
    }
    if (is_bg) {
        w("["); wnum(pid); w("] continued\n");
        sys_exit(0);
    }
    long code = sys_waitpid(pid);                                  /* fg: job returns to the
                                                                    * foreground stack */
    if (code == XT_WAIT_STOPPED) {                                 /* ^Z again */
        w("\n["); wnum(pid); w("]  Stopped\n");
        sys_exit(0);
    }
    sys_exit(code < 0 ? 1 : (int)code);
}
