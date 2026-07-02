/* libc-compat: pty.h — no ptys on XTOS (yet; a pty-ish fd is the Phase C
 * GEM-terminal plan). Declaration surface only. */
#ifndef _XT_COMPAT_PTY_H
#define _XT_COMPAT_PTY_H

#include <termios.h>
#include <sys/ioctl.h>

#ifdef __cplusplus
extern "C" {
#endif
int openpty(int *amaster, int *aslave, char *name,
            const struct termios *termp, const struct winsize *winp);
int forkpty(int *amaster, char *name,
            const struct termios *termp, const struct winsize *winp);
int ptsname_r(int fd, char *buf, int buflen);
int grantpt(int fd);
int unlockpt(int fd);
#ifdef __cplusplus
}
#endif

#endif
