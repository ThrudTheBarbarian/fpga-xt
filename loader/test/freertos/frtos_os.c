/*
 * frtos_os.c — the XTOS syscall layer on the REAL FreeRTOS kernel.
 *
 * - svc #1 dispatch (called from the chained vector) with the exit-via-thunk
 *   trick: a yielding op (vTaskDelete) cannot run in the SVC handler (it would
 *   nest svc #0), so exit redirects the task's resume PC to task_exit_thunk,
 *   which runs in task (System-mode) context and deletes cleanly.
 * - spawn = load an ET_DYN (xtld) + xTaskCreate; the task runs _app_entry, whose
 *   svc #1 traps here. waitpid blocks on a per-process semaphore.
 *
 * This is the FreeRTOS counterpart of the bare-metal kernel/ksys.c.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "ksys.h"      /* struct k_regs */
#include "xtsys.h"
#include "xtld.h"
#include "frtos_os.h"

#define MAXPROC 8
typedef struct {
    int               used;
    int               pid;
    TaskHandle_t      task;
    xtld_obj         *obj;
    uintptr_t         entry;
    SemaphoreHandle_t done;
    int               exit_code;
} proc_t;

static proc_t g_proc[MAXPROC];
static int    g_next_pid = 1;
static void (*g_console)(const char *, int);

void ksys_set_console(void (*w)(const char *, int)) { g_console = w; }

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

/* non-yielding syscalls return a value here; exit/spawn are handled in dispatch */
static long do_syscall(uint32_t num, long a0, long a1, long a2)
{
    switch (num) {
    case SYS_write:  if (g_console && a1) g_console((const char *)a1, (int)a2); return a2;
    case SYS_getpid: { proc_t *p = cur_proc(); return p ? p->pid : 0; }
    default:         return -38; /* -ENOSYS */
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
        regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;  /* resume in task ctx */
        return;
    }
    regs->r[0] = (uint32_t)do_syscall(num, regs->r[0], regs->r[1], regs->r[2]);
}

/* the task body: run constructors + the loaded entry; if it returns without
 * calling exit(), finish here (task context) */
static void app_main(void *arg)
{
    proc_t *p = (proc_t *)arg;
    xtld_run_init(p->obj);
    ((void (*)(void))p->entry)();
    if (p->done) xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

int frtos_spawn(const uint8_t *image, uint32_t len, const xtld_host *host)
{
    int slot = -1;
    for (int i = 0; i < MAXPROC; i++) if (!g_proc[i].used) { slot = i; break; }
    if (slot < 0) return -1;
    proc_t *p = &g_proc[slot];

    xtld_obj *obj = NULL; char err[64] = {0};
    if (xtld_load(image, len, host, &obj, err, sizeof err) != XTLD_OK) return -1;
    uintptr_t entry = xtld_sym(obj, "_app_entry");
    if (!entry) return -1;

    p->obj = obj; p->entry = entry; p->exit_code = 0; p->pid = g_next_pid++;
    p->done = xSemaphoreCreateBinary();
    if (!p->done) return -1;
    p->used = 1;
    if (xTaskCreate(app_main, "app", 2048, p, 3, &p->task) != pdPASS) {
        vSemaphoreDelete(p->done); p->used = 0; return -1;
    }
    return p->pid;
}

int frtos_waitpid(int pid)
{
    proc_t *p = NULL;
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].pid == pid) { p = &g_proc[i]; break; }
    if (!p) return -1;

    xSemaphoreTake(p->done, portMAX_DELAY);   /* yields via svc #0 until exit */
    int code = p->exit_code;
    vSemaphoreDelete(p->done);
    p->used = 0;                                /* reap (image left in bump arena) */
    return code;
}
