/* vfs_lockfs.c — advisory lock filesystem, mounted /OS/Var/Locks.
 *
 * A lock IS a file.  open(name, O_CREAT) acquires an exclusive advisory lock on
 * <name>; if another holder has it the open fails (-> SQLITE_BUSY at the caller).
 * close() releases it.  A plain open (no O_CREAT) succeeds only when the lock is
 * held and reads back the holder's task id, so `cat /OS/Var/Locks/Registry.db`
 * says who owns it and `ls /OS/Var/Locks` (later) lists the live locks.
 *
 * Reap-safe by construction: the acquiring fd lives in the holder's fd table, so
 * a crashed or killed holder's lock frees itself — reap closes its fds, which
 * calls our close and drops the lock.  No stale .lock files to garbage-collect.
 *
 * Backs SQLite's cross-process VFS locking (sqlite_vfs.c) so the config DB
 * (/OS/Etc/Registry.db) can be a living, multi-writer store.  Coarse by design:
 * every lock level maps to one whole-file exclusive lock, so a SHARED reader
 * serialises against an EXCLUSIVE writer.  Fine for an occasionally-touched
 * config DB; a shared/exclusive split can follow if a hot DB ever needs it.
 *
 * Each lock file is presented as an IN-MEMORY fd (f->data = the holder-id string):
 * reads and closes then stay inline and never touch the SD page store — a lock is
 * a few bytes, not a paged backing-store file.  Opens run in the fs task, so the
 * current task is not the caller; sys_open stashes the caller's id in g_fs_client
 * for us to record as the holder.
 */
#include "vfs.h"
#include <stdint.h>

extern int g_fs_client;                  /* task id of the in-flight open (frtos_os.c) */

#define NLOCKS   16
#define LK_NAME  64

typedef struct {
    int       used;
    char      name[LK_NAME];             /* rel path within the mount, e.g. "/Registry.db" */
    int       holder;                    /* client task id that acquired it */
    vfs_file *owner;                     /* the acquiring fd — only its close releases */
    char      idstr[16];                 /* "<holder>\n" — the read-back content */
    uint32_t  idlen;
} lock_t;

static lock_t g_locks[NLOCKS];

static int streq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }

static lock_t *find(const char *name)
{
    for (int i = 0; i < NLOCKS; i++)
        if (g_locks[i].used && streq(g_locks[i].name, name)) return &g_locks[i];
    return 0;
}

/* render the holder task id as decimal text ("5\n") into the lock's read-back buffer */
static void set_idstr(lock_t *lk)
{
    int v = lk->holder, neg = v < 0, k = 0;
    uint32_t u = neg ? (uint32_t)(-v) : (uint32_t)v;
    char d[12]; int dn = 0;
    do { d[dn++] = (char)('0' + u % 10); u /= 10; } while (u);
    if (neg) lk->idstr[k++] = '-';
    while (dn) lk->idstr[k++] = d[--dn];
    lk->idstr[k++] = '\n'; lk->idstr[k] = 0;
    lk->idlen = (uint32_t)k;
}

static void lk_close(vfs_file *f)
{
    lock_t *lk = (lock_t *)f->priv;
    if (lk && lk->owner == f) { lk->used = 0; lk->owner = 0; lk->holder = -1; }
}

static int lk_open(vfs_mount *m, const char *path, int flags, vfs_file *f)
{
    (void)m;
    lock_t *lk = find(path);
    if (flags & VFS_O_CREAT) {                        /* acquire (exclusive) */
        if (lk) return -1;                            /* already held -> busy */
        for (int i = 0; i < NLOCKS; i++) if (!g_locks[i].used) { lk = &g_locks[i]; break; }
        if (!lk) return -1;                           /* table full */
        lk->used = 1; lk->holder = g_fs_client; lk->owner = f;
        int j = 0; while (path[j] && j < LK_NAME - 1) { lk->name[j] = path[j]; j++; } lk->name[j] = 0;
        set_idstr(lk);
    } else {                                          /* probe / read holder */
        if (!lk) return -1;                           /* not held -> "no such lock" */
    }
    /* in-memory fd: reads copy from f->data (holder string) with no page-store hop,
     * and close stays inline so the owner's release runs in its own context. */
    f->priv = lk; f->data = lk->idstr; f->size = lk->idlen; f->pos = 0;
    f->read = 0; f->write = 0; f->lseek = 0; f->close = lk_close;
    return 0;
}

static vfs_fs lockfs_fs = { "lockfs", lk_open, 0 /* reentrant: a pure in-memory table */ };

void vfs_lockfs_init(void) { vfs_register_fs(&lockfs_fs); }
