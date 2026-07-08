/*
 * libfujinet — transport-policy connect: mount a server over the requested
 * transport, or probe UDP and fall back to TCP for TNFS_T_AUTO (several
 * public servers are TCP-only; some NATs eat UDP).
 *
 * Transport ids deliberately match the registry's fujiTransport rows:
 * 1 = udp, 2 = tcp, 3 = auto.
 */

#include <fujinet/tnfs.h>

static int mount_one(tnfs_session *s, const char *host, uint16_t port,
                     int use_tcp, int probe, const char *mountpath)
{
    tnfs_transport io;
    int rc = use_tcp ? tnfs_tcp_transport(&io, host, port)
                     : tnfs_udp_transport(&io, host, port);
    if (rc < 0)
        return rc;

    /* probe = short timeout / few attempts, for the UDP leg of auto mode */
    s->timeout_ms = probe ? 700 : 0;
    s->retries = probe ? 2 : 0;

    rc = tnfs_mount(s, &io, mountpath, "", "");
    if (rc != TNFS_OK && io.close)
        io.close(io.ctx);
    s->timeout_ms = 0;
    s->retries = 0;
    return rc;
}

int tnfs_connect(tnfs_session *s, const char *host, uint16_t port,
                 int transport, const char *mountpath)
{
    if (!mountpath)
        mountpath = "/";

    if (transport == TNFS_T_UDP)
        return mount_one(s, host, port, 0, 0, mountpath);
    if (transport == TNFS_T_TCP)
        return mount_one(s, host, port, 1, 0, mountpath);

    int rc = mount_one(s, host, port, 0, 1, mountpath);
    if (rc != TNFS_OK)
        rc = mount_one(s, host, port, 1, 0, mountpath);
    return rc;
}
