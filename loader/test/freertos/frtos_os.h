/* XTOS-on-FreeRTOS OS layer (frtos_os.c). */
#ifndef FRTOS_OS_H
#define FRTOS_OS_H
#include <stdint.h>
#include "xtld.h"
void ksys_set_console(void (*w)(const char *, int));
int  frtos_spawn(const uint8_t *image, uint32_t len, const xtld_host *host);
int  frtos_spawn_path(const char *path, const xtld_host *host);
int  frtos_waitpid(int pid);
#endif
