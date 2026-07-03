/* netcon.c — the console over TCP: port 23 MIRRORS the serial session (this is
 * not a second login — one console, two transports). Everything the console
 * writer emits (program output, prompts, cooked echo) is teed into a ring and
 * a flusher task streams it to the connected client; received bytes are
 * injected into the shell's input ring as if typed on the UART (so the line
 * discipline, ^C/^Z and the raw-mode editor all just work).
 *
 *   mac$ nc xtos.local 23        (or telnet xtos.local)
 *
 * One client at a time; a new connection replaces a dead one. If the first
 * byte from the client is IAC we assume a real telnet client: negotiate
 * WILL ECHO + WILL SGA (character mode) and strip IAC sequences from then on;
 * nc's raw byte stream passes through untouched. LAN trust, like the rest. */
#include "lwip/tcpip.h"
#include "lwip/tcp.h"
#include "FreeRTOS.h"
#include "task.h"
#include <string.h>

extern void puts0(const char *);
extern void sh_inject(unsigned char c);       /* uart1_rx.c (HW) / no-op (qemu) */

static struct tcp_pcb *g_client;
static int  g_telnet;                          /* client speaks telnet -> filter IAC */
static int  g_iac;                             /* IAC parser state: 0 none, 1 cmd, 2 opt, 3 subneg */

/* ---- output tee ring (console writer -> flusher task -> tcp) --------------- */
#define TEE_SZ 8192
static volatile unsigned char g_tee[TEE_SZ];
static volatile unsigned g_thead, g_ttail;     /* head = read, tail = write */

/* PURE memory writes: the console writer runs INLINE AT SVC LEVEL for fd 1/2,
 * so no FreeRTOS call is legal here — the flusher polls the ring instead */
void net_console_tee(const char *buf, int len)
{
    if (!g_client) return;                     /* nobody listening: free */
    for (int i = 0; i < len; i++) {
        unsigned nt = (g_ttail + 1u) % TEE_SZ;
        if (nt == g_thead) break;              /* full: drop the tail (console never blocks) */
        g_tee[g_ttail] = (unsigned char)buf[i];
        g_ttail = nt;
    }
}

static void flusher(void *arg)
{
    (void)arg;
    static unsigned char chunk[1024];
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(25));         /* poll: SVC-level writers can't signal us */
        while (g_thead != g_ttail && g_client) {
            unsigned n = 0;
            while (n < sizeof chunk && g_thead != g_ttail) {
                chunk[n++] = g_tee[g_thead];
                g_thead = (g_thead + 1u) % TEE_SZ;
            }
            LOCK_TCPIP_CORE();
            struct tcp_pcb *c = g_client;
            if (c) {
                if (n > tcp_sndbuf(c)) n = tcp_sndbuf(c);
                if (n) { tcp_write(c, chunk, (u16_t)n, TCP_WRITE_FLAG_COPY); tcp_output(c); }
            }
            UNLOCK_TCPIP_CORE();
            if (!n) { vTaskDelay(pdMS_TO_TICKS(20)); break; }   /* window full: let ACKs land */
        }
    }
}

/* ---- input: inject into the shell's byte stream ---------------------------- */
static void inject_filtered(const unsigned char *b, int len)
{
    for (int i = 0; i < len; i++) {
        unsigned char c = b[i];
        if (g_telnet) {
            if (g_iac == 3) { if (c == 240) g_iac = 0; continue; }       /* subneg until SE */
            if (g_iac == 2) { g_iac = 0; continue; }                     /* option byte */
            if (g_iac == 1) {                                            /* command byte */
                if (c == 250) { g_iac = 3; continue; }                   /* SB -> subneg */
                if (c >= 251 && c <= 254) { g_iac = 2; continue; }       /* WILL..DONT + opt */
                g_iac = 0; continue;                                     /* other cmds */
            }
            if (c == 255) { g_iac = 1; continue; }                       /* IAC */
            if (c == 0) continue;                                        /* telnet CR NUL pad */
        }
        sh_inject(c);
    }
}

/* ---- tcp callbacks (lwIP thread) ------------------------------------------- */
static void nc_close(struct tcp_pcb *pcb)
{
    if (pcb == g_client) g_client = 0;
    tcp_arg(pcb, 0); tcp_recv(pcb, 0); tcp_err(pcb, 0);
    tcp_close(pcb);
}

static void nc_err(void *arg, err_t err)
{
    (void)arg; (void)err;
    g_client = 0;                              /* pcb already freed by lwIP */
}

static err_t nc_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    (void)arg;
    if (!p) { nc_close(pcb); return ERR_OK; }  /* client closed */
    if (err == ERR_OK) {
        /* first byte IAC = a real telnet client: answer WILL ECHO + WILL SGA */
        if (!g_telnet && p->len && ((unsigned char *)p->payload)[0] == 255) {
            static const unsigned char nego[] = { 255,251,1, 255,251,3 };
            g_telnet = 1;
            tcp_write(pcb, nego, sizeof nego, TCP_WRITE_FLAG_COPY);
        }
        for (struct pbuf *q = p; q; q = q->next)
            inject_filtered((const unsigned char *)q->payload, q->len);
        tcp_recved(pcb, p->tot_len);
    }
    pbuf_free(p);
    return ERR_OK;
}

static err_t nc_accept(void *arg, struct tcp_pcb *pcb, err_t err)
{
    (void)arg;
    if (err != ERR_OK) return err;
    if (g_client) nc_close(g_client);          /* new session replaces the old */
    g_client = pcb; g_telnet = 0; g_iac = 0;
    g_thead = g_ttail = 0;                     /* fresh output stream */
    tcp_recv(pcb, nc_recv);
    tcp_err(pcb, nc_err);
    tcp_nagle_disable(pcb);                    /* keystroke echo must not coalesce */
    static const char hello[] = "connected to xtos console\r\n";
    tcp_write(pcb, hello, sizeof hello - 1, 0);
    sh_inject('\n');                           /* nudge the shell into a fresh prompt */
    return ERR_OK;
}

static void do_listen(void *arg)
{
    (void)arg;
    struct tcp_pcb *l = tcp_new_ip_type(IPADDR_TYPE_ANY);
    if (!l) return;
    if (tcp_bind(l, IP_ANY_TYPE, 23) != ERR_OK) { tcp_close(l); return; }
    l = tcp_listen(l);
    if (!l) return;
    tcp_accept(l, nc_accept);
    puts0("[net] console on tcp/23\n");
}

void netcon_init(void)
{
    xTaskCreate(flusher, "netcon", 1024, 0, 2, 0);
    tcpip_callback(do_listen, 0);
}

/* the console writer main.c registers: UART first (always), then the mirror */
void con_write_tee(const char *b, int n)
{
    extern void rt_write(const char *, int);
    rt_write(b, n);
    net_console_tee(b, n);
}
