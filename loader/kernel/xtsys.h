/*
 * xtsys.h — XTOS syscall numbers (the frozen ABI), shared by the kernel
 * dispatch and the user-side stubs. Numbers follow docs/OS/dynamic-loading.md
 * §8: class blocks of 0x100; reach the gateway via `svc #1` with the number in
 * r7, args in r0-r5, return in r0.
 */
#ifndef XTSYS_H
#define XTSYS_H

/* process / task — block 0x100 */
#define SYS_spawn    0x100
#define SYS_exit     0x101
#define SYS_waitpid  0x102
#define SYS_getpid   0x103

/* filesystem / VFS — block 0x300 */
#define SYS_open     0x300
#define SYS_close    0x301
#define SYS_read     0x302
#define SYS_write    0x303
#define SYS_lseek    0x304

#endif
