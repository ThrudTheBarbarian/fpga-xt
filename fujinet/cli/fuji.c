/*
 * fuji — command-line client for fujinetd.
 *
 *   fuji ping                              daemon alive?
 *   fuji servers                           list registry servers
 *   fuji ls    <server> [path]             list a directory
 *   fuji lsc   <server> [path]             ls + cache state column
 *   fuji stat  <server> <path>             file details
 *   fuji df    <server>                    filesystem size/free
 *   fuji fetch <server> <remote>           netcache download -> /Cache mirror
 *   fuji get   <server> <remote> [local]   plain download to a path
 *   fuji add-server <host[:port]> <udp|tcp|auto> [mountpath] [name…]
 *   fuji del-server <id>
 *
 * <server> = registry id / displayName / host, or a literal
 * [udp://|tcp://]host[:port]. Talks to fujinetd on 127.0.0.1:16385
 * (override with FUJID_PORT in the environment). Exit status: 0 on +ok,
 * 1 on any -err, 2 on usage/connect failure.
 *
 * Portable: builds for the host and for XTOS (posix/net shims + libc.so).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define FUJID_DEFAULT_PORT 16385

static int g_fd = -1;

static int daemon_connect(void)
{
    uint16_t port = FUJID_DEFAULT_PORT;
    const char *env = getenv("FUJID_PORT");
    if (env && atoi(env) > 0)
        port = (uint16_t)atoi(env);

    g_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_fd < 0)
        return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(g_fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        fprintf(stderr, "fuji: no fujinetd on 127.0.0.1:%u (boot script "
                        "40-FujiNet not run?)\n", port);
        close(g_fd);
        return -1;
    }
    return 0;
}

static int send_line(const char *fmt, ...)
{
    char line[640];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0 || n > (int)sizeof line - 2)
        return -1;
    line[n] = '\n';
    return send(g_fd, line, (size_t)n + 1, 0) == n + 1 ? 0 : -1;
}

/* stream reply lines until the daemon closes (we always send quit);
   returns 0 if a "+ok"/"+pong" was seen, 1 on "-err" */
static int stream_reply(int show_progress)
{
    char buf[1024], line[640];
    size_t have = 0, used = 0;
    int status = 1, tty = isatty(fileno(stdout));

    for (;;) {
        char *nl = memchr(buf + used, '\n', have - used);
        if (!nl) {
            if (used) {
                memmove(buf, buf + used, have - used);
                have -= used;
                used = 0;
            }
            ssize_t k = recv(g_fd, buf + have, sizeof buf - have, 0);
            if (k <= 0)
                break;
            have += (size_t)k;
            continue;
        }
        size_t n = (size_t)(nl - (buf + used));
        if (n >= sizeof line)
            n = sizeof line - 1;
        memcpy(line, buf + used, n);
        line[n] = '\0';
        used += (size_t)(nl - (buf + used)) + 1;

        if (strcmp(line, "+bye") == 0)
            continue;
        if (strncmp(line, "+progress ", 10) == 0 && show_progress) {
            unsigned done = 0, total = 0;
            sscanf(line + 10, "%u %u", &done, &total);
            if (tty) {
                if (total)
                    printf("\r%u / %u bytes (%u%%)   ", done, total,
                           (unsigned)(100.0 * done / (total ? total : 1)));
                else
                    printf("\r%u bytes   ", done);
                fflush(stdout);
            }
            continue;
        }
        if (strcmp(line, "+pong") == 0) {
            status = 0;
            printf("pong\n");
            continue;
        }
        if (strncmp(line, "+ok", 3) == 0) {
            status = 0;
            if (show_progress && tty)
                printf("\r");
            if (line[3])
                printf("%s\n", line + 4);
            continue;
        }
        if (line[0] == '-') {
            if (show_progress && tty)
                printf("\n");
            fprintf(stderr, "fuji: %s\n", line + 1);
            status = 1;
            continue;
        }
        if (strcmp(line, ".") == 0)
            continue;
        printf("%s\n", line);
    }
    return status;
}

static const char *path_basename(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static void usage(void)
{
    fprintf(stderr,
        "usage: fuji ping | servers | ls|lsc <server> [path]\n"
        "            | stat <server> <path> | df <server>\n"
        "            | fetch <server> <remote> | get <server> <remote> [local]\n"
        "            | add-server <host[:port]> <udp|tcp|auto> [mountpath] [name...]\n"
        "            | del-server <id>\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage();
        return 2;
    }
    const char *cmd = argv[1];
    int rc = -1, progress = 0;

    if (daemon_connect() < 0)
        return 2;

    if (strcmp(cmd, "ping") == 0 && argc == 2)
        rc = send_line("ping");
    else if (strcmp(cmd, "servers") == 0 && argc == 2)
        rc = send_line("servers");
    else if ((strcmp(cmd, "ls") == 0 || strcmp(cmd, "lsc") == 0) &&
             (argc == 3 || argc == 4))
        rc = send_line("%s \"%s\" \"%s\"", cmd, argv[2],
                       argc == 4 ? argv[3] : "/");
    else if (strcmp(cmd, "stat") == 0 && argc == 4)
        rc = send_line("stat \"%s\" \"%s\"", argv[2], argv[3]);
    else if (strcmp(cmd, "df") == 0 && argc == 3)
        rc = send_line("df \"%s\"", argv[2]);
    else if (strcmp(cmd, "fetch") == 0 && argc == 4) {
        progress = 1;
        rc = send_line("fetch \"%s\" \"%s\"", argv[2], argv[3]);
    }
    else if (strcmp(cmd, "get") == 0 && (argc == 4 || argc == 5)) {
        const char *local = argc == 5 ? argv[4] : path_basename(argv[3]);
        progress = 1;
        rc = send_line("get \"%s\" \"%s\" \"%s\"", argv[2], argv[3], local);
    }
    else if (strcmp(cmd, "add-server") == 0 && argc >= 3) {
        /* fuji add-server <host[:port]> [udp|tcp|auto] [mountpath] [name…] */
        const char *transport = argc > 3 ? argv[3] : "auto";
        const char *mount = argc > 4 ? argv[4] : "/";
        char name[192] = "";
        for (int i = 5; i < argc && strlen(name) < 160; i++) {
            if (name[0])
                strncat(name, " ", sizeof name - strlen(name) - 1);
            strncat(name, argv[i], sizeof name - strlen(name) - 1);
        }
        rc = send_line("add-server \"%s\" %s \"%s\" \"%s\"",
                       argv[2], transport, mount, name);
    }
    else if (strcmp(cmd, "del-server") == 0 && argc == 3)
        rc = send_line("del-server %s", argv[2]);
    else {
        usage();
        close(g_fd);
        return 2;
    }

    if (rc < 0 || send_line("quit") < 0) {
        fprintf(stderr, "fuji: daemon connection lost\n");
        close(g_fd);
        return 2;
    }
    rc = stream_reply(progress);
    close(g_fd);
    return rc;
}
