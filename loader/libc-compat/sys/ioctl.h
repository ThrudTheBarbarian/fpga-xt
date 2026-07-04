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

/* socket/interface ioctls (SIOCGIF* serviced kernel-side from the lwIP netif) */
#define SIOCGIFCONF    0x8912
#define SIOCGIFFLAGS   0x8913
#define SIOCSIFFLAGS   0x8914
#define SIOCGIFADDR    0x8915
#define SIOCSIFADDR    0x8916
#define SIOCGIFDSTADDR 0x8917
#define SIOCSIFDSTADDR 0x8918
#define SIOCGIFBRDADDR 0x8919
#define SIOCSIFBRDADDR 0x891a
#define SIOCGIFNETMASK 0x891b
#define SIOCSIFNETMASK 0x891c
#define SIOCGIFMETRIC  0x891d
#define SIOCSIFMETRIC  0x891e
#define SIOCGIFMTU     0x8921
#define SIOCSIFMTU     0x8922
#define SIOCGIFHWADDR  0x8927
#define SIOCSIFHWADDR  0x8924
#define SIOCGIFINDEX   0x8933
#define SIOCGIFTXQLEN  0x8942
#define SIOCSIFTXQLEN  0x8943
#define SIOCGIFMAP     0x8970
#define SIOCSIFMAP     0x8971
#define SIOCSIFNAME    0x8923
#define SIOCDIFADDR    0x8936
#define SIOCADDRT      0x890b
#define SIOCDELRT      0x890c
#define SIOCDEVPRIVATE 0x89f0

#ifdef __cplusplus
extern "C"
#endif
int ioctl(int fd, unsigned long request, ...);

#endif
