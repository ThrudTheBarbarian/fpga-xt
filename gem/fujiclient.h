// fujiclient.h — tiny blocking line client for fujinetd (the FujiNet daemon
// on 127.0.0.1:16385; FUJID_PORT in the environment overrides).  Plain BSD
// sockets so the same file builds for the SDL host and for the A9 (net_shim
// provides the socket surface there).  No SQLite in here — the daemon owns
// the registry.

#ifndef GEM_FUJICLIENT_H
#define GEM_FUJICLIENT_H

int  fuji_connect(void);                            // fd, or -1 (no daemon)
int  fuji_cmd(int fd, const char *fmt, ...);        // send one command line; 0 ok
int  fuji_readline(int fd, char *buf, int cap);     // 1 = line, 0 = closed, -1 = error
void fuji_close(int fd);

#endif // GEM_FUJICLIENT_H
