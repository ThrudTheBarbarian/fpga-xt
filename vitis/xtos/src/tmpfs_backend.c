// tmpfs_backend.c — VFS backend: a small RAM filesystem mounted at "/tmp".
// Files live in malloc'd buffers (newlib heap); they vanish on reboot.  Handy
// for scratch/temp files that shouldn't touch the SD.  (Shape after T288 tmpfs.)

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include "vfs.h"

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

#define TMP_MAXF 16
#define TMP_MAXD 2

typedef struct { char name[VFS_NAME_MAX]; char *data; long size, cap, pos; char used; } tfile;
static tfile tf[TMP_MAXF];
static struct { char used; int it; } td[TMP_MAXD];

static tfile *tmp_find(const char *path)
{
    for (int i = 0; i < TMP_MAXF; i++)
        if (tf[i].used && strcmp(tf[i].name, path) == 0) return &tf[i];
    return (void *)0;
}

static int tmp_open(const char *path, int flags)
{
    tfile *f = tmp_find(path);
    if (f) {
        f->pos = 0;
        if (flags & O_TRUNC) { free(f->data); f->data = (void *)0; f->size = f->cap = 0; }
        return (int)(f - tf);
    }
    if (flags & O_CREAT) {
        int i;
        for (i = 0; i < TMP_MAXF; i++) if (!tf[i].used) break;
        if (i == TMP_MAXF) return -1;
        memset(&tf[i], 0, sizeof tf[i]);
        strncpy(tf[i].name, path, VFS_NAME_MAX - 1);
        tf[i].used = 1;
        return i;
    }
    return -1;
}

static int tmp_read(int h, char *buf, int n)
{
    tfile *f = &tf[h];
    long avail = f->size - f->pos;
    if (avail <= 0) return 0;
    if (n > avail) n = (int)avail;
    memcpy(buf, f->data + f->pos, n);
    f->pos += n;
    return n;
}

static int tmp_write(int h, const char *buf, int n)
{
    tfile *f = &tf[h];
    if (f->pos + n > f->cap) {
        long nc = (f->pos + n) * 2 + 64;
        char *nd = realloc(f->data, nc);
        if (!nd) return -1;
        f->data = nd; f->cap = nc;
    }
    memcpy(f->data + f->pos, buf, n);
    f->pos += n;
    if (f->pos > f->size) f->size = f->pos;
    return n;
}

static int  tmp_close(int h)             { (void)h; return 0; }   /* persists in RAM */
static long tmp_size (int h)             { return tf[h].size; }

static long tmp_lseek(int h, long off, int whence)
{
    tfile *f = &tf[h];
    long b = (whence == SEEK_CUR) ? f->pos : (whence == SEEK_END) ? f->size : 0;
    f->pos = b + off;
    return f->pos;
}

static int tmp_remove(const char *path)
{
    tfile *f = tmp_find(path);
    if (!f) return -1;
    free(f->data); f->data = (void *)0; f->used = 0;
    return 0;
}

static int tmp_diropen(const char *path)
{
    (void)path;
    int i;
    for (i = 0; i < TMP_MAXD; i++) if (!td[i].used) break;
    if (i == TMP_MAXD) return -1;
    td[i].used = 1; td[i].it = 0;
    return i;
}

static int tmp_dirnext(int dh, struct vfs_dirent *o)
{
    while (td[dh].it < TMP_MAXF) {
        int i = td[dh].it++;
        if (!tf[i].used) continue;
        const char *base = strrchr(tf[i].name, '/');
        base = base ? base + 1 : tf[i].name;
        strncpy(o->name, base, VFS_NAME_MAX - 1);
        o->name[VFS_NAME_MAX - 1] = 0;
        o->is_dir = 0;
        o->size = (unsigned long)tf[i].size;
        return 1;
    }
    return 0;
}

static void tmp_dirclose(int dh) { td[dh].used = 0; }

static const vfs_fs TMP = {
    "/tmp", tmp_open, tmp_read, tmp_write, tmp_close, tmp_lseek, tmp_size,
    tmp_remove, tmp_diropen, tmp_dirnext, tmp_dirclose
};

void tmpfs_backend_register(void) { vfs_register(&TMP); }
