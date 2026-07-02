/* libc-compat: sys/uio.h — the shim implements readv/writev as read/write
 * loops (one syscall per iovec) */
#ifndef _XT_COMPAT_SYS_UIO_H
#define _XT_COMPAT_SYS_UIO_H

#include <sys/types.h>

struct iovec {
    void  *iov_base;
    size_t iov_len;
};

#ifdef __cplusplus
extern "C" {
#endif
ssize_t readv(int fd, const struct iovec *iov, int iovcnt);
ssize_t writev(int fd, const struct iovec *iov, int iovcnt);
#ifdef __cplusplus
}
#endif

#endif
