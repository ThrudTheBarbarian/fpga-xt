/* vfs_romfs.c — romfs as a VFS driver (in-memory; read-only). */
#include "vfs.h"
#include "romfs.h"
#include <stdint.h>

static long ro_read(vfs_file *f, void *buf, uint32_t n)
{
    uint32_t avail = f->size - f->pos;
    if (n > avail) n = avail;
    const uint8_t *d = (const uint8_t *)f->data;
    for (uint32_t i = 0; i < n; i++) ((uint8_t *)buf)[i] = d[f->pos + i];
    f->pos += n;
    return (long)n;
}

static long ro_lseek(vfs_file *f, long off, int whence)
{
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0 || np > (long)f->size) return -1;
    f->pos = (uint32_t)np;
    return np;
}

static void ro_close(vfs_file *f) { (void)f; }

static int ro_open(vfs_mount *m, const char *path, int flags, vfs_file *f)
{
    (void)m;
    if (flags & VFS_O_ACCMODE) return -1;               /* romfs is read-only */
    const uint8_t *d; uint32_t sz;
    if (!romfs_lookup(path, &d, &sz)) return -1;
    f->data = d; f->size = sz; f->pos = 0;
    f->read = ro_read; f->write = 0; f->lseek = ro_lseek; f->close = ro_close;
    return 0;
}

/* romfs is a flat path list — a "directory" exists iff some entry has it as
 * a proper prefix (mkromfs stores no directory records). */
static int ro_plen(const char *s) { int n = 0; while (s[n]) n++; return n; }

static int ro_stat(vfs_mount *m, const char *rel, struct xt_stat *st)
{
    (void)m;
    const uint8_t *d; uint32_t sz;
    if (romfs_lookup(rel, &d, &sz)) {
        st->mode = XT_S_IFREG; st->size = sz; st->mtime = 0;
        return 0;
    }
    int rl = ro_plen(rel);
    const char *p; uint32_t esz;
    for (uint32_t i = 0; romfs_entry(i, &p, &esz); i++) {
        int ok = 1;
        for (int k = 0; k < rl; k++) if (p[k] != rel[k]) { ok = 0; break; }
        if (ok && p[rl] == '/') {
            st->mode = XT_S_IFDIR; st->size = 0; st->mtime = 0;
            return 0;
        }
    }
    return -1;
}

/* enumerate the unique next components under rel ("/" = everything) */
static int ro_readdir(vfs_mount *m, const char *rel, int index,
                      char *name, int nsz, unsigned *mode)
{
    (void)m;
    int rl = ro_plen(rel);
    if (rl == 1 && rel[0] == '/') rl = 0;               /* root: prefix = "" */
    int emitted = 0;
    const char *p; uint32_t esz;
    for (uint32_t i = 0; romfs_entry(i, &p, &esz); i++) {
        int ok = 1;
        for (int k = 0; k < rl; k++) if (p[k] != rel[k]) { ok = 0; break; }
        if (!ok || p[rl] != '/') continue;
        const char *comp = p + rl + 1;
        int cn = 0; while (comp[cn] && comp[cn] != '/') cn++;
        if (!cn) continue;
        /* seen in an earlier matching entry? */
        int dup = 0;
        const char *q; uint32_t qsz;
        for (uint32_t j = 0; j < i && !dup; j++) {
            if (!romfs_entry(j, &q, &qsz)) break;
            int qok = 1;
            for (int k = 0; k < rl; k++) if (q[k] != rel[k]) { qok = 0; break; }
            if (!qok || q[rl] != '/') continue;
            const char *qc = q + rl + 1;
            int qn = 0; while (qc[qn] && qc[qn] != '/') qn++;
            if (qn == cn) {
                dup = 1;
                for (int t = 0; t < cn; t++) if (comp[t] != qc[t]) { dup = 0; break; }
            }
        }
        if (dup) continue;
        if (emitted++ == index) {
            int t = 0;
            while (t < cn && t < nsz - 1) { name[t] = comp[t]; t++; }
            name[t] = 0;
            if (mode) *mode = comp[cn] == '/' ? XT_S_IFDIR : XT_S_IFREG;
            return 1;
        }
    }
    return 0;
}

/* readdir + inline metadata (dir cache): same enumeration as ro_readdir, also filling
 * size (the entry byte length for files, 0 for dirs) + mode. mtime is 0 (romfs has none). */
static int ro_readdir_meta(vfs_mount *m, const char *rel, int index, struct vfs_dent *out)
{
    (void)m;
    int rl = ro_plen(rel);
    if (rl == 1 && rel[0] == '/') rl = 0;
    int emitted = 0;
    const char *p; uint32_t esz;
    for (uint32_t i = 0; romfs_entry(i, &p, &esz); i++) {
        int ok = 1;
        for (int k = 0; k < rl; k++) if (p[k] != rel[k]) { ok = 0; break; }
        if (!ok || p[rl] != '/') continue;
        const char *comp = p + rl + 1;
        int cn = 0; while (comp[cn] && comp[cn] != '/') cn++;
        if (!cn) continue;
        int dup = 0;
        const char *q; uint32_t qsz;
        for (uint32_t j = 0; j < i && !dup; j++) {
            if (!romfs_entry(j, &q, &qsz)) break;
            int qok = 1;
            for (int k = 0; k < rl; k++) if (q[k] != rel[k]) { qok = 0; break; }
            if (!qok || q[rl] != '/') continue;
            const char *qc = q + rl + 1;
            int qn = 0; while (qc[qn] && qc[qn] != '/') qn++;
            if (qn == cn) { dup = 1; for (int t = 0; t < cn; t++) if (comp[t] != qc[t]) { dup = 0; break; } }
        }
        if (dup) continue;
        if (emitted++ == index) {
            int t = 0; while (t < cn && t < (int)sizeof out->name - 1) { out->name[t] = comp[t]; t++; } out->name[t] = 0;
            if (t < cn) out->name[0] = 0;   /* name didn't fit -> mark uncacheable (dir cache skips it) */
            int isdir = (comp[cn] == '/');
            out->mode  = isdir ? XT_S_IFDIR : XT_S_IFREG;
            out->size  = isdir ? 0 : esz;
            out->mtime = 0;
            return 1;
        }
    }
    return 0;
}

static vfs_fs romfs_fs = {
    .name = "romfs", .open = ro_open,
    .stat = ro_stat, .readdir = ro_readdir, .readdir_meta = ro_readdir_meta,
};

void vfs_romfs_init(void) { vfs_register_fs(&romfs_fs); }
