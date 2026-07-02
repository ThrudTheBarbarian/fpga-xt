/* busybox-compat: sys/mman.h — declarations only; nothing configured in
 * actually maps (the loader's SYS_mmap is romfs-file-only, via usys.h). */
#ifndef _BB_COMPAT_SYS_MMAN_H
#define _BB_COMPAT_SYS_MMAN_H

#include <sys/types.h>

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

#define MAP_SHARED    0x01
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20
#define MAP_ANON      MAP_ANONYMOUS
#define MAP_FAILED    ((void *)-1)

#ifdef __cplusplus
extern "C" {
#endif
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);
int msync(void *addr, size_t len, int flags);
#ifdef __cplusplus
}
#endif

#endif
