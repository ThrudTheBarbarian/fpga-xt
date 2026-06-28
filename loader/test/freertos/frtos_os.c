/*
 * frtos_os.c — the XTOS syscall layer on the REAL FreeRTOS kernel.
 *
 * - svc #1 dispatch (from the chained vector) with the exit-via-thunk trick: a
 *   yielding op (vTaskDelete) cannot run in the SVC handler (it would nest
 *   svc #0), so exit redirects the task's resume PC to task_exit_thunk, which
 *   runs in task (System-mode) context and deletes cleanly.
 * - spawn (by image or by path via romfs) = load an ET_DYN (xtld) + xTaskCreate.
 * - per-process fd table: stdio (0/1/2) + read-only romfs files (open/read/
 *   close/lseek). waitpid blocks on a per-process semaphore.
 */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <malloc.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "ksys.h"      /* struct k_regs */
#include "xtsys.h"
#include "xtld.h"
#include "romfs.h"
#include "frtos_os.h"

#define MAXPROC 8
#define NFD     8       /* per process; 0/1/2 are stdio */

typedef struct {
    int            open;
    const uint8_t *data;
    uint32_t       size;
    uint32_t       pos;
} fd_t;

typedef struct {
    int               used;
    int               pid;
    TaskHandle_t      task;
    xtld_obj         *obj;
    uintptr_t         entry;
    SemaphoreHandle_t done;
    int               exit_code;
    int               argc;
    char            **argv;
    fd_t              fd[NFD];
} proc_t;

static proc_t g_proc[MAXPROC];
static int    g_next_pid = 1;
static void (*g_console)(const char *, int);

void ksys_set_console(void (*w)(const char *, int)) { g_console = w; }

/* xtld_host.alloc/dealloc — the OS heap (newlib). Real free, so xtld_unload
 * actually reclaims. */
void *frtos_alloc(size_t size, size_t align, void *u) { (void)u; return memalign(align ? align : 16, size); }
void  frtos_free(void *p, void *u) { (void)u; free(p); }

static proc_t *cur_proc(void)
{
    TaskHandle_t t = xTaskGetCurrentTaskHandle();
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].task == t) return &g_proc[i];
    return NULL;
}

/* runs in TASK (System-mode) context — safe to call yielding FreeRTOS APIs */
static void task_exit_thunk(void)
{
    proc_t *p = cur_proc();
    if (p && p->done) xSemaphoreGive(p->done);
    vTaskDelete(NULL);
    for (;;) {}
}

/* ---- file syscalls (non-yielding; romfs is in memory) ------------------ */
static long sys_open(proc_t *p, const char *path)
{
    const uint8_t *data; uint32_t size;
    if (!p || !romfs_lookup(path, &data, &size)) return -1;
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) {
            p->fd[fd] = (fd_t){ .open = 1, .data = data, .size = size, .pos = 0 };
            return fd;
        }
    }
    return -1; /* -EMFILE */
}

static long sys_read(proc_t *p, int fd, void *buf, uint32_t n)
{
    if (fd == 0) return 0;                       /* stdin: EOF for now */
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t *f = &p->fd[fd];
    uint32_t avail = f->size - f->pos;
    if (n > avail) n = avail;
    for (uint32_t i = 0; i < n; i++) ((uint8_t *)buf)[i] = f->data[f->pos + i];
    f->pos += n;
    return (long)n;
}

static long sys_lseek(proc_t *p, int fd, long off, int whence)
{
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t *f = &p->fd[fd];
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0 || np > (long)f->size) return -1;
    f->pos = (uint32_t)np;
    return np;
}

static long do_syscall(uint32_t num, long a0, long a1, long a2)
{
    proc_t *p = cur_proc();
    switch (num) {
    case SYS_write:                                          /* (fd, buf, len) */
        if ((a0 == 1 || a0 == 2) && g_console && a1) { g_console((const char *)a1, (int)a2); return a2; }
        return -1;
    case SYS_getpid: return p ? p->pid : 0;
    case SYS_open:   return sys_open(p, (const char *)a0);   /* (path, flags) */
    case SYS_read:   return sys_read(p, (int)a0, (void *)a1, (uint32_t)a2);
    case SYS_close:  if (p && a0 >= 3 && a0 < NFD) p->fd[a0].open = 0; return 0;
    case SYS_lseek:  return sys_lseek(p, (int)a0, a1, (int)a2);
    default:         return -38;                             /* -ENOSYS */
    }
}

/* called from the chained SVC vector with the saved register block */
void k_syscall_dispatch(struct k_regs *regs)
{
    uint32_t insn = *((volatile uint32_t *)(regs->lr - 4));
    if ((insn & 0x00ffffff) != 1) { regs->r[0] = (uint32_t)-1; return; }

    uint32_t num = regs->r[7];
    if (num == SYS_exit) {
        proc_t *p = cur_proc();
        if (p) p->exit_code = (int)regs->r[0];
        regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;   /* resume in task ctx */
        return;
    }
    regs->r[0] = (uint32_t)do_syscall(num, regs->r[0], regs->r[1], regs->r[2]);
}

/* task body: run constructors + the loaded entry; finish here if it returns */
static void app_main(void *arg)
{
    proc_t *p = (proc_t *)arg;
    xtld_run_init(p->obj);
    ((void (*)(int, char **))p->entry)(p->argc, p->argv);   /* argc/argv */
    if (p->done) xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

/* copy argv (strings + pointer array) into memory owned by the child, since the
 * caller's buffer (e.g. the shell's line) is reused. Returns NULL for argc<=0. */
static char **copy_argv(int argc, char **argv, const xtld_host *host)
{
    if (argc <= 0 || !argv) return NULL;
    uint32_t total = (uint32_t)(argc + 1) * sizeof(char *);
    for (int i = 0; i < argc; i++) total += (uint32_t)strlen(argv[i]) + 1;
    char *block = host->alloc(total, sizeof(char *), host->user);
    if (!block) return NULL;
    char **out = (char **)block;
    char *str = block + (uint32_t)(argc + 1) * sizeof(char *);
    for (int i = 0; i < argc; i++) {
        out[i] = str;
        uint32_t n = (uint32_t)strlen(argv[i]) + 1;
        memcpy(str, argv[i], n);
        str += n;
    }
    out[argc] = NULL;
    return out;
}

int frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv,
                const xtld_host *host)
{
    int slot = -1;
    for (int i = 0; i < MAXPROC; i++) if (!g_proc[i].used) { slot = i; break; }
    if (slot < 0) return -1;
    proc_t *p = &g_proc[slot];

    xtld_obj *obj = NULL; char err[64] = {0};
    int rc = xtld_load(image, len, host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        if (g_console) { g_console("  xtld_load err: ", 17); g_console(err, (int)strlen(err)); g_console("\n", 1); }
        return -1;
    }
    uintptr_t entry = xtld_sym(obj, "_app_entry");
    if (!entry) return -1;

    for (int i = 0; i < NFD; i++) p->fd[i].open = 0;
    p->obj = obj; p->entry = entry; p->exit_code = 0; p->pid = g_next_pid++;
    p->argc = argc; p->argv = copy_argv(argc, argv, host);
    p->done = xSemaphoreCreateBinary();
    if (!p->done) return -1;
    p->used = 1;
    if (xTaskCreate(app_main, "app", 2048, p, 3, &p->task) != pdPASS) {
        vSemaphoreDelete(p->done); p->used = 0; return -1;
    }
    return p->pid;
}

int frtos_spawn_path(const char *path, const xtld_host *host)
{
    return frtos_spawn_argv(path, 0, NULL, host);
}

int frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host)
{
    const uint8_t *data; uint32_t size;
    if (!romfs_lookup(path, &data, &size)) return -1;
    return frtos_spawn(data, size, argc, argv, host);
}

/* xtld_host.resolve: the curated kernel export table — the libc-level symbols
 * the kernel publishes to loaded programs (e.g. gcc emits memcpy for array
 * init). Resolved after the loaded-library registry. */
/* EABI runtime helpers from libgcc (the A9 has no hardware integer divide) */
extern int      __aeabi_idiv(int, int);
extern unsigned __aeabi_uidiv(unsigned, unsigned);
extern void     __aeabi_idivmod(void);
extern void     __aeabi_uidivmod(void);

uintptr_t frtos_ksym(const char *name, void *u)
{
    (void)u;
    if (!strcmp(name, "memcpy"))  return (uintptr_t)memcpy;
    if (!strcmp(name, "memset"))  return (uintptr_t)memset;
    if (!strcmp(name, "memmove")) return (uintptr_t)memmove;
    if (!strcmp(name, "memcmp"))  return (uintptr_t)memcmp;
    if (!strcmp(name, "strlen"))  return (uintptr_t)strlen;
    if (!strcmp(name, "strcmp"))  return (uintptr_t)strcmp;
    if (!strcmp(name, "malloc"))  return (uintptr_t)malloc;
    if (!strcmp(name, "free"))    return (uintptr_t)free;
    if (!strcmp(name, "realloc")) return (uintptr_t)realloc;
    if (!strcmp(name, "calloc"))  return (uintptr_t)calloc;
    if (!strcmp(name, "__aeabi_idiv"))     return (uintptr_t)__aeabi_idiv;
    if (!strcmp(name, "__aeabi_uidiv"))    return (uintptr_t)__aeabi_uidiv;
    if (!strcmp(name, "__aeabi_idivmod"))  return (uintptr_t)__aeabi_idivmod;
    if (!strcmp(name, "__aeabi_uidivmod")) return (uintptr_t)__aeabi_uidivmod;
    return 0;
}

/* xtld_host.open_lib: map a DT_NEEDED soname to /OS/Library/<name> in the romfs */
int frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *u)
{
    (void)u;
    char path[64];
    const char *pfx = "/OS/Library/";
    int i = 0;
    while (pfx[i]) { path[i] = pfx[i]; i++; }
    int j = 0;
    while (name[j] && i < (int)sizeof(path) - 1) path[i++] = name[j++];
    path[i] = 0;
    return romfs_lookup(path, data, len);
}

int frtos_waitpid(int pid)
{
    proc_t *p = NULL;
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].pid == pid) { p = &g_proc[i]; break; }
    if (!p) return -1;

    xSemaphoreTake(p->done, portMAX_DELAY);    /* yields via svc #0 until exit */
    int code = p->exit_code;
    vSemaphoreDelete(p->done);
    p->used = 0;                                 /* reap (image left in bump arena) */
    return code;
}
