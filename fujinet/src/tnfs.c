/*
 * libfujinet — TNFS protocol core.
 *
 * Transport-agnostic: everything goes through the tnfs_transport in the
 * session. No OS dependencies beyond <string.h>, so the same object
 * builds for macOS, Linux, and XTOS.
 */

#include <string.h>
#include <fujinet/tnfs.h>

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, (uint16_t)v); put16(p + 2, (uint16_t)(v >> 16)); }
static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p) | ((uint32_t)get16(p + 2) << 16); }

/*
 * Expected total length of the (possibly partial) stream message at the
 * start of buf, derived from its own header cmd + status byte. Returns
 * 0 when more bytes are needed to decide. Only used for stream (TCP)
 * transports — tnfsd writes each reply with a single send(), but the
 * segments can still arrive split.
 */
static size_t frame_need(const uint8_t *buf, size_t len)
{
    const size_t base = TNFS_HDR_SIZE + 1;      /* header + status */
    if (len < base)
        return 0;
    if (buf[4] != TNFS_OK)                      /* error/EOF: status only */
        return base;
    switch (buf[3]) {
    case TNFS_CMD_MOUNT:
        return base + 4;                        /* version + min-retry */
    case TNFS_CMD_OPENDIR:
    case TNFS_CMD_OPEN:
        return base + 1;                        /* handle / fd */
    case TNFS_CMD_READDIR: {                    /* NUL-terminated name */
        for (size_t i = base; i < len; i++)
            if (!buf[i])
                return i + 1;
        return 0;
    }
    case TNFS_CMD_READ:                         /* len16 + data */
        if (len < base + 2)
            return 0;
        return base + 2 + get16(buf + base);
    case TNFS_CMD_WRITE:
        return base + 2;                        /* len16 written */
    case TNFS_CMD_LSEEK:
        return base + 4;                        /* new position (v1.2) */
    case TNFS_CMD_STAT:
        /* fixed 22 bytes; the spec's trailing uid/gid strings are
           aspirational — tnfsd (all deployed versions) never sends them */
        return base + 22;
    case TNFS_CMD_SIZE:
    case TNFS_CMD_FREE:
        return base + 4;
    default:
        return base;
    }
}

/*
 * Receive one whole TNFS message into rsp. Datagram transports get it
 * in a single recv; stream transports reassemble via the session's
 * sbuf (which also carries leftover bytes — e.g. a late duplicate —
 * across calls). Returns message length, or TNFS_ERR_*.
 */
static int recv_message(tnfs_session *s, uint8_t *rsp, size_t cap, int timeout)
{
    if (!s->io.stream)
        return s->io.recv(s->io.ctx, rsp, cap, timeout);

    for (;;) {
        size_t need = frame_need(s->sbuf, s->slen);
        if (need > sizeof s->sbuf || need > cap)
            return TNFS_ERR_PROTOCOL;
        if (need && s->slen >= need) {
            memcpy(rsp, s->sbuf, need);
            s->slen -= need;
            memmove(s->sbuf, s->sbuf + need, s->slen);
            return (int)need;
        }
        if (s->slen == sizeof s->sbuf)
            return TNFS_ERR_PROTOCOL;           /* full buffer, no message */
        int n = s->io.recv(s->io.ctx, s->sbuf + s->slen,
                           sizeof s->sbuf - s->slen, timeout);
        if (n <= 0)
            return n == 0 ? TNFS_ERR_TRANSPORT : n;
        s->slen += (size_t)n;
    }
}

/*
 * One command round-trip: build header+payload, send, wait for the
 * matching reply (same seq + cmd, same session id except during MOUNT),
 * retrying the identical message on timeout (the server dedupes by
 * sequence number on both transports). Returns the TNFS status byte,
 * or a negative TNFS_ERR_*. Reply payload (bytes after the status
 * byte) is copied to `reply`; its full length goes to *rlen.
 */
static int xchg(tnfs_session *s, uint8_t cmd,
                const uint8_t *payload, size_t plen,
                uint8_t *reply, size_t cap, size_t *rlen,
                uint16_t *out_sid)
{
    uint8_t pkt[TNFS_MAX_PACKET];
    uint8_t rsp[TNFS_MAX_PACKET];

    if (plen + TNFS_HDR_SIZE > sizeof pkt)
        return TNFS_ERR_ARGS;
    if (!s->io.send || !s->io.recv)
        return TNFS_ERR_ARGS;

    uint8_t seq = s->seq++;
    put16(pkt, s->sid);
    pkt[2] = seq;
    pkt[3] = cmd;
    if (plen)
        memcpy(pkt + TNFS_HDR_SIZE, payload, plen);

    int timeout = s->timeout_ms > 0 ? s->timeout_ms : 1000;
    if (s->min_retry_ms > timeout)
        timeout = s->min_retry_ms;
    int attempts = s->retries > 0 ? s->retries : 5;

    for (int a = 0; a < attempts; a++) {
        if (s->io.send(s->io.ctx, pkt, plen + TNFS_HDR_SIZE) < 0)
            return TNFS_ERR_TRANSPORT;

        for (;;) {
            int n = recv_message(s, rsp, sizeof rsp, timeout);
            if (n == TNFS_ERR_TIMEOUT)
                break;              /* resend */
            if (n < 0)
                return n;
            if (n < TNFS_HDR_SIZE + 1)
                continue;           /* runt datagram */
            if (rsp[2] != seq || rsp[3] != cmd)
                continue;           /* stale reply from an earlier retry */
            if (cmd != TNFS_CMD_MOUNT && get16(rsp) != s->sid)
                continue;

            int status = rsp[4];
            if (status == TNFS_EAGAIN) {
                /* Server busy: honour its suggested delay (bytes 5-6),
                   then fall through to a resend. Waiting is done with a
                   throwaway recv so the core stays sleep()-free. */
                int delay = (n >= TNFS_HDR_SIZE + 3) ? get16(rsp + 5) : timeout;
                if (delay > 0)
                    (void)recv_message(s, rsp, sizeof rsp,
                                       delay > 2000 ? 2000 : delay);
                break;
            }

            if (out_sid)
                *out_sid = get16(rsp);
            size_t got = (size_t)n - (TNFS_HDR_SIZE + 1);
            if (rlen)
                *rlen = got;
            if (reply && cap) {
                if (got > cap)
                    got = cap;
                memcpy(reply, rsp + TNFS_HDR_SIZE + 1, got);
            }
            return status;
        }
        timeout += timeout / 2;     /* back off */
    }
    return TNFS_ERR_TIMEOUT;
}

/* payload helper: append a NUL-terminated string, bounds-checked */
static int put_str(uint8_t *buf, size_t cap, size_t *off, const char *str)
{
    size_t len = strlen(str) + 1;
    if (*off + len > cap)
        return -1;
    memcpy(buf + *off, str, len);
    *off += len;
    return 0;
}

/* the common "command takes just a path string" shape */
static int path_cmd(tnfs_session *s, uint8_t cmd, const char *path)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE];
    size_t off = 0;
    if (put_str(pl, sizeof pl, &off, path) < 0)
        return TNFS_ERR_ARGS;
    return xchg(s, cmd, pl, off, NULL, 0, NULL, NULL);
}

int tnfs_mount(tnfs_session *s, const tnfs_transport *io,
               const char *mountpath, const char *user, const char *pass)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE];
    uint8_t rp[8];
    size_t off = 2, rlen = 0;
    uint16_t sid = 0;

    int timeout = s->timeout_ms;
    int retries = s->retries;
    memset(s, 0, sizeof *s);
    s->timeout_ms = timeout;
    s->retries = retries;
    s->io = *io;

    put16(pl, TNFS_VERSION);
    if (put_str(pl, sizeof pl, &off, mountpath ? mountpath : "/") < 0 ||
        put_str(pl, sizeof pl, &off, user ? user : "") < 0 ||
        put_str(pl, sizeof pl, &off, pass ? pass : "") < 0)
        return TNFS_ERR_ARGS;

    int rc = xchg(s, TNFS_CMD_MOUNT, pl, off, rp, sizeof rp, &rlen, &sid);
    if (rc == TNFS_OK) {
        s->sid = sid;
        s->mounted = 1;
        if (rlen >= 2)
            s->server_version = get16(rp);
        if (rlen >= 4)
            s->min_retry_ms = get16(rp + 2);
    }
    return rc;
}

int tnfs_umount(tnfs_session *s)
{
    int rc = xchg(s, TNFS_CMD_UMOUNT, NULL, 0, NULL, 0, NULL, NULL);
    if (rc == TNFS_OK)
        s->mounted = 0;
    return rc;
}

void tnfs_disconnect(tnfs_session *s)
{
    if (s->mounted)
        (void)tnfs_umount(s);
    if (s->io.close)
        s->io.close(s->io.ctx);
    memset(&s->io, 0, sizeof s->io);
    s->mounted = 0;
}

int tnfs_opendir(tnfs_session *s, const char *path, uint8_t *out_handle)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE], rp[1];
    size_t off = 0, rlen = 0;
    if (put_str(pl, sizeof pl, &off, path) < 0)
        return TNFS_ERR_ARGS;
    int rc = xchg(s, TNFS_CMD_OPENDIR, pl, off, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 1)
            return TNFS_ERR_PROTOCOL;
        *out_handle = rp[0];
    }
    return rc;
}

int tnfs_readdir(tnfs_session *s, uint8_t handle, char *name, size_t cap)
{
    uint8_t rp[TNFS_MAX_PACKET];
    size_t rlen = 0;
    int rc = xchg(s, TNFS_CMD_READDIR, &handle, 1, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 1 || !name || !cap)
            return TNFS_ERR_PROTOCOL;
        size_t n = rlen < cap - 1 ? rlen : cap - 1;
        memcpy(name, rp, n);
        name[n] = '\0';
    }
    return rc;
}

int tnfs_closedir(tnfs_session *s, uint8_t handle)
{
    return xchg(s, TNFS_CMD_CLOSEDIR, &handle, 1, NULL, 0, NULL, NULL);
}

int tnfs_mkdir(tnfs_session *s, const char *path) { return path_cmd(s, TNFS_CMD_MKDIR, path); }
int tnfs_rmdir(tnfs_session *s, const char *path) { return path_cmd(s, TNFS_CMD_RMDIR, path); }
int tnfs_unlink(tnfs_session *s, const char *path) { return path_cmd(s, TNFS_CMD_UNLINK, path); }

int tnfs_open(tnfs_session *s, const char *path, uint16_t flags,
              uint16_t mode, uint8_t *out_fd)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE], rp[1];
    size_t off = 4, rlen = 0;
    put16(pl, flags);
    put16(pl + 2, mode);
    if (put_str(pl, sizeof pl, &off, path) < 0)
        return TNFS_ERR_ARGS;
    int rc = xchg(s, TNFS_CMD_OPEN, pl, off, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 1)
            return TNFS_ERR_PROTOCOL;
        *out_fd = rp[0];
    }
    return rc;
}

int tnfs_read(tnfs_session *s, uint8_t fd, void *buf, uint16_t want,
              uint16_t *out_got)
{
    uint8_t pl[3], rp[TNFS_IO_CHUNK + 2];
    size_t rlen = 0;

    if (want > TNFS_IO_CHUNK)
        want = TNFS_IO_CHUNK;
    pl[0] = fd;
    put16(pl + 1, want);
    if (out_got)
        *out_got = 0;

    int rc = xchg(s, TNFS_CMD_READ, pl, 3, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 2)
            return TNFS_ERR_PROTOCOL;
        uint16_t got = get16(rp);
        if (got > rlen - 2 || got > want)
            return TNFS_ERR_PROTOCOL;
        memcpy(buf, rp + 2, got);
        if (out_got)
            *out_got = got;
    }
    return rc;
}

int tnfs_write(tnfs_session *s, uint8_t fd, const void *buf, uint16_t len,
               uint16_t *out_put)
{
    uint8_t pl[TNFS_IO_CHUNK + 3], rp[2];
    size_t rlen = 0;

    if (len > TNFS_IO_CHUNK)
        len = TNFS_IO_CHUNK;
    pl[0] = fd;
    put16(pl + 1, len);
    memcpy(pl + 3, buf, len);
    if (out_put)
        *out_put = 0;

    int rc = xchg(s, TNFS_CMD_WRITE, pl, (size_t)len + 3, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 2)
            return TNFS_ERR_PROTOCOL;
        if (out_put)
            *out_put = get16(rp);
    }
    return rc;
}

int tnfs_lseek(tnfs_session *s, uint8_t fd, uint8_t whence, int32_t offset,
               uint32_t *out_pos)
{
    uint8_t pl[6], rp[4];
    size_t rlen = 0;
    pl[0] = fd;
    pl[1] = whence;
    put32(pl + 2, (uint32_t)offset);
    int rc = xchg(s, TNFS_CMD_LSEEK, pl, 6, rp, sizeof rp, &rlen, NULL);
    /* new-position field only exists on protocol > 1.0 servers */
    if (rc == TNFS_OK && out_pos && rlen >= 4)
        *out_pos = get32(rp);
    return rc;
}

int tnfs_close(tnfs_session *s, uint8_t fd)
{
    return xchg(s, TNFS_CMD_CLOSE, &fd, 1, NULL, 0, NULL, NULL);
}

int tnfs_stat(tnfs_session *s, const char *path, tnfs_stat_t *st)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE], rp[22];
    size_t off = 0, rlen = 0;
    if (put_str(pl, sizeof pl, &off, path) < 0)
        return TNFS_ERR_ARGS;
    int rc = xchg(s, TNFS_CMD_STAT, pl, off, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 22)
            return TNFS_ERR_PROTOCOL;
        st->mode  = get16(rp);
        st->uid   = get16(rp + 2);
        st->gid   = get16(rp + 4);
        st->size  = get32(rp + 6);
        st->atime = get32(rp + 10);
        st->mtime = get32(rp + 14);
        st->ctime = get32(rp + 18);
    }
    return rc;
}

int tnfs_rename(tnfs_session *s, const char *from, const char *to)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE];
    size_t off = 0;
    if (put_str(pl, sizeof pl, &off, from) < 0 ||
        put_str(pl, sizeof pl, &off, to) < 0)
        return TNFS_ERR_ARGS;
    return xchg(s, TNFS_CMD_RENAME, pl, off, NULL, 0, NULL, NULL);
}

int tnfs_chmod(tnfs_session *s, const char *path, uint16_t mode)
{
    uint8_t pl[TNFS_MAX_PACKET - TNFS_HDR_SIZE];
    size_t off = 2;
    put16(pl, mode);
    if (put_str(pl, sizeof pl, &off, path) < 0)
        return TNFS_ERR_ARGS;
    return xchg(s, TNFS_CMD_CHMOD, pl, off, NULL, 0, NULL, NULL);
}

static int info_cmd(tnfs_session *s, uint8_t cmd, uint32_t *out_kb)
{
    uint8_t rp[4];
    size_t rlen = 0;
    int rc = xchg(s, cmd, NULL, 0, rp, sizeof rp, &rlen, NULL);
    if (rc == TNFS_OK) {
        if (rlen < 4)
            return TNFS_ERR_PROTOCOL;
        *out_kb = get32(rp);
    }
    return rc;
}

int tnfs_size(tnfs_session *s, uint32_t *out_kb) { return info_cmd(s, TNFS_CMD_SIZE, out_kb); }
int tnfs_free(tnfs_session *s, uint32_t *out_kb) { return info_cmd(s, TNFS_CMD_FREE, out_kb); }

static int notify(tnfs_progress_cb progress, void *user,
                  uint32_t done, uint32_t total)
{
    if (progress && progress(user, done, total) != 0)
        return TNFS_ERR_ABORTED;
    return TNFS_OK;
}

int tnfs_download(tnfs_session *s, const char *path,
                  int (*sink)(void *user, const void *buf, size_t len),
                  void *sink_user,
                  tnfs_progress_cb progress, void *progress_user)
{
    uint8_t fd, buf[TNFS_IO_CHUNK];
    tnfs_stat_t st;
    uint32_t total = 0, done = 0;

    if (!sink)
        return TNFS_ERR_ARGS;
    if (tnfs_stat(s, path, &st) == TNFS_OK)
        total = st.size;

    int rc = tnfs_open(s, path, TNFS_O_RDONLY, 0, &fd);
    if (rc != TNFS_OK)
        return rc;

    for (;;) {
        uint16_t got = 0;
        rc = tnfs_read(s, fd, buf, sizeof buf, &got);
        if (rc == TNFS_EOF) {
            rc = TNFS_OK;
            break;
        }
        if (rc != TNFS_OK)
            break;
        if (got && sink(sink_user, buf, got) != 0) {
            rc = TNFS_ERR_LOCAL_IO;
            break;
        }
        done += got;
        rc = notify(progress, progress_user, done, total);
        if (rc != TNFS_OK)
            break;
    }
    (void)tnfs_close(s, fd);
    if (rc == TNFS_OK)
        rc = notify(progress, progress_user, done, total ? total : done);
    return rc;
}

int tnfs_upload(tnfs_session *s, const char *path, uint16_t mode,
                int (*source)(void *user, void *buf, size_t cap),
                void *source_user, uint32_t total,
                tnfs_progress_cb progress, void *progress_user)
{
    uint8_t fd, buf[TNFS_IO_CHUNK];
    uint32_t done = 0;

    if (!source)
        return TNFS_ERR_ARGS;

    int rc = tnfs_open(s, path, TNFS_O_WRONLY | TNFS_O_CREAT | TNFS_O_TRUNC,
                       mode ? mode : 0644, &fd);
    if (rc != TNFS_OK)
        return rc;

    for (;;) {
        int n = source(source_user, buf, sizeof buf);
        if (n == 0)
            break;
        if (n < 0) {
            rc = TNFS_ERR_LOCAL_IO;
            break;
        }
        uint16_t put = 0;
        rc = tnfs_write(s, fd, buf, (uint16_t)n, &put);
        if (rc != TNFS_OK)
            break;
        if (put != (uint16_t)n) {
            rc = TNFS_ERR_PROTOCOL;
            break;
        }
        done += put;
        rc = notify(progress, progress_user, done, total);
        if (rc != TNFS_OK)
            break;
    }
    (void)tnfs_close(s, fd);
    if (rc == TNFS_OK)
        rc = notify(progress, progress_user, done, total ? total : done);
    return rc;
}

const char *tnfs_strerror(int rc)
{
    switch (rc) {
    case TNFS_ERR_TIMEOUT:   return "timeout (no reply from server)";
    case TNFS_ERR_TRANSPORT: return "transport error";
    case TNFS_ERR_PROTOCOL:  return "malformed reply";
    case TNFS_ERR_ARGS:      return "bad arguments";
    case TNFS_ERR_ABORTED:   return "transfer cancelled";
    case TNFS_ERR_LOCAL_IO:  return "local read/write failed";
    case 0x00: return "success";
    case 0x01: return "operation not permitted";
    case 0x02: return "no such file or directory";
    case 0x03: return "I/O error";
    case 0x04: return "no such device or address";
    case 0x05: return "argument list too long";
    case 0x06: return "bad file number";
    case 0x07: return "try again";
    case 0x08: return "out of memory";
    case 0x09: return "permission denied";
    case 0x0A: return "device or resource busy";
    case 0x0B: return "file exists";
    case 0x0C: return "not a directory";
    case 0x0D: return "is a directory";
    case 0x0E: return "invalid argument";
    case 0x0F: return "file table overflow";
    case 0x10: return "too many open files";
    case 0x11: return "file too large";
    case 0x12: return "no space left on device";
    case 0x13: return "attempt to seek on a FIFO or pipe";
    case 0x14: return "read-only filesystem";
    case 0x15: return "filename too long";
    case 0x16: return "function not implemented";
    case 0x17: return "directory not empty";
    case 0x18: return "too many symbolic links";
    case 0x19: return "no data available";
    case 0x1A: return "out of streams resources";
    case 0x1B: return "protocol error";
    case 0x1C: return "file descriptor in bad state";
    case 0x1D: return "too many users";
    case 0x1E: return "no buffer space available";
    case 0x1F: return "operation already in progress";
    case 0x20: return "stale TNFS handle";
    case 0x21: return "end of file";
    case 0xFF: return "invalid TNFS handle";
    default:   return "unknown error";
    }
}
