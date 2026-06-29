/* romfs — read-only filesystem over a packed blob (see tools/mkromfs.c). */
#ifndef ROMFS_H
#define ROMFS_H
#include <stdint.h>

/* Point the FS at an in-memory blob. */
void romfs_mount(const uint8_t *blob, uint32_t len);

/* Look up a path; on success returns 1 and fills *data/*size, else 0. */
int  romfs_lookup(const char *path, const uint8_t **data, uint32_t *size);

/* romfs as a VFS filesystem (the read-only, in-RAM, mmap-able root). */
struct fs_ops;
extern const struct fs_ops romfs_ops;

#endif
