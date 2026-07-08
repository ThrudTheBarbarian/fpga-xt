/*
 * fujinetd — the FujiNet/TNFS daemon.
 *
 *   fujinetd [port] [logfile]     (default port 16385, log to stdout)
 *
 * A small control server on 127.0.0.1 speaking a line protocol; the
 * desktop (and anything else — `nc 127.0.0.1 16385` works) drives TNFS
 * through it. The daemon owns a pool of live server sessions so repeated
 * requests reuse a mount instead of re-mounting per operation.
 *
 * Protocol (one command per line; replies start '+' ok / '-' error):
 *   ping                                  -> +pong
 *   servers                               -> +ok, then per registry row:
 *        "<id> <udp|tcp|auto> <host>:<port> <path> <displayName>", then "."
 *   ls   <server> <path>
 *        -> +ok, then one entry per line: "d 0 <name>" | "f <size> <name>",
 *           terminated by "."
 *   stat <server> <path>                  -> +ok <d|f> <size> <mtime>
 *   df   <server>                         -> +ok <total-kb> <free-kb>
 *   get  <server> <remote> <local>
 *        -> "+progress <done> <total>" events, then "+ok <bytes>"
 *   quit                                  -> +bye (closes the connection)
 *
 * <server> is a registry id / displayName / host from the `fujinet` table
 * (which supplies port + transport), or a literal
 * "[udp://|tcp://]host[:port]" for unregistered servers.
 *
 * Portable: builds for the host (Makefile here) and for XTOS (loader/
 * Makefile, posix/net shims + libc.so; SQLite over the xt VFS). Single-
 * threaded, one client at a time — the desktop is the one real client.
 * Kill/restart is always safe: sessions are disposable and the server
 * side times them out.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sqlite3.h>

#include <fujinet/tnfs.h>

#define FUJID_PORT     16385
#define MAX_SESSIONS   4
#define LINE_MAX_LEN   768

/* registry (SQLite) with the fujinet/fujiTransport tables; optional — an
 * absent registry just disables `servers` and name resolution */
static const char *g_registry;      /* argv override */

static sqlite3 *reg_open(void)
{
    static const char *candidates[] =
        { NULL /* g_registry */, "/OS/var/registry.db",
          "/System/test/Registry.db" };    /* qemu romfs fixture */
    sqlite3 *db;
    candidates[0] = g_registry;
    for (int i = 0; i < 3; i++) {
        if (!candidates[i])
            continue;
        if (sqlite3_open_v2(candidates[i], &db, SQLITE_OPEN_READONLY, NULL)
                == SQLITE_OK)
            return db;
        sqlite3_close(db);
    }
    return NULL;
}

/* ------------------------------------------------------------- sessions */

typedef struct {
    char host[96];
    uint16_t port;
    int transport;
    int live;
    unsigned lastuse;
    tnfs_session s;
} pool_entry;

static pool_entry g_pool[MAX_SESSIONS];
static unsigned g_tick;

/* parse "[udp://|tcp://]host[:port]" */
static void parse_hostspec(const char *spec, char *host, size_t cap,
                           uint16_t *port, int *transport)
{
    *transport = TNFS_T_AUTO;
    *port = TNFS_PORT;
    if (strncmp(spec, "udp://", 6) == 0) { *transport = TNFS_T_UDP; spec += 6; }
    else if (strncmp(spec, "tcp://", 6) == 0) { *transport = TNFS_T_TCP; spec += 6; }
    snprintf(host, cap, "%s", spec);
    char *colon = strrchr(host, ':');
    if (colon) {
        *colon = '\0';
        *port = (uint16_t)atoi(colon + 1);
    }
}

/* resolve <server> against the registry: numeric id, displayName, or host.
   Returns 1 and fills host/port/transport on a hit. */
static int registry_server(const char *spec, char *host, size_t cap,
                           uint16_t *port, int *transport)
{
    sqlite3 *db = reg_open();
    if (!db)
        return 0;

    int all_digits = *spec != '\0';
    for (const char *p = spec; *p; p++)
        if (!isdigit((unsigned char)*p))
            all_digits = 0;

    const char *sql = all_digits
        ? "SELECT host,port,transport FROM fujinet WHERE id=?1"
        : "SELECT host,port,transport FROM fujinet "
          "WHERE displayName=?1 COLLATE NOCASE OR host=?1 LIMIT 1";
    sqlite3_stmt *st = NULL;
    int hit = 0;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        if (all_digits)
            sqlite3_bind_int(st, 1, atoi(spec));
        else
            sqlite3_bind_text(st, 1, spec, -1, SQLITE_STATIC);
        if (sqlite3_step(st) == SQLITE_ROW) {
            snprintf(host, cap, "%s", sqlite3_column_text(st, 0));
            *port = (uint16_t)sqlite3_column_int(st, 1);
            *transport = sqlite3_column_int(st, 2);
            hit = 1;
        }
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
    return hit;
}

static pool_entry *session_for(const char *spec, int *out_rc)
{
    char host[96];
    uint16_t port;
    int transport;
    if (!registry_server(spec, host, sizeof host, &port, &transport))
        parse_hostspec(spec, host, sizeof host, &port, &transport);

    pool_entry *victim = &g_pool[0];
    for (int i = 0; i < MAX_SESSIONS; i++) {
        pool_entry *e = &g_pool[i];
        if (e->live && e->port == port && e->transport == transport &&
            strcmp(e->host, host) == 0) {
            e->lastuse = ++g_tick;
            *out_rc = TNFS_OK;
            return e;
        }
        if (!e->live || e->lastuse < victim->lastuse)
            victim = e->live && !victim->live ? victim : e;
    }

    if (victim->live) {
        tnfs_disconnect(&victim->s);
        victim->live = 0;
    }
    int rc = tnfs_connect(&victim->s, host, port, transport, "/");
    *out_rc = rc;
    if (rc != TNFS_OK)
        return NULL;
    snprintf(victim->host, sizeof victim->host, "%s", host);
    victim->port = port;
    victim->transport = transport;
    victim->live = 1;
    victim->lastuse = ++g_tick;
    return victim;
}

/* a transport-level failure means the session is toast — drop it so the
   next command reconnects fresh instead of erroring forever */
static void session_check(pool_entry *e, int rc)
{
    if (rc == TNFS_ERR_TIMEOUT || rc == TNFS_ERR_TRANSPORT) {
        tnfs_disconnect(&e->s);
        e->live = 0;
    }
}

/* ------------------------------------------------------------ client io */

static int g_client = -1;

static void say(const char *fmt, ...)
{
    char line[LINE_MAX_LEN];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (n > (int)sizeof line - 2)
        n = (int)sizeof line - 2;
    line[n] = '\n';
    send(g_client, line, (size_t)n + 1, 0);
}

typedef struct {
    char buf[1024];
    size_t len;
} line_reader;

/* read one \n-terminated line; returns length, 0 on EOF, -1 on error */
static int read_line(line_reader *r, char *out, size_t cap)
{
    for (;;) {
        char *nl = memchr(r->buf, '\n', r->len);
        if (nl) {
            size_t n = (size_t)(nl - r->buf);
            if (n >= cap)
                n = cap - 1;
            memcpy(out, r->buf, n);
            out[n] = '\0';
            size_t consumed = (size_t)(nl - r->buf) + 1;
            r->len -= consumed;
            memmove(r->buf, r->buf + consumed, r->len);
            if (n && out[n - 1] == '\r')
                out[n - 1] = '\0';
            return (int)(n ? n : 1);
        }
        if (r->len == sizeof r->buf)
            return -1;                          /* runaway line */
        ssize_t k = recv(g_client, r->buf + r->len, sizeof r->buf - r->len, 0);
        if (k <= 0)
            return (int)k;
        r->len += (size_t)k;
    }
}

/* ------------------------------------------------------------- commands */

static void cmd_servers(void)
{
    sqlite3 *db = reg_open();
    if (!db) {
        say("-err no registry");
        return;
    }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT f.id, t.type, f.host, f.port, f.path,"
            " COALESCE(NULLIF(f.displayName,''), f.host)"
            " FROM fujinet f JOIN fujiTransport t ON t.id = f.transport"
            " ORDER BY f.id", -1, &st, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        say("-err registry query failed");
        return;
    }
    say("+ok");
    while (sqlite3_step(st) == SQLITE_ROW)
        say("%d %s %s:%d %s %s",
            sqlite3_column_int(st, 0), sqlite3_column_text(st, 1),
            sqlite3_column_text(st, 2), sqlite3_column_int(st, 3),
            sqlite3_column_text(st, 4), sqlite3_column_text(st, 5));
    sqlite3_finalize(st);
    sqlite3_close(db);
    say(".");
}

static void cmd_ls(const char *spec, const char *path)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say("-err mount: %s", tnfs_strerror(rc));
        return;
    }

    uint8_t handle;
    rc = tnfs_opendir(&e->s, path, &handle);
    if (rc != TNFS_OK) {
        session_check(e, rc);
        say("-err opendir: %s", tnfs_strerror(rc));
        return;
    }
    say("+ok");
    char name[512], full[1024];
    for (;;) {
        rc = tnfs_readdir(&e->s, handle, name, sizeof name);
        if (rc != TNFS_OK)
            break;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;
        tnfs_stat_t st;
        snprintf(full, sizeof full, "%s/%s",
                 strcmp(path, "/") == 0 ? "" : path, name);
        if (tnfs_stat(&e->s, full, &st) == TNFS_OK)
            say("%c %u %s", TNFS_S_ISDIR(st.mode) ? 'd' : 'f', st.size, name);
        else
            say("f 0 %s", name);
    }
    tnfs_closedir(&e->s, handle);
    session_check(e, rc == TNFS_EOF ? TNFS_OK : rc);
    say(".");
}

static void cmd_stat(const char *spec, const char *path)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say("-err mount: %s", tnfs_strerror(rc));
        return;
    }
    tnfs_stat_t st;
    rc = tnfs_stat(&e->s, path, &st);
    session_check(e, rc);
    if (rc != TNFS_OK)
        say("-err stat: %s", tnfs_strerror(rc));
    else
        say("+ok %c %u %u", TNFS_S_ISDIR(st.mode) ? 'd' : 'f',
            st.size, st.mtime);
}

static void cmd_df(const char *spec)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say("-err mount: %s", tnfs_strerror(rc));
        return;
    }
    uint32_t total = 0, freekb = 0;
    rc = tnfs_size(&e->s, &total);
    if (rc == TNFS_OK)
        rc = tnfs_free(&e->s, &freekb);
    session_check(e, rc);
    if (rc != TNFS_OK)
        say("-err df: %s", tnfs_strerror(rc));
    else
        say("+ok %u %u", total, freekb);
}

typedef struct {
    uint32_t last;
} get_progress;

static int get_progress_cb(void *user, uint32_t done, uint32_t total)
{
    get_progress *gp = user;
    if (done && done == gp->last)
        return 0;
    if (done - gp->last >= 16384 || done == total) {
        gp->last = done;
        say("+progress %u %u", done, total);
    }
    return 0;
}

static int file_sink(void *user, const void *buf, size_t len)
{
    return fwrite(buf, 1, len, (FILE *)user) == len ? 0 : -1;
}

static void cmd_get(const char *spec, const char *remote, const char *local)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say("-err mount: %s", tnfs_strerror(rc));
        return;
    }

    /* atomic: download to <local>.part, rename into place on success */
    char part[600];
    snprintf(part, sizeof part, "%s.part", local);
    FILE *out = fopen(part, "wb");
    if (!out) {
        say("-err cannot write %s", part);
        return;
    }

    get_progress gp = { 0 };
    rc = tnfs_download(&e->s, remote, file_sink, out, get_progress_cb, &gp);
    fclose(out);
    session_check(e, rc);
    if (rc != TNFS_OK) {
        remove(part);
        say("-err get: %s", tnfs_strerror(rc));
        return;
    }
    if (rename(part, local) != 0) {
        remove(part);
        say("-err rename to %s failed", local);
        return;
    }
    say("+ok %u", gp.last);
}

/* --------------------------------------------------------------- server */

static int split(char *line, char *argv[], int max)
{
    int argc = 0;
    char *p = line;
    while (*p && argc < max) {
        while (*p == ' ' || *p == '\t')
            p++;
        if (!*p)
            break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t')
            p++;
        if (*p)
            *p++ = '\0';
    }
    return argc;
}

static void serve(int client)
{
    line_reader r = { .len = 0 };
    char line[LINE_MAX_LEN];

    g_client = client;
    for (;;) {
        int n = read_line(&r, line, sizeof line);
        if (n <= 0)
            break;

        char *argv[4];
        int argc = split(line, argv, 4);
        if (argc == 0)
            continue;

        if (strcmp(argv[0], "ping") == 0)
            say("+pong");
        else if (strcmp(argv[0], "servers") == 0)
            cmd_servers();
        else if (strcmp(argv[0], "quit") == 0) {
            say("+bye");
            break;
        }
        else if (strcmp(argv[0], "ls") == 0 && argc >= 3)
            cmd_ls(argv[1], argv[2]);
        else if (strcmp(argv[0], "stat") == 0 && argc >= 3)
            cmd_stat(argv[1], argv[2]);
        else if (strcmp(argv[0], "df") == 0 && argc >= 2)
            cmd_df(argv[1]);
        else if (strcmp(argv[0], "get") == 0 && argc >= 4)
            cmd_get(argv[1], argv[2], argv[3]);
        else
            say("-err unknown or malformed command");
    }
    g_client = -1;
    close(client);
}

int main(int argc, char **argv)
{
    uint16_t port = FUJID_PORT;
    if (argc > 1)
        port = (uint16_t)atoi(argv[1]);
    if (argc > 2) {
        if (!freopen(argv[2], "a", stdout))
            fprintf(stderr, "fujinetd: cannot open log %s\n", argv[2]);
        else
            setvbuf(stdout, NULL, _IOLBF, 0);
    }
    if (argc > 3)
        g_registry = argv[3];

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) {
        fprintf(stderr, "fujinetd: socket failed\n");
        return 1;
    }
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(ls, 2) < 0) {
        fprintf(stderr, "fujinetd: cannot bind/listen on 127.0.0.1:%u\n", port);
        return 1;
    }
    printf("fujinetd: listening on 127.0.0.1:%u\n", port);

    for (;;) {
        int client = accept(ls, NULL, NULL);
        if (client < 0)
            continue;
        serve(client);
    }
}
