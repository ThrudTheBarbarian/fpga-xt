/* busybox-compat: signal.h — newlib's, plus the sa_flags glibc spells that
 * newlib lacks. Signals on XTOS are soft (newlib's raise only); the shim's
 * sigaction/sigprocmask just keep the caller's bookkeeping consistent. */
#ifndef _BB_COMPAT_SIGNAL_H
#define _BB_COMPAT_SIGNAL_H

#include_next <signal.h>

#ifndef SA_RESTART
# define SA_RESTART   0x10000000
#endif
#ifndef SA_SIGINFO
# define SA_SIGINFO   0x00000004
#endif
#ifndef SA_NODEFER
# define SA_NODEFER   0x40000000
#endif
#ifndef SA_RESETHAND
# define SA_RESETHAND 0x80000000
#endif
#ifndef SA_NOCLDWAIT
# define SA_NOCLDWAIT 0x00000002
#endif

/* newlib's bare-metal struct sigaction has no sa_sigaction member and there
 * is no ucontext; signals here are soft (never asynchronously delivered), so
 * a 3-arg handler stored via sa_handler is never actually called wrong. */
#ifndef sa_sigaction
# define sa_sigaction sa_handler
#endif
typedef struct { sigset_t uc_sigmask; } ucontext_t;

#ifdef __cplusplus
extern "C" {
#endif
int killpg(int pgrp, int sig);
int sigisemptyset(const sigset_t *set);
#ifdef __cplusplus
}
#endif

#endif
