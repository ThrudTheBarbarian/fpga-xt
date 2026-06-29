/*
 * ksys.h — XTOS kernel syscall gateway + spawn (portable core).
 *
 * The svc handler (arch asm) saves the caller's registers and calls
 * k_syscall_dispatch(); spawn loads an ET_DYN via xtld, runs it, and returns
 * its exit code. Console output goes through a registered callback so this core
 * stays free of the testbed's I/O. Becomes XTOS kernel code; the FreeRTOS port
 * will swap spawn's "run to exit" for xTaskCreate + a real process table.
 */
#ifndef KSYS_H
#define KSYS_H

#include <stdint.h>
#include "xtld.h"

/* register block pushed by the svc handler: r0..r12 then lr_svc */
struct k_regs { uint32_t r[13]; uint32_t lr; };

/* C dispatch called from the asm svc handler. Returns 1 if the resumed PC must run
 * at PL1 (the FreeRTOS testbed uses this for the exit thunk of a PL0 task); 0 else. */
int   k_syscall_dispatch(struct k_regs *regs);

/* the syscall implementations */
long  k_syscall(uint32_t num, long a0, long a1, long a2, long a3, long a4, long a5);

/* load + run an ET_DYN image; returns its exit() code (or <0 on load failure) */
int   k_spawn(const uint8_t *image, uint32_t len, const xtld_host *host);

/* register the console writer used by SYS_write */
void  ksys_set_console(void (*w)(const char *, int));

/* ---- arch asm (kernel/arch_arm.S) -------------------------------------- */
typedef uint32_t k_jmpbuf[10];           /* r4-r11, sp, lr */
int   my_setjmp(k_jmpbuf);
void  my_longjmp(k_jmpbuf, int val);
void  enter_user(uintptr_t entry, int argc, char **argv, void *sp_top);
void  set_vbar(void *vectors);
extern uint32_t vector_table[];

#endif
