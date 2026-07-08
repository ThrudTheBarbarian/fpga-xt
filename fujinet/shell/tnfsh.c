/*
 * tnfsh — interactive TNFS shell over libfujinet.
 *
 *   tnfsh [host[:port] [mountpath]]
 *
 * Commands: open close ls cd pwd get put cat stat df mkdir rmdir rm mv
 *           help quit
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <fujinet/tnfs.h>

#define MAX_PATH 512
#define MAX_ARGS 8

static tnfs_session g_session;
static int  g_connected;
static char g_host[128];
static char g_cwd[MAX_PATH] = "/";

/* ---------------------------------------------------------------- paths */

/* Resolve `arg` against the cwd, normalising "." and "..". */
static void path_resolve(const char *arg, char *out, size_t cap)
{
    char joined[MAX_PATH * 2];
    if (arg && arg[0] == '/')
        snprintf(joined, sizeof joined, "%s", arg);
    else
        snprintf(joined, sizeof joined, "%s/%s", g_cwd, arg ? arg : "");

    /* split on '/', apply . and .. */
    char *parts[64];
    int nparts = 0;
    char work[MAX_PATH * 2];
    snprintf(work, sizeof work, "%s", joined);
    for (char *tok = strtok(work, "/"); tok; tok = strtok(NULL, "/")) {
        if (strcmp(tok, ".") == 0)
            continue;
        if (strcmp(tok, "..") == 0) {
            if (nparts > 0)
                nparts--;
            continue;
        }
        if (nparts < 64)
            parts[nparts++] = tok;
    }

    size_t off = 0;
    out[0] = '\0';
    for (int i = 0; i < nparts; i++) {
        int n = snprintf(out + off, cap - off, "/%s", parts[i]);
        if (n < 0 || (size_t)n >= cap - off)
            break;
        off += (size_t)n;
    }
    if (out[0] == '\0')
        snprintf(out, cap, "/");
}

static const char *path_basename(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/* ------------------------------------------------------------- helpers */

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int require_connected(void)
{
    if (!g_connected) {
        printf("not connected — use: open <host[:port]> [mountpath]\n");
        return 0;
    }
    return 1;
}

static void report(const char *what, int rc)
{
    printf("%s: %s\n", what, tnfs_strerror(rc));
}

/* ------------------------------------------------------------ commands */

static void cmd_close(void)
{
    if (g_connected) {
        tnfs_disconnect(&g_session);
        g_connected = 0;
        printf("disconnected from %s\n", g_host);
    }
    snprintf(g_cwd, sizeof g_cwd, "/");
}

static void cmd_open(const char *hostspec, const char *mountpath)
{
    char host[128];
    uint16_t port = TNFS_PORT;
    int transport = TNFS_T_AUTO;

    if (!hostspec) {
        printf("usage: open <[udp://|tcp://]host[:port]> [mountpath]\n");
        return;
    }
    cmd_close();

    if (strncmp(hostspec, "udp://", 6) == 0) { transport = TNFS_T_UDP; hostspec += 6; }
    else if (strncmp(hostspec, "tcp://", 6) == 0) { transport = TNFS_T_TCP; hostspec += 6; }

    snprintf(host, sizeof host, "%s", hostspec);
    char *colon = strrchr(host, ':');
    if (colon) {
        *colon = '\0';
        port = (uint16_t)atoi(colon + 1);
    }
    if (!mountpath)
        mountpath = "/";

    int rc = tnfs_connect(&g_session, host, port, transport, mountpath);
    if (rc != TNFS_OK) {
        report("mount", rc);
        return;
    }

    g_connected = 1;
    snprintf(g_host, sizeof g_host, "%s", host);
    printf("mounted %s:%u%s over %s (server protocol %u.%u, min retry %u ms)\n",
           host, port, mountpath,
           g_session.io.stream ? "tcp" : "udp",
           g_session.server_version >> 8, g_session.server_version & 0xff,
           g_session.min_retry_ms);
}

static void cmd_ls(const char *arg)
{
    char path[MAX_PATH], entry[MAX_PATH], full[MAX_PATH * 2];
    uint8_t handle;

    if (!require_connected())
        return;
    path_resolve(arg, path, sizeof path);

    int rc = tnfs_opendir(&g_session, path, &handle);
    if (rc != TNFS_OK) {
        report("ls", rc);
        return;
    }

    int count = 0;
    for (;;) {
        rc = tnfs_readdir(&g_session, handle, entry, sizeof entry);
        if (rc == TNFS_EOF)
            break;
        if (rc != TNFS_OK) {
            report("ls", rc);
            break;
        }
        if (strcmp(entry, ".") == 0 || strcmp(entry, "..") == 0)
            continue;

        tnfs_stat_t st;
        snprintf(full, sizeof full, "%s/%s",
                 strcmp(path, "/") == 0 ? "" : path, entry);
        if (tnfs_stat(&g_session, full, &st) == TNFS_OK) {
            if (TNFS_S_ISDIR(st.mode))
                printf("%10s  %s/\n", "<dir>", entry);
            else
                printf("%10u  %s\n", st.size, entry);
        } else {
            printf("%10s  %s\n", "?", entry);
        }
        count++;
    }
    tnfs_closedir(&g_session, handle);
    printf("%d entr%s\n", count, count == 1 ? "y" : "ies");
}

static void cmd_cd(const char *arg)
{
    char path[MAX_PATH];
    uint8_t handle;

    if (!require_connected())
        return;
    path_resolve(arg ? arg : "/", path, sizeof path);

    /* validate by opening the directory */
    int rc = tnfs_opendir(&g_session, path, &handle);
    if (rc != TNFS_OK) {
        report("cd", rc);
        return;
    }
    tnfs_closedir(&g_session, handle);
    snprintf(g_cwd, sizeof g_cwd, "%s", path);
}

static void cmd_stat(const char *arg)
{
    char path[MAX_PATH];
    tnfs_stat_t st;

    if (!require_connected())
        return;
    if (!arg) {
        printf("usage: stat <path>\n");
        return;
    }
    path_resolve(arg, path, sizeof path);

    int rc = tnfs_stat(&g_session, path, &st);
    if (rc != TNFS_OK) {
        report("stat", rc);
        return;
    }
    time_t mtime = (time_t)st.mtime;
    char when[32] = "-";
    struct tm *tm = gmtime(&mtime);
    if (tm)
        strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", tm);
    printf("%s\n  type: %s  mode: %04o  size: %u bytes\n  mtime: %s UTC\n",
           path, TNFS_S_ISDIR(st.mode) ? "directory" : "file",
           st.mode & 07777, st.size, when);
}

/* progress display shared by get/put — throttled to ~4 updates/s */
typedef struct {
    double t0;
    double last_print;
    uint32_t done;
    uint32_t printed;
} xfer_ui;

static int xfer_progress(void *user, uint32_t done, uint32_t total)
{
    xfer_ui *ui = user;
    double now = now_seconds();

    ui->done = done;
    if (done == ui->printed)
        return 0;
    if (now - ui->last_print < 0.25 && done != total)
        return 0;
    ui->last_print = now;
    ui->printed = done;

    double dt = now - ui->t0;
    double kbs = dt > 0 ? done / 1024.0 / dt : 0.0;
    if (total)
        printf("\r%u / %u bytes (%u%%)  %.1f KB/s   ",
               done, total, (unsigned)(100.0 * done / total), kbs);
    else
        printf("\r%u bytes  %.1f KB/s   ", done, kbs);
    fflush(stdout);
    return 0;
}

static int file_sink(void *user, const void *buf, size_t len)
{
    return fwrite(buf, 1, len, (FILE *)user) == len ? 0 : -1;
}

static int file_source(void *user, void *buf, size_t cap)
{
    FILE *in = user;
    size_t n = fread(buf, 1, cap, in);
    if (n == 0 && ferror(in))
        return -1;
    return (int)n;
}

static void cmd_get(const char *remote, const char *local)
{
    char path[MAX_PATH];

    if (!require_connected())
        return;
    if (!remote) {
        printf("usage: get <remote> [local]\n");
        return;
    }
    path_resolve(remote, path, sizeof path);
    if (!local)
        local = path_basename(path);

    FILE *out = fopen(local, "wb");
    if (!out) {
        printf("get: cannot write local file '%s'\n", local);
        return;
    }

    xfer_ui ui = { .t0 = now_seconds() };
    int rc = tnfs_download(&g_session, path, file_sink, out,
                           xfer_progress, &ui);
    fclose(out);
    if (rc != TNFS_OK) {
        printf("\n");
        report("get", rc);
        return;
    }
    double dt = now_seconds() - ui.t0;
    printf("\r%u bytes -> %s in %.1fs (%.1f KB/s)      \n",
           ui.done, local, dt, dt > 0 ? ui.done / 1024.0 / dt : 0.0);
}

static void cmd_put(const char *local, const char *remote)
{
    char path[MAX_PATH];

    if (!require_connected())
        return;
    if (!local) {
        printf("usage: put <local> [remote]\n");
        return;
    }

    FILE *in = fopen(local, "rb");
    if (!in) {
        printf("put: cannot read local file '%s'\n", local);
        return;
    }
    uint32_t total = 0;
    if (fseek(in, 0, SEEK_END) == 0) {
        long sz = ftell(in);
        if (sz > 0)
            total = (uint32_t)sz;
        rewind(in);
    }
    path_resolve(remote ? remote : path_basename(local), path, sizeof path);

    xfer_ui ui = { .t0 = now_seconds() };
    int rc = tnfs_upload(&g_session, path, 0644, file_source, in, total,
                         xfer_progress, &ui);
    fclose(in);
    if (rc != TNFS_OK) {
        printf("\n");
        report("put", rc);
        return;
    }
    double dt = now_seconds() - ui.t0;
    printf("\r%u bytes -> %s in %.1fs (%.1f KB/s)      \n",
           ui.done, path, dt, dt > 0 ? ui.done / 1024.0 / dt : 0.0);
}

static int stdout_sink(void *user, const void *buf, size_t len)
{
    (void)user;
    return fwrite(buf, 1, len, stdout) == len ? 0 : -1;
}

static void cmd_cat(const char *remote)
{
    char path[MAX_PATH];

    if (!require_connected())
        return;
    if (!remote) {
        printf("usage: cat <remote>\n");
        return;
    }
    path_resolve(remote, path, sizeof path);

    int rc = tnfs_download(&g_session, path, stdout_sink, NULL, NULL, NULL);
    if (rc != TNFS_OK)
        report("cat", rc);
}

static void cmd_df(void)
{
    uint32_t total_kb = 0, free_kb = 0;
    if (!require_connected())
        return;
    int rc1 = tnfs_size(&g_session, &total_kb);
    int rc2 = tnfs_free(&g_session, &free_kb);
    if (rc1 == TNFS_OK && rc2 == TNFS_OK)
        printf("%u KB total, %u KB free\n", total_kb, free_kb);
    else
        report("df", rc1 != TNFS_OK ? rc1 : rc2);
}

static void path_op(const char *name, const char *arg,
                    int (*op)(tnfs_session *, const char *))
{
    char path[MAX_PATH];
    if (!require_connected())
        return;
    if (!arg) {
        printf("usage: %s <path>\n", name);
        return;
    }
    path_resolve(arg, path, sizeof path);
    int rc = op(&g_session, path);
    if (rc != TNFS_OK)
        report(name, rc);
}

static void cmd_mv(const char *from, const char *to)
{
    char pfrom[MAX_PATH], pto[MAX_PATH];
    if (!require_connected())
        return;
    if (!from || !to) {
        printf("usage: mv <from> <to>\n");
        return;
    }
    path_resolve(from, pfrom, sizeof pfrom);
    path_resolve(to, pto, sizeof pto);
    int rc = tnfs_rename(&g_session, pfrom, pto);
    if (rc != TNFS_OK)
        report("mv", rc);
}

static void cmd_help(void)
{
    printf("open <[udp://|tcp://]host[:port]> [mountpath]\n"
           "                                 connect + mount a TNFS server\n"
           "                                 (no scheme: try UDP, fall back to TCP)\n"
           "close                            umount + disconnect\n"
           "ls [path]                        list directory\n"
           "cd <path>                        change remote directory\n"
           "pwd                              print remote directory\n"
           "get <remote> [local]             download a file\n"
           "put <local> [remote]             upload a file\n"
           "cat <remote>                     print a remote file\n"
           "stat <path>                      show file details\n"
           "df                               filesystem size/free\n"
           "mkdir/rmdir/rm <path>            create/remove dir, delete file\n"
           "mv <from> <to>                   rename\n"
           "help                             this text\n"
           "quit                             exit\n");
}

/* ---------------------------------------------------------------- REPL */

static int split_args(char *line, char *argv[], int max)
{
    int argc = 0;
    char *p = line;
    while (*p && argc < max) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
            p++;
        if (!*p)
            break;
        char quote = 0;
        if (*p == '"' || *p == '\'')
            quote = *p++;
        argv[argc++] = p;
        if (quote) {
            while (*p && *p != quote)
                p++;
        } else {
            while (*p && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r')
                p++;
        }
        if (*p)
            *p++ = '\0';
    }
    return argc;
}

int main(int argc, char **argv)
{
    char line[1024];
    int tty = isatty(fileno(stdin));

    if (argc > 1)
        cmd_open(argv[1], argc > 2 ? argv[2] : NULL);
    else if (tty)
        printf("tnfsh — TNFS shell. 'open <host>' to connect, 'help' for commands.\n");

    for (;;) {
        if (tty) {
            if (g_connected)
                printf("tnfs://%s%s> ", g_host, g_cwd);
            else
                printf("tnfs> ");
            fflush(stdout);
        }
        if (!fgets(line, sizeof line, stdin))
            break;

        char *args[MAX_ARGS];
        int n = split_args(line, args, MAX_ARGS);
        if (n == 0)
            continue;
        const char *cmd = args[0];
        const char *a1 = n > 1 ? args[1] : NULL;
        const char *a2 = n > 2 ? args[2] : NULL;

        if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "exit") == 0)
            break;
        else if (strcmp(cmd, "open") == 0 || strcmp(cmd, "mount") == 0)
            cmd_open(a1, a2);
        else if (strcmp(cmd, "close") == 0 || strcmp(cmd, "umount") == 0)
            cmd_close();
        else if (strcmp(cmd, "ls") == 0 || strcmp(cmd, "dir") == 0)
            cmd_ls(a1);
        else if (strcmp(cmd, "cd") == 0)
            cmd_cd(a1);
        else if (strcmp(cmd, "pwd") == 0)
            printf("%s\n", g_cwd);
        else if (strcmp(cmd, "get") == 0)
            cmd_get(a1, a2);
        else if (strcmp(cmd, "put") == 0)
            cmd_put(a1, a2);
        else if (strcmp(cmd, "cat") == 0)
            cmd_cat(a1);
        else if (strcmp(cmd, "stat") == 0)
            cmd_stat(a1);
        else if (strcmp(cmd, "df") == 0)
            cmd_df();
        else if (strcmp(cmd, "mkdir") == 0)
            path_op("mkdir", a1, tnfs_mkdir);
        else if (strcmp(cmd, "rmdir") == 0)
            path_op("rmdir", a1, tnfs_rmdir);
        else if (strcmp(cmd, "rm") == 0)
            path_op("rm", a1, tnfs_unlink);
        else if (strcmp(cmd, "mv") == 0)
            cmd_mv(a1, a2);
        else if (strcmp(cmd, "help") == 0 || strcmp(cmd, "?") == 0)
            cmd_help();
        else
            printf("unknown command '%s' — try 'help'\n", cmd);
    }

    cmd_close();
    return 0;
}
