/* busybox-compat: sys/sysmacros.h — no device numbers on the XTOS VFS */
#ifndef _BB_COMPAT_SYS_SYSMACROS_H
#define _BB_COMPAT_SYS_SYSMACROS_H
#ifndef major
# define major(dev)      ((int)(((dev) >> 8) & 0xff))
# define minor(dev)      ((int)((dev) & 0xff))
# define makedev(ma, mi) ((((ma) & 0xff) << 8) | ((mi) & 0xff))
#endif
#endif
