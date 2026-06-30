/* blkdev.c — block-device registry (see blkdev.h). */
#include "blkdev.h"

#define MAXBLK 8
static blkdev_t *g_dev[MAXBLK];
static int       g_n;

static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == 0 && *b == 0;
}

int blkdev_register(blkdev_t *d)
{
    if (!d || g_n >= MAXBLK) return -1;
    g_dev[g_n++] = d;
    return 0;
}

blkdev_t *blkdev_find(const char *name)
{
    for (int i = 0; i < g_n; i++)
        if (streq(g_dev[i]->name, name)) return g_dev[i];
    return 0;
}

int       blkdev_count(void)      { return g_n; }
blkdev_t *blkdev_at(int i)        { return (i >= 0 && i < g_n) ? g_dev[i] : 0; }

int blkdev_read(blkdev_t *d, uint32_t lba, uint32_t cnt, void *buf)
{
    return (d && d->read) ? d->read(d, lba, cnt, buf) : -1;
}
int blkdev_write(blkdev_t *d, uint32_t lba, uint32_t cnt, const void *buf)
{
    return (d && d->write) ? d->write(d, lba, cnt, buf) : -1;
}
