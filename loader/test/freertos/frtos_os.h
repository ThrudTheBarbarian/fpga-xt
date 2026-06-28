/* XTOS-on-FreeRTOS OS layer (frtos_os.c). */
#ifndef FRTOS_OS_H
#define FRTOS_OS_H
#include <stdint.h>
#include <stddef.h>
#include "xtld.h"

/* T2-b: per-process heap window (mapped per-process to private physical by vm.c;
 * libc's _sbrk hands out of it for the current process). 1 section for now. */
#define XTOS_HEAP_VA   0x10000000u
#define XTOS_HEAP_SIZE 0x00100000u
/* T2-c: synthetic copy-on-write demo window (one page, shared-RO -> private on
 * first write). The kernel never touches it, so no global TLB shadow on HW. */
#define XTOS_COW_VA    0x11000000u
#define XTOS_COW_SIZE  0x00001000u
void vm_set_libc(uintptr_t wva, uint32_t wsize, const void *snapshot);
void vm_cow_init(void);
void vm_cow_register(uint32_t va, uint32_t size, uint32_t src);
uint32_t vm_cow_count(void);
int  vm_cow_map(int idx, uint32_t va);
int  vm_demand_map(int idx, uint32_t va);

void ksys_set_console(void (*w)(const char *, int));
void *frtos_alloc(size_t size, size_t align, void *user);
void  frtos_free(void *p, void *user);
void  frtos_activate_libc(xtld_obj *libc);   /* after the loader loads libc.so */
int  frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv, const xtld_host *host);
int  frtos_spawn_path(const char *path, const xtld_host *host);
int  frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host);
int  frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *user);
uintptr_t frtos_ksym(const char *name, void *user);
int  frtos_waitpid(int pid);
#endif
