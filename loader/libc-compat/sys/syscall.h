/* libc-compat: sys/syscall.h — Linux syscall numbers don't exist here; the
 * XTOS ABI is kernel/xtsys.h. Nothing configured in should call syscall()
 * directly; the shim's syscall() fails. */
#ifndef _XT_COMPAT_SYS_SYSCALL_H
#define _XT_COMPAT_SYS_SYSCALL_H

#ifdef __cplusplus
extern "C"
#endif
long syscall(long number, ...);

#endif
