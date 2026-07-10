/*
 * fujinetd — the FujiNet/TNFS daemon.
 *
 *   fujinetd [port] [logfile] [registry.db] [cacheroot]   (16385, stdout, auto, /Cache)
 *
 * A small control server on 127.0.0.1 speaking a line protocol; the
 * desktop (and anything else — `nc 127.0.0.1 16385` works) drives TNFS
 * through it. The daemon owns a pool of live server sessions so repeated
 * requests reuse a mount instead of re-mounting per operation.
 * Multi-client: a poll loop serves several connections at once and
 * advances each long transfer/listing a few TNFS round-trips per turn,
 * so a slow download never blocks another client's commands.
 *
 * Protocol (one command per line; replies start '+' ok / '-' error):
 *   ping                                  -> +pong
 *   servers                               -> +ok, then per registry row:
 *        "<id> <udp|tcp|auto> <host>:<port> <path> <displayName>", then "."
 *   ls   <server> <path>
 *        -> +ok, then one entry per line: "d 0 <name>" | "f <size> <name>",
 *           terminated by "."
 *   lsc  <server> <path>                  ls + netcache state column:
 *        -> "d 0 - <name>" | "f <size> <g|f|c|u> <name>" (ghost/fetching/
 *           cached/updateAvailable), terminated by "."
 *   stat <server> <path>                  -> +ok <d|f> <size> <mtime>
 *   df   <server>                         -> +ok <total-kb> <free-kb>
 *   get  <server> <remote> <local>        plain download to an explicit path
 *        -> "+progress <done> <total>" events, then "+ok <bytes>"
 *   fetch <server> <remote>               netcache download: mirrors to
 *        <cacheroot>/<server-id><remote>, upserts the fujiCache row
 *        (fetching -> cached, size/remoteMtime/fetchedAt)
 *        -> "+progress" events, then "+ok <bytes> <localpath>"
 *   add-server <host[:port]> <udp|tcp|auto> <mountpath> [displayName…]
 *        -> +ok <new id>
 *   del-server <id>                       -> +ok  (drops its cache rows too)
 *   quit                                  -> +bye (closes the connection)
 *
 * Arguments containing spaces are quoted: "like this" (or <like this>).
 *
 * <server> is a registry id / displayName / host from the `fujinet` table
 * (which supplies port + transport), or a literal
 * "[udp://|tcp://]host[:port]" for unregistered servers (fetch/lsc state
 * need a registry-backed server — the cache is keyed by row id).
 *
 * Portable: builds for the host (Makefile here) and for XTOS (loader/
 * Makefile, posix/net shims + libc.so; SQLite over the xt VFS). Single-
 * threaded; concurrency comes from the poll loop, never threads.
 * Kill/restart is always safe: sessions are disposable and the server
 * side times them out.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sqlite3.h>

#include <fujinet/tnfs.h>

#define FUJID_PORT     16385
#define MAX_SESSIONS   8
#define MAX_CLIENTS    4
#define LINE_MAX_LEN   768

/* Pump pacing: an op keeps issuing TNFS round-trips until its turn has
 * burned this much wall time, then yields the loop. Time (not chunk
 * count) is the budget so a fast server streams hundreds of chunks per
 * turn while a lossy one yields after a single retry window; a bystander
 * client's command stalls at most one turn + one in-flight retry. */
#define OP_TURN_MS         100
#define XFER_TURN_CHUNKS   256  /* hard cap per turn: 128 KB */
#define LIST_TURN_ENTRIES  64   /* hard cap per turn */

/* registry (SQLite) with the fujinet/fuji* tables; optional — an absent
 * registry just disables servers/name-resolution/netcache. Writes (the
 * daemon owns add/del-server and all fujiCache updates, per the design
 * doc) need rw=1; the qemu romfs fixture is read-only, so netcache state
 * silently no-ops there. */
static const char *g_registry;      /* argv override */
static const char *g_cacheroot = "/Cache";

static sqlite3 *reg_open(int rw)
{
    static const char *candidates[] =
        { NULL /* g_registry */, "/OS/var/registry.db",
          "/System/test/Registry.db" };    /* qemu romfs fixture */
    sqlite3 *db;
    candidates[0] = g_registry;
    for (int i = 0; i < 3; i++) {
        if (!candidates[i])
            continue;
        if (sqlite3_open_v2(candidates[i], &db,
                rw ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, NULL)
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
    int busy;           /* held by an active op — one command in flight per
                           session is a protocol rule, so never share it */
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
   Returns 1 and fills host/port/transport (+ the row id, for the cache
   key) on a hit. */
static int registry_server(const char *spec, char *host, size_t cap,
                           uint16_t *port, int *transport, int *out_id)
{
    sqlite3 *db = reg_open(0);
    if (!db)
        return 0;

    int all_digits = *spec != '\0';
    for (const char *p = spec; *p; p++)
        if (!isdigit((unsigned char)*p))
            all_digits = 0;

    const char *sql = all_digits
        ? "SELECT host,port,transport,id FROM fujinet WHERE id=?1"
        : "SELECT host,port,transport,id FROM fujinet "
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
            if (out_id)
                *out_id = sqlite3_column_int(st, 3);
            hit = 1;
        }
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
    return hit;
}

/* Busy sessions are invisible here (no sharing, no LRU eviction): a second
   request for a server whose session is mid-op gets a second session. */
static pool_entry *session_for(const char *spec, int *out_rc)
{
    char host[96];
    uint16_t port;
    int transport;
    if (!registry_server(spec, host, sizeof host, &port, &transport, NULL))
        parse_hostspec(spec, host, sizeof host, &port, &transport);

    pool_entry *victim = NULL;
    for (int i = 0; i < MAX_SESSIONS; i++) {
        pool_entry *e = &g_pool[i];
        if (e->busy)
            continue;
        if (e->live && e->port == port && e->transport == transport &&
            strcmp(e->host, host) == 0) {
            e->lastuse = ++g_tick;
            *out_rc = TNFS_OK;
            return e;
        }
        if (!victim || (victim->live && (!e->live || e->lastuse < victim->lastuse)))
            victim = e;
    }
    if (!victim) {          /* whole pool op-held (can't happen: 2x client cap) */
        *out_rc = TNFS_ERR_ARGS;
        return NULL;
    }

    if (victim->live) {
        tnfs_disconnect(&victim->s);
        victim->live = 0;
    }
    int rc = tnfs_connect(&victim->s, host, port, transport, "/");
    *out_rc = rc;
    if (rc != TNFS_OK)
        return NULL;
    /* pump pacing: shorter per-attempt timeout, more retries — the same
       overall patience (~12 s), but a lost datagram stalls the loop 250 ms
       instead of a full second (a server-announced min_retry still wins) */
    victim->s.timeout_ms = 250;
    victim->s.retries = 8;
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

typedef struct {
    char buf[1024];
    size_t len;
} line_reader;

enum { OP_IDLE = 0, OP_XFER, OP_LIST };

/* One connected control client. `op` is its resumable command in flight
   (get/fetch/ls/lsc): started by the dispatcher, advanced a turn at a time
   by the main loop. Later pipelined commands wait in the line_reader. */
typedef struct {
    int fd;                     /* -1 = free slot */
    int dead;                   /* hung up (recv EOF / failed send): the loop
                                   reaps it and aborts its op with cleanup */
    line_reader r;
    struct {
        int kind;               /* OP_IDLE / OP_XFER / OP_LIST */
        pool_entry *sess;       /* the busy-held session */
        /* get/fetch */
        uint8_t rfd;            /* remote file handle */
        FILE *out;              /* -> part */
        char local[LINE_MAX_LEN];
        char part[LINE_MAX_LEN + 8];
        char remote[LINE_MAX_LEN];      /* fetch: the fujiCache key */
        uint32_t total, done, last;     /* last = previous +progress mark */
        int fetch;              /* netcache fetch vs plain get */
        int server_id;
        uint32_t r_size, r_mtime;       /* remote stat for the cache stamp */
        /* ls/lsc */
        uint8_t dh;             /* remote dir handle */
        int withstate;
        sqlite3 *db;            /* lsc: cache-state lookups */
        char path[LINE_MAX_LEN];
    } op;
} client;

static client g_clients[MAX_CLIENTS];

static void say(client *c, const char *fmt, ...)
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
    /* a failed send means the client closed on us (SIGPIPE is ignored in
       main); flag it so its op aborts instead of streaming to a dead
       socket for minutes */
    if (send(c->fd, line, (size_t)n + 1, 0) != (ssize_t)(n + 1))
        c->dead = 1;
}

/* one buffered \n-terminated line out of the reader; 1 = got one, 0 = none */
static int next_line(line_reader *r, char *out, size_t cap)
{
    char *nl = memchr(r->buf, '\n', r->len);
    if (!nl)
        return 0;
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
    return 1;
}

/* poll said readable: pull one recv() into the buffer. -1 = hangup/error,
   or a runaway line (full buffer without a newline). */
static int pump_input(client *c)
{
    if (c->r.len == sizeof c->r.buf)    /* full: parked commands, or runaway */
        return memchr(c->r.buf, '\n', c->r.len) ? 0 : -1;
    ssize_t k = recv(c->fd, c->r.buf + c->r.len, sizeof c->r.buf - c->r.len, 0);
    if (k <= 0)
        return -1;
    c->r.len += (size_t)k;
    return 0;
}

/* ------------------------------------------------------------- commands */

static void cmd_servers(client *c)
{
    sqlite3 *db = reg_open(0);
    if (!db) {
        say(c, "-err no registry");
        return;
    }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT f.id, t.type, f.host, f.port, f.path,"
            " COALESCE(NULLIF(f.displayName,''), f.host)"
            " FROM fujinet f JOIN fujiTransport t ON t.id = f.transport"
            " ORDER BY f.id", -1, &st, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        say(c, "-err registry query failed");
        return;
    }
    say(c, "+ok");
    while (sqlite3_step(st) == SQLITE_ROW)
        say(c, "%d %s %s:%d %s %s",
            sqlite3_column_int(st, 0), sqlite3_column_text(st, 1),
            sqlite3_column_text(st, 2), sqlite3_column_int(st, 3),
            sqlite3_column_text(st, 4), sqlite3_column_text(st, 5));
    sqlite3_finalize(st);
    sqlite3_close(db);
    say(c, ".");
}

/* ---- netcache: the fujiCache table + the /Cache mirror ------------------ */

#define CS_NONE 0   /* no row: uncached -> ghost */
#define CS_FETCHING 1
#define CS_CACHED 2
#define CS_UPDATE 3

static int cache_state(sqlite3 *db, int server_id, const char *remote)
{
    if (!db)
        return CS_NONE;
    sqlite3_stmt *st = NULL;
    int state = CS_NONE;
    if (sqlite3_prepare_v2(db,
            "SELECT state FROM fujiCache WHERE server=?1 AND remotePath=?2",
            -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, server_id);
        sqlite3_bind_text(st, 2, remote, -1, SQLITE_STATIC);
        if (sqlite3_step(st) == SQLITE_ROW)
            state = sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    return state;
}

static void cache_upsert(int server_id, const char *remote, int state,
                         uint32_t size, uint32_t mtime)
{
    sqlite3 *db = reg_open(1);
    if (!db)
        return;                     /* read-only registry: state is best-effort */
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO fujiCache (server,remotePath,state,size,remoteMtime,fetchedAt)"
            " VALUES (?1,?2,?3,?4,?5,?6)"
            " ON CONFLICT(server,remotePath) DO UPDATE SET"
            " state=?3, size=?4, remoteMtime=?5, fetchedAt=?6",
            -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, server_id);
        sqlite3_bind_text(st, 2, remote, -1, SQLITE_STATIC);
        sqlite3_bind_int(st, 3, state);
        sqlite3_bind_int64(st, 4, (sqlite3_int64)size);
        sqlite3_bind_int64(st, 5, (sqlite3_int64)mtime);
        sqlite3_bind_int64(st, 6, (sqlite3_int64)time(NULL));
        sqlite3_step(st);
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
}

static void cache_drop(int server_id, const char *remote)
{
    sqlite3 *db = reg_open(1);
    if (!db)
        return;
    sqlite3_stmt *st = NULL;
    const char *sql = remote
        ? "DELETE FROM fujiCache WHERE server=?1 AND remotePath=?2"
        : "DELETE FROM fujiCache WHERE server=?1";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, server_id);
        if (remote)
            sqlite3_bind_text(st, 2, remote, -1, SQLITE_STATIC);
        sqlite3_step(st);
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
}

/* mkdir -p for the parent directories of `path` (below the cache root) */
static void mkdir_parents(char *path)
{
    for (char *p = path + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        mkdir(path, 0755);          /* EEXIST is fine */
        *p = '/';
    }
}

/* ----------------------------------------------------------- active ops */

static long long now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* release the op's session hold and go idle */
static void op_finish(client *c)
{
    if (c->op.sess)
        c->op.sess->busy = 0;
    memset(&c->op, 0, sizeof c->op);        /* kind = OP_IDLE */
}

/* the client hung up mid-op: same cleanup as the error paths, no replies */
static void op_abort(client *c)
{
    pool_entry *e = c->op.sess;
    if (c->op.kind == OP_XFER) {
        if (e->live)
            (void)tnfs_close(&e->s, c->op.rfd);
        fclose(c->op.out);
        remove(c->op.part);
        if (c->op.fetch)
            cache_drop(c->op.server_id, c->op.remote);
    } else if (c->op.kind == OP_LIST) {
        if (c->op.db)
            sqlite3_close(c->op.db);
        if (e->live)
            (void)tnfs_closedir(&e->s, c->op.dh);
    }
    op_finish(c);
}

/* +progress every >=16 KB and at completion (same cadence as before) */
static void xfer_progress(client *c, uint32_t total)
{
    if (c->op.done && c->op.done == c->op.last)
        return;
    if (c->op.done - c->op.last >= 16384 || c->op.done == total) {
        c->op.last = c->op.done;
        say(c, "+progress %u %u", c->op.done, total);
    }
}

/* transfer failed: cleanup exactly as the old one-shot path did */
static void xfer_fail(client *c, int rc)
{
    pool_entry *e = c->op.sess;
    if (rc != TNFS_ERR_TIMEOUT && rc != TNFS_ERR_TRANSPORT)
        (void)tnfs_close(&e->s, c->op.rfd);    /* dead session: don't burn retries */
    fclose(c->op.out);
    session_check(e, rc);
    remove(c->op.part);
    if (c->op.fetch)
        cache_drop(c->op.server_id, c->op.remote);
    say(c, "-err %s: %s", c->op.fetch ? "fetch" : "get", tnfs_strerror(rc));
    op_finish(c);
}

/* advance a get/fetch by one time-budgeted turn of TNFS reads */
static void xfer_turn(client *c)
{
    pool_entry *e = c->op.sess;
    uint8_t buf[TNFS_IO_CHUNK];
    long long t0 = now_ms();

    for (int i = 0; i < XFER_TURN_CHUNKS && now_ms() - t0 < OP_TURN_MS; i++) {
        uint16_t got = 0;
        int rc = tnfs_read(&e->s, c->op.rfd, buf, sizeof buf, &got);
        if (rc == TNFS_OK && got && fwrite(buf, 1, got, c->op.out) != got)
            rc = TNFS_ERR_LOCAL_IO;
        if (rc == TNFS_OK) {
            c->op.done += got;
            xfer_progress(c, c->op.total);
            if (c->dead)
                return;                     /* reaped (aborted) by the loop */
            continue;
        }
        if (rc != TNFS_EOF) {
            xfer_fail(c, rc);
            return;
        }
        /* EOF: finish up — close, final progress, rename into place */
        (void)tnfs_close(&e->s, c->op.rfd);
        xfer_progress(c, c->op.total ? c->op.total : c->op.done);
        fclose(c->op.out);
        if (rename(c->op.part, c->op.local) != 0) {
            remove(c->op.part);
            if (c->op.fetch)
                cache_drop(c->op.server_id, c->op.remote);
            say(c, "-err rename to %s failed", c->op.local);
        } else if (c->op.fetch) {
            cache_upsert(c->op.server_id, c->op.remote, CS_CACHED,
                         c->op.r_size, c->op.r_mtime);
            say(c, "+ok %u %s", c->op.done, c->op.local);
        } else {
            say(c, "+ok %u", c->op.done);
        }
        op_finish(c);
        return;
    }
}

/* advance an ls/lsc by one time-budgeted turn of readdir+stat pairs */
static void list_turn(client *c)
{
    pool_entry *e = c->op.sess;
    static const char statechar[] = { 'g', 'f', 'c', 'u' };
    char name[512], full[1024];
    long long t0 = now_ms();

    for (int i = 0; i < LIST_TURN_ENTRIES && now_ms() - t0 < OP_TURN_MS; i++) {
        int rc = tnfs_readdir(&e->s, c->op.dh, name, sizeof name);
        if (rc != TNFS_OK) {                /* EOF (or error): end of listing */
            if (c->op.db)
                sqlite3_close(c->op.db);
            c->op.db = NULL;
            if (rc != TNFS_ERR_TIMEOUT && rc != TNFS_ERR_TRANSPORT)
                (void)tnfs_closedir(&e->s, c->op.dh);
            session_check(e, rc == TNFS_EOF ? TNFS_OK : rc);
            say(c, ".");
            op_finish(c);
            return;
        }
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;
        tnfs_stat_t st;
        int isdir = 0;
        uint32_t size = 0;
        snprintf(full, sizeof full, "%s/%s",
                 strcmp(c->op.path, "/") == 0 ? "" : c->op.path, name);
        if (tnfs_stat(&e->s, full, &st) == TNFS_OK) {
            isdir = TNFS_S_ISDIR(st.mode);
            size = st.size;
        }
        if (!c->op.withstate) {
            say(c, "%c %u %s", isdir ? 'd' : 'f', size, name);
        } else if (isdir) {
            say(c, "d %u - %s", size, name);
        } else {
            int cs = c->op.server_id
                   ? cache_state(c->op.db, c->op.server_id, full) : CS_NONE;
            say(c, "f %u %c %s", size, statechar[cs & 3], name);
        }
        if (c->dead)
            return;
    }
}

/* start a listing: mount + opendir (+ lsc registry lookups), then hand the
   entry loop to the pump */
static void cmd_ls(client *c, const char *spec, const char *path, int withstate)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say(c, "-err mount: %s", tnfs_strerror(rc));
        return;
    }

    uint8_t handle;
    rc = tnfs_opendir(&e->s, path, &handle);
    if (rc != TNFS_OK) {
        session_check(e, rc);
        say(c, "-err opendir: %s", tnfs_strerror(rc));
        return;
    }
    /* lsc: annotate each file with its fujiCache state (needs a
       registry-backed server for the cache key) */
    int server_id = 0;
    sqlite3 *db = NULL;
    if (withstate) {
        char h[96]; uint16_t p16; int tr;
        if (registry_server(spec, h, sizeof h, &p16, &tr, &server_id))
            db = reg_open(0);
    }
    say(c, "+ok");

    c->op.kind = OP_LIST;
    c->op.sess = e;
    e->busy = 1;
    c->op.dh = handle;
    c->op.withstate = withstate;
    c->op.server_id = server_id;
    c->op.db = db;
    snprintf(c->op.path, sizeof c->op.path, "%s", path);
}

static void cmd_stat(client *c, const char *spec, const char *path)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say(c, "-err mount: %s", tnfs_strerror(rc));
        return;
    }
    tnfs_stat_t st;
    rc = tnfs_stat(&e->s, path, &st);
    session_check(e, rc);
    if (rc != TNFS_OK)
        say(c, "-err stat: %s", tnfs_strerror(rc));
    else
        say(c, "+ok %c %u %u", TNFS_S_ISDIR(st.mode) ? 'd' : 'f',
            st.size, st.mtime);
}

static void cmd_df(client *c, const char *spec)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say(c, "-err mount: %s", tnfs_strerror(rc));
        return;
    }
    uint32_t total = 0, freekb = 0;
    rc = tnfs_size(&e->s, &total);
    if (rc == TNFS_OK)
        rc = tnfs_free(&e->s, &freekb);
    session_check(e, rc);
    if (rc != TNFS_OK)
        say(c, "-err df: %s", tnfs_strerror(rc));
    else
        say(c, "+ok %u %u", total, freekb);
}

static void cmd_add_server(client *c, int argc, char **argv)
{
    /* add-server <host[:port]> <udp|tcp|auto> <mountpath> [displayName…] */
    sqlite3 *db = reg_open(1);
    if (!db) {
        say(c, "-err no writable registry");
        return;
    }
    char host[96];
    uint16_t port;
    int transport = TNFS_T_AUTO;
    parse_hostspec(argv[1], host, sizeof host, &port, &transport);
    if (strcmp(argv[2], "udp") == 0) transport = TNFS_T_UDP;
    else if (strcmp(argv[2], "tcp") == 0) transport = TNFS_T_TCP;

    char name[128] = "";
    for (int i = 4; i < argc; i++) {
        if (i > 4)
            strncat(name, " ", sizeof name - strlen(name) - 1);
        strncat(name, argv[i], sizeof name - strlen(name) - 1);
    }

    sqlite3_stmt *st = NULL;
    int ok = 0;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO fujinet (displayName,host,port,transport,path)"
            " VALUES (NULLIF(?1,''),?2,?3,?4,?5)", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, name, -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 2, host, -1, SQLITE_STATIC);
        sqlite3_bind_int(st, 3, port);
        sqlite3_bind_int(st, 4, transport);
        sqlite3_bind_text(st, 5, argv[3], -1, SQLITE_STATIC);
        ok = sqlite3_step(st) == SQLITE_DONE;
    }
    sqlite3_finalize(st);
    if (ok)
        say(c, "+ok %d", (int)sqlite3_last_insert_rowid(db));
    else
        say(c, "-err insert failed");
    sqlite3_close(db);
}

static void cmd_del_server(client *c, const char *idstr)
{
    sqlite3 *db = reg_open(1);
    if (!db) {
        say(c, "-err no writable registry");
        return;
    }
    int id = atoi(idstr);
    sqlite3_stmt *st = NULL;
    int ok = 0;
    if (sqlite3_prepare_v2(db, "DELETE FROM fujinet WHERE id=?1",
                           -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, id);
        ok = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) > 0;
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
    if (!ok) {
        say(c, "-err no such server");
        return;
    }
    cache_drop(id, NULL);           /* rows only; /Cache files stay until Flush */
    say(c, "+ok");
}

/* start a transfer: open the remote file and the local .part, then hand the
   chunk loop to the pump. `remote` is the fujiCache key for fetch (0 id =
   plain get). */
static void xfer_start(client *c, pool_entry *e, const char *remote,
                       const char *local, int fetch, int server_id,
                       uint32_t size, uint32_t mtime)
{
    char part[LINE_MAX_LEN + 8];
    snprintf(part, sizeof part, "%s.part", local);
    FILE *out = fopen(part, "wb");
    if (!out) {
        say(c, "-err cannot write %s", part);
        return;
    }
    if (fetch)
        cache_upsert(server_id, remote, CS_FETCHING, size, mtime);

    uint8_t rfd;
    int rc = tnfs_open(&e->s, remote, TNFS_O_RDONLY, 0, &rfd);
    if (rc != TNFS_OK) {
        fclose(out);
        remove(part);
        if (fetch)
            cache_drop(server_id, remote);
        session_check(e, rc);
        say(c, "-err %s: %s", fetch ? "fetch" : "get", tnfs_strerror(rc));
        return;
    }

    c->op.kind = OP_XFER;
    c->op.sess = e;
    e->busy = 1;
    c->op.rfd = rfd;
    c->op.out = out;
    c->op.total = size;
    c->op.done = c->op.last = 0;
    c->op.fetch = fetch;
    c->op.server_id = server_id;
    c->op.r_size = size;
    c->op.r_mtime = mtime;
    snprintf(c->op.local, sizeof c->op.local, "%s", local);
    snprintf(c->op.part, sizeof c->op.part, "%s", part);
    snprintf(c->op.remote, sizeof c->op.remote, "%s", remote);
}

static void cmd_get(client *c, const char *spec, const char *remote,
                    const char *local)
{
    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say(c, "-err mount: %s", tnfs_strerror(rc));
        return;
    }
    /* size is advisory (progress total) — a failed stat still transfers */
    tnfs_stat_t st;
    uint32_t total = 0;
    if (tnfs_stat(&e->s, remote, &st) == TNFS_OK)
        total = st.size;
    xfer_start(c, e, remote, local, 0, 0, total, 0);
}

/* netcache fetch: download into the /Cache mirror + track it in fujiCache */
static void cmd_fetch(client *c, const char *spec, const char *remote)
{
    char host[96];
    uint16_t port;
    int transport, server_id = 0;
    if (!registry_server(spec, host, sizeof host, &port, &transport,
                         &server_id) || !server_id) {
        say(c, "-err fetch needs a registry server (use add-server first)");
        return;
    }
    if (remote[0] != '/') {
        say(c, "-err remote path must be absolute");
        return;
    }

    int rc;
    pool_entry *e = session_for(spec, &rc);
    if (!e) {
        say(c, "-err mount: %s", tnfs_strerror(rc));
        return;
    }

    /* remote size/mtime up front: progress total + the fujiCache stamp */
    tnfs_stat_t st;
    if ((rc = tnfs_stat(&e->s, remote, &st)) != TNFS_OK) {
        session_check(e, rc);
        say(c, "-err stat: %s", tnfs_strerror(rc));
        return;
    }

    char local[LINE_MAX_LEN];
    snprintf(local, sizeof local, "%s/%d%s", g_cacheroot, server_id, remote);
    mkdir_parents(local);
    xfer_start(c, e, remote, local, 1, server_id, st.size, st.mtime);
}

/* --------------------------------------------------------------- server */

/* whitespace split with quoting: "two words" or <two words> arrive as one
   argument (paths on public TNFS servers really do contain spaces) */
static int split(char *line, char *argv[], int max)
{
    int argc = 0;
    char *p = line;
    while (*p && argc < max) {
        while (*p == ' ' || *p == '\t')
            p++;
        if (!*p)
            break;
        char close = 0;
        if (*p == '"')      { close = '"'; p++; }
        else if (*p == '<') { close = '>'; p++; }
        argv[argc++] = p;
        if (close) {
            while (*p && *p != close)
                p++;
        } else {
            while (*p && *p != ' ' && *p != '\t')
                p++;
        }
        if (*p)
            *p++ = '\0';
    }
    return argc;
}

static void dispatch(client *c, char *line)
{
    char *argv[8];
    int argc = split(line, argv, 8);
    if (argc == 0)
        return;

    if (strcmp(argv[0], "ping") == 0)
        say(c, "+pong");
    else if (strcmp(argv[0], "servers") == 0)
        cmd_servers(c);
    else if (strcmp(argv[0], "quit") == 0) {
        say(c, "+bye");
        c->dead = 1;                /* reaped (and closed) by the loop */
    }
    else if (strcmp(argv[0], "ls") == 0 && argc >= 3)
        cmd_ls(c, argv[1], argv[2], 0);
    else if (strcmp(argv[0], "lsc") == 0 && argc >= 3)
        cmd_ls(c, argv[1], argv[2], 1);
    else if (strcmp(argv[0], "fetch") == 0 && argc >= 3)
        cmd_fetch(c, argv[1], argv[2]);
    else if (strcmp(argv[0], "add-server") == 0 && argc >= 4)
        cmd_add_server(c, argc, argv);
    else if (strcmp(argv[0], "del-server") == 0 && argc >= 2)
        cmd_del_server(c, argv[1]);
    else if (strcmp(argv[0], "stat") == 0 && argc >= 3)
        cmd_stat(c, argv[1], argv[2]);
    else if (strcmp(argv[0], "df") == 0 && argc >= 2)
        cmd_df(c, argv[1]);
    else if (strcmp(argv[0], "get") == 0 && argc >= 4)
        cmd_get(c, argv[1], argv[2], argv[3]);
    else
        say(c, "-err unknown or malformed command");
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
    if (argc > 4)
        g_cacheroot = argv[4];

    signal(SIGPIPE, SIG_IGN);   /* dead client -> send() -1/EPIPE, not death */

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
    if (bind(ls, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(ls, 8) < 0) {
        fprintf(stderr, "fujinetd: cannot bind/listen on 127.0.0.1:%u\n", port);
        return 1;
    }
    fcntl(ls, F_SETFL, O_NONBLOCK);     /* accept never blocks the loop */
    printf("fujinetd: listening on 127.0.0.1:%u\n", port);

    for (int i = 0; i < MAX_CLIENTS; i++)
        g_clients[i].fd = -1;

    for (;;) {
        struct pollfd pfd[1 + MAX_CLIENTS];
        client *who[1 + MAX_CLIENTS];
        int n = 0, work = 0, slots = 0;

        for (int i = 0; i < MAX_CLIENTS; i++)
            slots += g_clients[i].fd < 0;
        if (slots) {                /* full house: new connections wait in the
                                       listen backlog until a slot frees */
            pfd[n].fd = ls;
            pfd[n].events = POLLIN;
            pfd[n].revents = 0;
            who[n++] = NULL;
        }
        for (int i = 0; i < MAX_CLIENTS; i++) {
            client *c = &g_clients[i];
            if (c->fd < 0)
                continue;
            pfd[n].fd = c->fd;
            pfd[n].events = POLLIN; /* commands, pipelined quit, hangup */
            pfd[n].revents = 0;
            who[n++] = c;
            /* active op, or parked lines to dispatch: don't sleep */
            work += c->op.kind != OP_IDLE ||
                    (!c->dead && memchr(c->r.buf, '\n', c->r.len) != NULL);
        }

        /* active ops pace the loop (each turn blocks in its own TNFS RTTs);
           an idle daemon parks in poll and burns no CPU */
        if (poll(pfd, (nfds_t)n, work ? 0 : -1) < 0)
            continue;

        for (int i = 0; i < n; i++) {
            if (!(pfd[i].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;
            if (!who[i]) {          /* one accept per wake; poll re-fires */
                int fd = accept(ls, NULL, NULL);
                if (fd < 0)
                    continue;
                client *slot = NULL;
                for (int j = 0; j < MAX_CLIENTS && !slot; j++)
                    if (g_clients[j].fd < 0)
                        slot = &g_clients[j];
                if (!slot) {        /* raced full: back to the backlog rule */
                    close(fd);
                    continue;
                }
                memset(slot, 0, sizeof *slot);
                slot->fd = fd;
                /* the first command usually rode in with the connect: pump
                   it now so it dispatches this turn, not one op-turn later */
                struct pollfd nb = { .fd = fd, .events = POLLIN, .revents = 0 };
                if (poll(&nb, 1, 0) > 0 && pump_input(slot) < 0)
                    slot->dead = 1;
            } else if (pump_input(who[i]) < 0) {
                who[i]->dead = 1;
            }
        }

        /* dispatch buffered commands (held back while that client's own op
           is in flight — replies must not interleave) */
        char line[LINE_MAX_LEN];
        for (int i = 0; i < MAX_CLIENTS; i++) {
            client *c = &g_clients[i];
            if (c->fd < 0)
                continue;
            while (!c->dead && c->op.kind == OP_IDLE &&
                   next_line(&c->r, line, sizeof line))
                dispatch(c, line);
        }

        /* reap the dead before the turns: abort their op (cleanup, no
           replies) and free the slot — a quit'd client sees its close now,
           not one op-turn later. Deaths during a turn reap next loop. */
        for (int i = 0; i < MAX_CLIENTS; i++) {
            client *c = &g_clients[i];
            if (c->fd < 0 || !c->dead)
                continue;
            op_abort(c);
            close(c->fd);
            c->fd = -1;
        }

        /* one turn for every active op */
        for (int i = 0; i < MAX_CLIENTS; i++) {
            client *c = &g_clients[i];
            if (c->fd < 0 || c->dead)
                continue;
            if (c->op.kind == OP_XFER)
                xfer_turn(c);
            else if (c->op.kind == OP_LIST)
                list_turn(c);
        }
    }
}
