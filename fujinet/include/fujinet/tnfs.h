/*
 * libfujinet — TNFS client
 *
 * Portable TNFS (Trivial Network File System) client core, per the
 * protocol spec in the Spectranet/FujiNet tnfs-protocol.md. The core is
 * transport-agnostic: callers supply a tnfs_transport (datagram send /
 * timed recv). A POSIX/BSD UDP transport is included for host builds
 * (macOS/Linux); the XTOS port swaps in one backed by the net_shim
 * socket API.
 *
 * Conventions:
 *  - All wire integers are little-endian.
 *  - API calls return a TNFS status byte (>= 0): TNFS_OK on success,
 *    TNFS_EOF at end-of-file/dir, other positive values per the spec's
 *    error table. Negative returns are local errors (timeout, transport,
 *    malformed reply) — see TNFS_ERR_*.
 */

#ifndef FUJINET_TNFS_H
#define FUJINET_TNFS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TNFS_PORT        16384
#define TNFS_HDR_SIZE    4
#define TNFS_MAX_PACKET  1024   /* rx/tx buffer; datagrams are <= ~532 bytes */
#define TNFS_IO_CHUNK    512    /* max data bytes per READ/WRITE */

/* Protocol version we announce in MOUNT: 1.2 (LSB=minor, MSB=major). */
#define TNFS_VERSION     0x0102

/* Command bytes */
enum {
    TNFS_CMD_MOUNT    = 0x00,
    TNFS_CMD_UMOUNT   = 0x01,
    TNFS_CMD_OPENDIR  = 0x10,
    TNFS_CMD_READDIR  = 0x11,
    TNFS_CMD_CLOSEDIR = 0x12,
    TNFS_CMD_MKDIR    = 0x13,
    TNFS_CMD_RMDIR    = 0x14,
    TNFS_CMD_READ     = 0x21,
    TNFS_CMD_WRITE    = 0x22,
    TNFS_CMD_CLOSE    = 0x23,
    TNFS_CMD_STAT     = 0x24,
    TNFS_CMD_LSEEK    = 0x25,
    TNFS_CMD_UNLINK   = 0x26,
    TNFS_CMD_CHMOD    = 0x27,
    TNFS_CMD_RENAME   = 0x28,
    TNFS_CMD_OPEN     = 0x29,
    TNFS_CMD_SIZE     = 0x30,
    TNFS_CMD_FREE     = 0x31,
};

/* Status codes (returned by API calls; per-spec error table) */
#define TNFS_OK          0x00
#define TNFS_EAGAIN      0x07
#define TNFS_ENOENT      0x02
#define TNFS_EOF         0x21

/* Local (non-protocol) errors — negative */
#define TNFS_ERR_TIMEOUT   (-1)   /* no valid reply within retries */
#define TNFS_ERR_TRANSPORT (-2)   /* send/recv failed */
#define TNFS_ERR_PROTOCOL  (-3)   /* reply too short / malformed */
#define TNFS_ERR_ARGS      (-4)   /* bad arguments / payload too large */
#define TNFS_ERR_ABORTED   (-5)   /* transfer cancelled by progress callback */
#define TNFS_ERR_LOCAL_IO  (-6)   /* sink/source callback failed */

/* Open flags (wire values per spec — not host O_*) */
#define TNFS_O_RDONLY    0x0001
#define TNFS_O_WRONLY    0x0002
#define TNFS_O_RDWR      0x0003
#define TNFS_O_APPEND    0x0008
#define TNFS_O_CREAT     0x0100
#define TNFS_O_TRUNC     0x0200
#define TNFS_O_EXCL      0x0400

/* lseek whence */
#define TNFS_SEEK_SET    0
#define TNFS_SEEK_CUR    1
#define TNFS_SEEK_END    2

/* File mode helpers (POSIX bits on the wire) */
#define TNFS_S_ISDIR(m)  (((m) & 0170000) == 0040000)
#define TNFS_S_ISREG(m)  (((m) & 0170000) == 0100000)

/*
 * Transport supplied by the platform layer.
 *  send: transmit one message (datagram) / the given bytes (stream);
 *        returns 0 on success, <0 on error.
 *  recv: wait up to timeout_ms; returns bytes received (one whole
 *        datagram, or whatever the stream delivered), TNFS_ERR_TIMEOUT
 *        on timeout, TNFS_ERR_TRANSPORT on error/close.
 *  close: release the transport (may be NULL).
 *  stream: 0 = datagram (UDP), 1 = byte stream (TCP). For streams the
 *        core reassembles TNFS messages from the byte flow itself.
 */
typedef struct tnfs_transport {
    int  (*send)(void *ctx, const void *buf, size_t len);
    int  (*recv)(void *ctx, void *buf, size_t cap, int timeout_ms);
    void (*close)(void *ctx);
    void *ctx;
    int  stream;
} tnfs_transport;

typedef struct tnfs_stat_s {
    uint16_t mode;
    uint16_t uid;
    uint16_t gid;
    uint32_t size;
    uint32_t atime;
    uint32_t mtime;
    uint32_t ctime;
} tnfs_stat_t;

typedef struct tnfs_session {
    tnfs_transport io;
    uint16_t sid;            /* connection id assigned by MOUNT */
    uint8_t  seq;            /* next sequence number */
    int      mounted;
    uint16_t server_version; /* from MOUNT reply */
    uint16_t min_retry_ms;   /* from MOUNT reply */
    int      timeout_ms;     /* per-attempt reply wait (default 1000) */
    int      retries;        /* send attempts per command (default 5) */
    /* stream-transport (TCP) reassembly buffer */
    uint8_t  sbuf[2 * TNFS_MAX_PACKET];
    size_t   slen;
} tnfs_session;

/* Session */
int tnfs_mount(tnfs_session *s, const tnfs_transport *io,
               const char *mountpath, const char *user, const char *pass);
int tnfs_umount(tnfs_session *s);
/* umount (if mounted) + close the transport; session is dead after this */
void tnfs_disconnect(tnfs_session *s);

/* Directories */
int tnfs_opendir(tnfs_session *s, const char *path, uint8_t *out_handle);
int tnfs_readdir(tnfs_session *s, uint8_t handle, char *name, size_t cap);
int tnfs_closedir(tnfs_session *s, uint8_t handle);
int tnfs_mkdir(tnfs_session *s, const char *path);
int tnfs_rmdir(tnfs_session *s, const char *path);

/* Files */
int tnfs_open(tnfs_session *s, const char *path, uint16_t flags,
              uint16_t mode, uint8_t *out_fd);
int tnfs_read(tnfs_session *s, uint8_t fd, void *buf, uint16_t want,
              uint16_t *out_got);
int tnfs_write(tnfs_session *s, uint8_t fd, const void *buf, uint16_t len,
               uint16_t *out_put);
int tnfs_lseek(tnfs_session *s, uint8_t fd, uint8_t whence, int32_t offset,
               uint32_t *out_pos);
int tnfs_close(tnfs_session *s, uint8_t fd);
int tnfs_stat(tnfs_session *s, const char *path, tnfs_stat_t *st);
int tnfs_unlink(tnfs_session *s, const char *path);
int tnfs_rename(tnfs_session *s, const char *from, const char *to);
int tnfs_chmod(tnfs_session *s, const char *path, uint16_t mode);

/* Filesystem info (kilobytes) */
int tnfs_size(tnfs_session *s, uint32_t *out_kb);
int tnfs_free(tnfs_session *s, uint32_t *out_kb);

/*
 * Whole-file transfers. The library owns the chunk loop; the caller
 * supplies a data sink/source plus an optional progress callback.
 *
 * progress is invoked after every chunk and once at completion, with
 * bytes done so far and the expected total (0 if unknown). Returning
 * nonzero cancels the transfer (-> TNFS_ERR_ABORTED). A sink/source
 * failure aborts with TNFS_ERR_LOCAL_IO.
 *
 * tnfs_download stats the file first for the progress total. tnfs_upload
 * creates/truncates the remote file; source returns bytes produced
 * (0 = EOF, <0 = error) and total is caller-supplied (0 if unknown).
 */
typedef int (*tnfs_progress_cb)(void *user, uint32_t done, uint32_t total);

int tnfs_download(tnfs_session *s, const char *path,
                  int (*sink)(void *user, const void *buf, size_t len),
                  void *sink_user,
                  tnfs_progress_cb progress, void *progress_user);
int tnfs_upload(tnfs_session *s, const char *path, uint16_t mode,
                int (*source)(void *user, void *buf, size_t cap),
                void *source_user, uint32_t total,
                tnfs_progress_cb progress, void *progress_user);

/* Human-readable message for any tnfs_* return value */
const char *tnfs_strerror(int rc);

/*
 * POSIX/BSD transports. Resolve host and connect. Return 0 on success,
 * <0 on error. UDP is the spec's mandatory transport; TCP is for
 * TCP-only servers (e.g. apps.irata.online) and NATs that eat UDP.
 */
int tnfs_udp_transport(tnfs_transport *out, const char *host, uint16_t port);
int tnfs_tcp_transport(tnfs_transport *out, const char *host, uint16_t port);

/*
 * Transport-policy connect + mount (tnfs_connect.c): TNFS_T_UDP / TNFS_T_TCP
 * force a transport; TNFS_T_AUTO probes UDP (short timeout) and falls back
 * to TCP. Ids match the registry's fujiTransport rows.
 */
#define TNFS_T_UDP  1
#define TNFS_T_TCP  2
#define TNFS_T_AUTO 3
int tnfs_connect(tnfs_session *s, const char *host, uint16_t port,
                 int transport, const char *mountpath);

#ifdef __cplusplus
}
#endif

#endif /* FUJINET_TNFS_H */
