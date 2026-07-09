// fujiclient.c — tiny blocking line client for fujinetd (see fujiclient.h).
// Protocol: send command lines, read reply lines ("+ok ..." / "-err msg",
// lists end with ".", fetch streams "+progress <done> <total>").  One
// connection at a time: the receive buffer is shared and reset by
// fuji_connect (the desktop is single-threaded, one command per connection).

#include "fujiclient.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define FUJID_DEFAULT_PORT 16385

static char   rxbuf[1024];
static size_t rxhave, rxused;

int fuji_connect(void) {
    uint16_t port = FUJID_DEFAULT_PORT;
    const char *env = getenv("FUJID_PORT");
    if (env && atoi(env) > 0) port = (uint16_t)atoi(env);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { close(fd); return -1; }
    rxhave = rxused = 0;
    return fd;
}

int fuji_cmd(int fd, const char *fmt, ...) {
    char line[640];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0 || n > (int)sizeof line - 2) return -1;
    line[n] = '\n';
    return send(fd, line, (size_t)n + 1, 0) == n + 1 ? 0 : -1;
}

// One reply line into buf (NUL-terminated, newline stripped; long lines are
// truncated but consumed whole).
int fuji_readline(int fd, char *buf, int cap) {
    for (;;) {
        char *nl = memchr(rxbuf + rxused, '\n', rxhave - rxused);
        if (nl) {
            size_t n = (size_t)(nl - (rxbuf + rxused));
            if (n >= (size_t)cap) n = (size_t)cap - 1;
            memcpy(buf, rxbuf + rxused, n);
            buf[n] = 0;
            rxused = (size_t)(nl - rxbuf) + 1;
            return 1;
        }
        if (rxused) { memmove(rxbuf, rxbuf + rxused, rxhave - rxused); rxhave -= rxused; rxused = 0; }
        if (rxhave == sizeof rxbuf) rxhave = 0;                   // oversize line: drop and resync
        ssize_t k = recv(fd, rxbuf + rxhave, sizeof rxbuf - rxhave, 0);
        if (k == 0) return 0;
        if (k < 0) return -1;
        rxhave += (size_t)k;
    }
}

void fuji_close(int fd) { if (fd >= 0) close(fd); }
