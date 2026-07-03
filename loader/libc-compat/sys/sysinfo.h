/* libc-compat: sys/sysinfo.h — the shim answers from the wall clock and
 * static memory totals (toybox ps/top want uptime + totalram) */
#ifndef _XT_COMPAT_SYS_SYSINFO_H
#define _XT_COMPAT_SYS_SYSINFO_H

struct sysinfo {
    long          uptime;
    unsigned long loads[3];
    unsigned long totalram;
    unsigned long freeram;
    unsigned long sharedram;
    unsigned long bufferram;
    unsigned long totalswap;
    unsigned long freeswap;
    unsigned short procs;
    unsigned long totalhigh;
    unsigned long freehigh;
    unsigned int  mem_unit;
};

#ifdef __cplusplus
extern "C"
#endif
int sysinfo(struct sysinfo *info);

#endif
