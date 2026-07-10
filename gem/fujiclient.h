// fujiclient.h — tiny line client for fujinetd (the FujiNet daemon on
// 127.0.0.1:16385; FUJID_PORT in the environment overrides).  Plain BSD
// sockets so the same file builds for the SDL host and for the A9 (net_shim
// provides the socket surface there).  No SQLite in here — the daemon owns
// the registry.
//
// Two read styles share one per-fd line buffer: fuji_readline blocks until a
// full line arrives (CLI-style callers), fuji_poll_line never blocks (the
// desktop pumps it from its event loop after fuji_set_nonblock).

#ifndef GEM_FUJICLIENT_H
#define GEM_FUJICLIENT_H

int  fuji_connect(void);                            // fd, or -1 (no daemon)
int  fuji_cmd(int fd, const char *fmt, ...);        // send one command line; 0 ok
int  fuji_readline(int fd, char *buf, int cap);     // 1 = line, 0 = closed, -1 = error
int  fuji_set_nonblock(int fd);                     // make fd non-blocking; 0 ok
int  fuji_poll_line(int fd, char *buf, int cap);    // 1 = line, 0 = none yet, -1 = EOF/error
void fuji_close(int fd);

#endif // GEM_FUJICLIENT_H
