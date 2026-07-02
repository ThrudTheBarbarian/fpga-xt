/* romfs — read-only filesystem over a packed blob. See tools/mkromfs.c. */
#include "romfs.h"
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

/* flat enumeration (for the VFS driver's stat/readdir): entry i's path+size,
 * 1 while valid, 0 past the end */
int romfs_entry(uint32_t i, const char **path, uint32_t *size)
{
    if (!g_blob || i >= g_count) return 0;
    *path = g_ents[i].path;
    *size = g_ents[i].size;
    return 1;
}
