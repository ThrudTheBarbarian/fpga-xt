/* tftpd.c — the TFTP file drop: lwIP's tftp server over the kernel VFS.
 *
 *   mac$ tftp <board-ip>            (or curl tftp://<ip>/...)
 *   tftp> binary
 *   tftp> put desktop /OS/bin/desktop
 *   tftp> get /OS/etc/motd
 *
 * Writes stream through the fs task (KFS_WRITEOPEN/WRITEBLOCK/WRITECLOSE —
 * the fs task stays the sole FatFs driver); one transfer at a time, which is
 * also lwIP's tftp model. Reads pull the whole file via KFS_READFILE (kernel
 * bump heap: fine for the occasional get, not a file server). Filenames are
 * VFS paths; a leading '/' is added if missing. This is a LAN convenience
 * with no authentication — same trust level as the serial console. */
#include "lwip/apps/tftp_server.h"
#include "lwip/pbuf.h"
#include "lwip/tcpip.h"

extern void klog(const char *);      /* -> /OS/var/log/system.log (not console) */
extern void klog_u(unsigned);
long frtos_net_writeopen(const char *path);
long frtos_net_writeblock(const void *buf, unsigned len);
long frtos_net_writeclose(void);
long frtos_net_readfile(const char *path, const void **data);

#define H_WRITE ((void *)1)
#define H_READ  ((void *)2)

static struct {                       /* the single read transfer */
    const char *data;
    long        len, pos;
} g_rd;

static void *tf_open(const char *fname, const char *mode, u8_t write)
{
    (void)mode;
    char path[160];
    int i = 0;
    if (fname[0] != '/') path[i++] = '/';
    for (int j = 0; fname[j] && i < (int)sizeof path - 1; j++) path[i++] = fname[j];
    path[i] = 0;

    klog("[tftp] open "); klog(path); klog(write ? " (put)\n" : " (get)\n");
    if (write)
        return frtos_net_writeopen(path) == 0 ? H_WRITE : 0;

    g_rd.len = frtos_net_readfile(path, (const void **)&g_rd.data);
    g_rd.pos = 0;
    return g_rd.len >= 0 ? H_READ : 0;
}

static void tf_close(void *h)
{
    if (h == H_WRITE) frtos_net_writeclose();
    if (h == H_READ) { g_rd.data = 0; g_rd.len = 0; }
}

static int tf_read(void *h, void *buf, int bytes)
{
    if (h != H_READ || !g_rd.data) return -1;
    long left = g_rd.len - g_rd.pos;
    if (bytes > left) bytes = (int)left;
    if (bytes > 0) {
        const char *s = g_rd.data + g_rd.pos;
        char *d = (char *)buf;
        for (int i = 0; i < bytes; i++) d[i] = s[i];
        g_rd.pos += bytes;
    }
    return bytes;
}

static int tf_write(void *h, struct pbuf *p)
{
    if (h != H_WRITE) return -1;
    /* lwIP treats a block SHORTER than blksize as end-of-file and closes the
     * handle. So a block that arrives short mid-transfer silently truncates the
     * file, and every later block then gets "No connection" (an ACCESS_VIOLATION)
     * -- which is what a stalled `curl -T` actually reports. Log any short block
     * so a truncated receive is distinguishable from a genuine last block. */
    if (p->tot_len < 512u) {
        klog("[tftp] short block: tot_len "); klog_u((unsigned)p->tot_len);
        klog("\n");
    }
    for (struct pbuf *q = p; q; q = q->next) {
        long w = frtos_net_writeblock(q->payload, q->len);
        if (w != (long)q->len) {
            /* lwIP turns a -1 from here into TFTP_ERROR_ACCESS_VIOLATION and
             * tears the transfer down -- which is exactly what a stalled
             * `curl -T` was hitting. Say what the write actually returned: a
             * SHORT COUNT and an ERROR are different faults and the old code
             * could not tell them apart. */
            klog("[tftp] short write: asked "); klog_u((unsigned)q->len);
            klog(" got "); klog_u((unsigned)w); klog("\n");
            return -1;
        }
    }
    return 0;
}

static void tf_error(void *h, int err, const char *msg, int size)
{
    (void)h; (void)err; (void)msg; (void)size;
    if (h == H_WRITE) frtos_net_writeclose();          /* drop the half-written handle */
}

static const struct tftp_context g_tftp = {
    tf_open, tf_close, tf_read, tf_write, tf_error,
};

static void do_init(void *arg)
{
    (void)arg;
    if (tftp_init_server(&g_tftp) != ERR_OK) klog("[net] tftpd init failed\n");
    else klog("[net] tftpd listening\n");
}

void tftpd_init(void)
{
    tcpip_callback(do_init, 0);       /* raw-API init belongs in the lwIP thread */
}
