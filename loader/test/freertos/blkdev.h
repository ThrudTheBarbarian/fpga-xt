/*
 * blkdev.h — minimal block-device manager. Filesystems (FatFs via diskio,
 * minixfs later) and swap ride on registered block devices, each exposing raw
 * LBA read/write. Devices are caller-owned (static); the registry just indexes.
 */
#ifndef BLKDEV_H
#define BLKDEV_H
#include <stdint.h>

typedef struct blkdev {
    char      name[16];        /* "sd0", "sd0p1", ... */
    uint32_t  block_size;      /* bytes per block (512) */
    uint32_t  block_count;     /* total blocks (0 = unknown) */
    int     (*read )(struct blkdev *d, uint32_t lba, uint32_t cnt, void *buf);
    int     (*write)(struct blkdev *d, uint32_t lba, uint32_t cnt, const void *buf);
    void     *priv;
} blkdev_t;

int        blkdev_register(blkdev_t *dev);          /* dev must be static; 0=ok */
blkdev_t  *blkdev_find(const char *name);
int        blkdev_count(void);
blkdev_t  *blkdev_at(int i);
int        blkdev_read (blkdev_t *d, uint32_t lba, uint32_t cnt, void *buf);
int        blkdev_write(blkdev_t *d, uint32_t lba, uint32_t cnt, const void *buf);

#endif
