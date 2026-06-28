/* ksys.c — see ksys.h. Portable kernel syscall gateway + spawn. */
#include "ksys.h"
#include "xtsys.h"

static k_jmpbuf g_ret;          /* where exit() longjmps back to */
static int      g_exit_code;
static int      g_cur_pid;
static void   (*g_console)(const char *, int);

void ksys_set_console(void (*w)(const char *, int)) { g_console = w; }

long k_syscall(uint32_t num, long a0, long a1, long a2, long a3, long a4, long a5)
{
    (void)a3; (void)a4; (void)a5;
    switch (num) {
    case SYS_write:                                   /* (fd, buf, len) */
        if (g_console && a1) g_console((const char *)a1, (int)a2);
        return a2;
    case SYS_getpid:
        return g_cur_pid;
    case SYS_exit:                                     /* (code) — no return */
        g_exit_code = (int)a0;
        my_longjmp(g_ret, 1);
        return 0;                                      /* unreachable */
    default:
        return -38;                                    /* -ENOSYS */
    }
}

/* called from the asm svc handler with a pointer to the saved register block */
void k_syscall_dispatch(struct k_regs *regs)
{
    /* the gateway is `svc #1`; decode the immediate from the trapping
     * instruction (svc #0 is the FreeRTOS port's, per dynamic-loading.md §7). */
    uint32_t insn = *((volatile uint32_t *)(regs->lr - 4));
    if ((insn & 0x00ffffff) != 1) {
        if (g_console) g_console("kernel: bad svc immediate\n", 26);
        return;
    }
    long ret = k_syscall(regs->r[7],
                         regs->r[0], regs->r[1], regs->r[2],
                         regs->r[3], regs->r[4], regs->r[5]);
    regs->r[0] = (uint32_t)ret;
}

int k_spawn(const uint8_t *image, uint32_t len, const xtld_host *host)
{
    xtld_obj *obj = NULL;
    char err[64] = {0};
    int rc = xtld_load(image, len, host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        if (g_console) g_console("spawn: load failed\n", 19);
        return -1;
    }
    xtld_run_init(obj);

    uintptr_t entry = xtld_sym(obj, "_app_entry");
    if (!entry) {
        if (g_console) g_console("spawn: no _app_entry\n", 21);
        return -1;
    }

    void *ustack = host->alloc(0x10000, 16, host->user);   /* 64 KB user stack */
    if (!ustack) return -1;

    g_cur_pid   = 1;          /* first (and only) process for now */
    g_exit_code = 0;
    if (my_setjmp(g_ret) == 0)
        enter_user(entry, 0, NULL, (char *)ustack + 0x10000);
    /* arrives here either via exit()'s longjmp or a normal return (code 0) */
    return g_exit_code;
}
