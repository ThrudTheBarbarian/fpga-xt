/* socktest.c — self-contained socket regression over 127.0.0.1 (lwIP loopback,
 * no DHCP/PHY/link needed, so it runs identically on qemu and HW). One process:
 * a listener child (spawned with its stdout on a pipe so we serialize), then
 * the parent connects, sends, and the two exchange a token each way.
 *
 * Actually simpler + single-process: loopback lets a connect() to our own
 * listener complete within lwIP without a second scheduler entity — but accept
 * blocks the caller, so we need two flows. We use the kernel pipe + spawn_fd is
 * overkill here; instead we drive both ends by making the socket non-ordering
 * dependent: listen, then connect (queued in lwIP), then accept, then the
 * data. lwIP completes the SYN handshake in its own thread between our calls. */
#include "usys.h"

static void w(const char *s) { unsigned n = 0; while (s[n]) n++; sys_write(1, s, n); }
static int fails;
static void expect(const char *what, int ok)
{ w(ok ? "  [PASS] " : "  [FAIL] "); w(what); w("\n"); if (!ok) fails++; }

#define LOOPBACK 0x0100007Fu     /* 127.0.0.1 as be32 (in memory) */
#define PORT     8137

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    int ls = (int)sys_socket(XT_SOCK_TCP);
    expect("socket(TCP)", ls >= 0);
    expect("bind 127.0.0.1:8137", sys_bind(ls, LOOPBACK, PORT) == 0);
    expect("listen", sys_listen(ls, 4) == 0);

    /* connect from a second socket; lwIP's loopback completes the handshake in
     * the tcpip thread, so the SYN is pending by the time we accept */
    int cs = (int)sys_socket(XT_SOCK_TCP);
    expect("socket(client)", cs >= 0);
    long cr = sys_connect(cs, LOOPBACK, PORT);
    expect("connect to the listener", cr == 0);

    unsigned peer[2] = { 0, 0 };
    int as = (int)sys_accept(ls, peer);
    expect("accept -> server socket", as >= 0);
    expect("peer is 127.0.0.1", peer[0] == LOOPBACK);

    /* client -> server */
    const char *msg = "ping-over-tcp";
    long sn = sys_write(cs, msg, 13);
    expect("client send 13", sn == 13);
    char buf[32];
    long rn = sys_read(as, buf, sizeof buf);
    expect("server recv 13", rn == 13);
    int match = (rn == 13);
    for (int i = 0; i < 13 && match; i++) if (buf[i] != msg[i]) match = 0;
    expect("payload intact", match);

    /* server -> client (the reply direction) */
    long sn2 = sys_write(as, "pong", 4);
    expect("server send 4", sn2 == 4);
    long rn2 = sys_read(cs, buf, sizeof buf);
    expect("client recv 4", rn2 == 4 && buf[0] == 'p' && buf[3] == 'g');

    /* closing the server end -> the client read returns 0 (EOF) */
    sys_close(as);
    long eof = sys_read(cs, buf, sizeof buf);
    expect("EOF after peer close", eof == 0);

    sys_close(cs);
    sys_close(ls);

    if (fails) { w("socktest: FAILURES\n"); sys_exit(1); }
    w("socktest: all PASS\n");
    sys_exit(0);
}
