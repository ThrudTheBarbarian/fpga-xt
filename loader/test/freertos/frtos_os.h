/* XTOS-on-FreeRTOS OS layer (frtos_os.c). */
#ifndef FRTOS_OS_H
#define FRTOS_OS_H
#include <stdint.h>
#include <stddef.h>
#include "xtld.h"
void ksys_set_console(void (*w)(const char *, int));
void *frtos_alloc(size_t size, size_t align, void *user);
void  frtos_free(void *p, void *user);
int  frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv, const xtld_host *host);
int  frtos_spawn_path(const char *path, const xtld_host *host);
int  frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host);
int  frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *user);
uintptr_t frtos_ksym(const char *name, void *user);
int  frtos_waitpid(int pid);
#endif
