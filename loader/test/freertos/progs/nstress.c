/* nstress.c — socket connection-churn stress (bare usys). Brings up NPORT
 * listeners, then hammers them: each round opens NCONN client sockets and
 * connects them (spread across the ports) with minimal work per connection,
 * multiplexes non-blocking accept across all listeners to pick them up,
 * exchanges a byte each way, and closes everything — for many rounds. The
 * point is to shake out races in socket alloc/free, accept, close and the fd
 * table under rapid concurrent setup/teardown, all over loopback (no DHCP).
 *
 *   nstress [rounds]     (default 200)
 */
#include "usys.h"

#define NPORT   10
#define BASE    9000
#define NCONN   8            /* concurrent connections in flight per round */
#define LOOPBACK 0x0100007Fu /* 127.0.0.1 be32 */

static void w(const char *s) { unsigned n=0; while(s[n])n++; sys_write(1,s,n); }
static void wn(const char *tag, long v)
{ char b[48],*p=b; while(*tag)*p++=*tag++; *p++='='; char t[16]; int i=0; long u=v; if(u<0){*p++='-';u=-u;}
  do{t[i++]=(char)('0'+u%10);u/=10;}while(u); while(i)*p++=t[--i]; *p++='\n'; sys_write(1,b,(unsigned)(p-b)); }

int lsock[NPORT];

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    int rounds = 200;
    if (argc > 1) { rounds = 0; for (const char *s = argv[1]; *s>='0'&&*s<='9'; s++) rounds = rounds*10 + (*s-'0'); }

    /* NPORT listeners */
    int up = 0;
    for (int i = 0; i < NPORT; i++) {
        lsock[i] = (int)sys_socket(XT_SOCK_TCP);
        if (lsock[i] < 0) { wn("sock_fail port", BASE+i); continue; }
        long br = sys_bind(lsock[i], 0, (unsigned)(BASE+i));
        if (br != 0) { wn("bind_fail rc port", BASE+i); sys_close(lsock[i]); lsock[i] = -1; continue; }
        long lr = sys_listen(lsock[i], 8);
        if (lr != 0) { wn("listen_fail rc port", BASE+i); sys_close(lsock[i]); lsock[i] = -1; continue; }
        up++;
    }
    wn("nstress: listeners up", up);
    if (up < NPORT) w("(some listeners failed — continuing with those that came up)\n");

    long conn_ok = 0, conn_fail = 0, data_fail = 0, accept_fail = 0;

    for (int r = 0; r < rounds; r++) {
        int cli[NCONN], acc[NCONN];              /* client j and its accepted peer both index by PORT j */
        for (int j = 0; j < NCONN; j++) { cli[j] = acc[j] = -1; }

        /* open + connect NCONN clients, one per distinct port (so accept from
         * listener j pairs deterministically with client j) */
        for (int j = 0; j < NCONN; j++) {
            if (lsock[j] < 0) continue;                /* that port never came up */
            cli[j] = (int)sys_socket(XT_SOCK_TCP);
            if (cli[j] < 0) { conn_fail++; continue; }
            if (sys_connect(cli[j], LOOPBACK, (unsigned)(BASE + j)) != 0) { conn_fail++; sys_close(cli[j]); cli[j] = -1; }
        }

        /* multiplex non-blocking accept across the listeners until every live
         * client is picked up (bounded so a lost connection can't wedge us) */
        int need = 0; for (int j = 0; j < NCONN; j++) if (cli[j] >= 0) need++;
        int got = 0, spins = 0;
        while (got < need && spins++ < 4000) {
            for (int j = 0; j < NCONN; j++) {
                if (acc[j] >= 0 || cli[j] < 0) continue;
                unsigned peer[2];
                long a = sys_accept_nb(lsock[j], peer);    /* port j -> pairs with cli[j] */
                if (a == -2) continue;                     /* none pending yet */
                if (a < 0) { accept_fail++; acc[j] = -2; continue; }  /* mark hard fail */
                acc[j] = (int)a; got++;
            }
        }

        /* one byte each way over every established pair */
        for (int j = 0; j < NCONN; j++) {
            if (cli[j] < 0 || acc[j] < 0) { if (cli[j] >= 0 && acc[j] == -1) accept_fail++; continue; }
            char c = (char)('A' + (j & 31)), rb = 0;
            if (sys_write(cli[j], &c, 1) != 1) { data_fail++; continue; }
            if (sys_read(acc[j], &rb, 1) != 1 || rb != c) { data_fail++; continue; }
            char d = (char)('a' + (j & 31)), rb2 = 0;
            if (sys_write(acc[j], &d, 1) != 1) { data_fail++; continue; }
            if (sys_read(cli[j], &rb2, 1) != 1 || rb2 != d) { data_fail++; continue; }
            conn_ok++;
        }

        /* tear everything down */
        for (int j = 0; j < NCONN; j++) { if (acc[j] >= 0) sys_close(acc[j]); if (cli[j] >= 0) sys_close(cli[j]); }

        if ((r & 31) == 31) wn("round", r + 1);
    }

    w("=== nstress done ===\n");
    wn("conn_ok", conn_ok);
    wn("conn_fail", conn_fail);
    wn("accept_fail", accept_fail);
    wn("data_fail", data_fail);
    sys_exit((conn_fail || accept_fail || data_fail) ? 1 : 0);
}
