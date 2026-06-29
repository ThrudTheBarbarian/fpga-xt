/* bare_rt — minimal bare-metal runtime shared by the qemu testbeds:
 * semihosting I/O, freestanding libc bits, and a bump allocator. */
#ifndef BARE_RT_H
#define BARE_RT_H
#include <stddef.h>
#include <stdint.h>

void puts0(const char *s);          /* semihosting SYS_WRITE0 (NUL-terminated) */
void putu(unsigned v);              /* decimal */
int  sh_readc(void);               /* semihosting SYS_READC; <0 at EOF */
void rt_write(const char *b, int n);/* length-bounded write (-> puts0) */
void sh_exit(int code);            /* semihosting exit, sets qemu status */

/* host filesystem over semihosting (qemu only; stubs return -1 on real metal) */
long hostfs_open(const char *path);          /* -> handle, or <0 */
long hostfs_len(long h);                     /* -> byte length, or <0 */
long hostfs_read(long h, void *buf, long len);/* -> bytes read, or <0 */
void hostfs_close(long h);

void *bump(size_t size, size_t align, void *user); /* xtld_host.alloc */

#endif
