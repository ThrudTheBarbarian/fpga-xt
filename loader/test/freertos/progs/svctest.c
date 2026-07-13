/*
 * svctest — the M0 gate for gemd: SYS_svc_register/connect/accept + SYS_poll.
 *
 * This proves the one thing XTOS could not do, and which gemd is impossible without:
 * TWO UNRELATED PROCESSES CAN RENDEZVOUS. Pipes need shared ancestry (SYS_spawn_fd), and
 * gemd is not the parent of a boot-script desktop or an ssh-launched app — so before this,
 * they could not talk at all.
 *
 * It also proves the server never blocks on any one client (poll), and that a client's
 * DEATH is observed — via channel EOF, not SIGCHLD, which only ever reaches the parent.
 *
 *   svctest -s        server: register "test", poll, echo, report deaths
 *   svctest -c <msg>  client: connect, send, read the echo, exit
 *   svctest -q        client: connect, send "quiet", then _exit() WITHOUT closing
 *                     -> the server must still see the hangup (the death test)
 */
#include <stdio.h>
#include <string.h>
#include "usys.h"

#define MAXC 8

static void server(void)
{
    int lfd = sys_svc_register("test");
    if (lfd < 0) { printf("svctest: FAIL — register: %d\n", lfd); sys_exit(1); }
    printf("svctest: registered service \"test\" (listen fd %d)\n", lfd);

    int cfd[MAXC]; int nc = 0;
    int served = 0, hups = 0;

    for (;;) {
        struct xt_pollfd pf[1 + MAXC];
        pf[0].fd = lfd; pf[0].events = XT_POLLIN; pf[0].revents = 0;
        for (int i = 0; i < nc; i++) {
            pf[1 + i].fd = cfd[i]; pf[1 + i].events = XT_POLLIN; pf[1 + i].revents = 0;
        }

        int r = sys_poll(pf, 1 + nc, 30000);      /* ONE wait, all fds. No thread per client. */
        if (r == 0) break;                        /* 30 s idle: done */
        if (r < 0) { printf("svctest: poll -> %d\n", r); break; }

        if (pf[0].revents & XT_POLLIN) {          /* a client is connecting */
            int c = sys_svc_accept(lfd);
            if (c >= 0 && nc < MAXC) {
                cfd[nc++] = c;
                printf("svctest: accepted a client (fd %d) — not my child, never was\n", c);
            }
        }

        for (int i = 0; i < nc; i++) {
            if (!(pf[1 + i].revents & (XT_POLLIN | XT_POLLHUP))) continue;
            char buf[64];
            long n = sys_read(cfd[i], buf, sizeof buf - 1);
            if (n > 0) {
                buf[n] = 0;
                printf("svctest:   <- \"%s\"\n", buf);
                sys_write(cfd[i], buf, (unsigned)n);      /* echo it back */
                served++;
            } else {                                       /* n == 0: EOF — the peer is GONE */
                printf("svctest:   client fd %d hung up (EOF) — death observed WITHOUT SIGCHLD\n",
                       cfd[i]);
                sys_close(cfd[i]);
                hups++;
                for (int k = i + 1; k < nc; k++) cfd[k - 1] = cfd[k];
                nc--; i--;
            }
        }
    }
    printf("svctest: server done — %d message(s) served, %d hangup(s) seen %s\n",
           served, hups, (served >= 1 && hups >= 1) ? "OK" : "FAIL");
    sys_exit(0);
}

static void client(const char *msg, int quiet)
{
    int fd = sys_svc_connect("test");
    if (fd < 0) { printf("svctest: FAIL — connect: %d (is the server up?)\n", fd); sys_exit(1); }
    sys_write(fd, msg, (unsigned)strlen(msg));

    if (quiet) {                 /* die WITHOUT closing: the server must still see the hangup */
        printf("svctest: client sent \"%s\" and is exiting without closing\n", msg);
        sys_exit(0);
    }
    char buf[64];
    long n = sys_read(fd, buf, sizeof buf - 1);
    if (n > 0) {
        buf[n] = 0;
        printf("svctest: client got echo \"%s\" %s\n", buf, strcmp(buf, msg) ? "FAIL" : "OK");
    } else {
        printf("svctest: client got no echo (%ld) FAIL\n", n);
    }
    sys_close(fd);
    sys_exit(0);
}

void _app_entry(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "-s")) server();
    if (argc >= 2 && !strcmp(argv[1], "-q")) client("quiet", 1);
    if (argc >= 3 && !strcmp(argv[1], "-c")) client(argv[2], 0);
    printf("usage: svctest -s | svctest -c <msg> | svctest -q\n");
    sys_exit(1);
}
