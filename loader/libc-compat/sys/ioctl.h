/* libc-compat: sys/ioctl.h — the console is a dumb UART; the shim answers
 * TIOCGWINSZ with a fixed 80x24 and fails everything else. */
#ifndef _XT_COMPAT_SYS_IOCTL_H
#define _XT_COMPAT_SYS_IOCTL_H

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

#define TIOCSCTTY  0x540E
#define TIOCGPGRP  0x540F
#define TIOCSPGRP  0x5410
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#define FIONREAD   0x541B
#define TIOCNOTTY  0x5422

#ifdef __cplusplus
extern "C"
#endif
int ioctl(int fd, unsigned long request, ...);

#endif
