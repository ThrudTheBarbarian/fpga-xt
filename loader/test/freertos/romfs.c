/* romfs — read-only filesystem over a packed blob. See tools/mkromfs.c. */
#include "romfs.h"
#include "vfs.h"
#include <string.h>

#define PATHLEN 56
typedef struct { char path[PATHLEN]; uint32_t off; uint32_t size; } ent_t;

static const uint8_t *g_blob;
static uint32_t       g_count;
static const ent_t   *g_ents;

void romfs_mount(const uint8_t *blob, uint32_t len)
{
    (void)len;
    if (!blob || memcmp(blob, "XRFS", 4) != 0) { g_blob = 0; return; }
    g_blob  = blob;
    memcpy(&g_count, blob + 4, 4);
    g_ents  = (const ent_t *)(blob + 8);
}

int romfs_lookup(const char *path, const uint8_t **data, uint32_t *size)
{
    if (!g_blob) return 0;
    for (uint32_t i = 0; i < g_count; i++) {
        if (strcmp(g_ents[i].path, path) == 0) {
            *data = g_blob + g_ents[i].off;
            *size = g_ents[i].size;
            return 1;
        }
    }
    return 0;
}

/* ---- romfs as a VFS filesystem (read-only, in-RAM, mmap-able) ------------- */
static int romfs_vopen(void *fsdata, const char *path, int flags, struct vfile *f)
{
    (void)fsdata; (void)flags;
    const uint8_t *d; uint32_t sz;
    if (!romfs_lookup(path, &d, &sz)) return -1;
    f->priv = (void *)d; f->size = sz;      /* files are page-aligned in the blob (mkromfs) */
    return 0;
}
static long romfs_vread(struct vfile *f, void *buf, long n)
{
    uint32_t avail = f->size - f->pos;
    if ((uint32_t)n > avail) n = (long)avail;
    memcpy(buf, (const uint8_t *)f->priv + f->pos, (size_t)n);
    f->pos += (uint32_t)n;
    return n;
}
static void     romfs_vclose(struct vfile *f) { (void)f; }   /* stateless */
static uint32_t romfs_vmmap(struct vfile *f)  { return (uint32_t)f->priv; }  /* in RAM = zero-copy */

const struct fs_ops romfs_ops = { "romfs", romfs_vopen, romfs_vread, romfs_vclose, romfs_vmmap };
