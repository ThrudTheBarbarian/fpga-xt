/* busybox-compat: mntent.h — no mount table on XTOS; nothing configured in
 * walks it, libbb.h just wants the types to exist. */
#ifndef _BB_COMPAT_MNTENT_H
#define _BB_COMPAT_MNTENT_H

#include <stdio.h>

struct mntent {
    char *mnt_fsname;
    char *mnt_dir;
    char *mnt_type;
    char *mnt_opts;
    int   mnt_freq;
    int   mnt_passno;
};

#define MNTTYPE_IGNORE "ignore"
#define MOUNTED "/etc/mtab"

#ifdef __cplusplus
extern "C" {
#endif
FILE *setmntent(const char *file, const char *mode);
struct mntent *getmntent(FILE *f);
struct mntent *getmntent_r(FILE *f, struct mntent *m, char *buf, int len);
int endmntent(FILE *f);
#ifdef __cplusplus
}
#endif

#endif
