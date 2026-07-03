/* libc-compat: sys/resource.h — full replacement (newlib's has only a 2-field
 * rusage; guarding with its own include guard keeps it out). The shim's
 * getrusage/wait4 zero-fill the accounting fields; getrlimit reports
 * "unlimited" and setrlimit refuses. */
#ifndef _SYS_RESOURCE_H_
#define _SYS_RESOURCE_H_

#include <sys/time.h>
#include <sys/types.h>

#define RUSAGE_SELF     0
#define RUSAGE_CHILDREN (-1)

struct rusage {
    struct timeval ru_utime;
    struct timeval ru_stime;
    long ru_maxrss;
    long ru_ixrss;
    long ru_idrss;
    long ru_isrss;
    long ru_minflt;
    long ru_majflt;
    long ru_nswap;
    long ru_inblock;
    long ru_oublock;
    long ru_msgsnd;
    long ru_msgrcv;
    long ru_nsignals;
    long ru_nvcsw;
    long ru_nivcsw;
};

typedef unsigned long rlim_t;
#define RLIM_INFINITY ((rlim_t)~0ul)

struct rlimit {
    rlim_t rlim_cur;
    rlim_t rlim_max;
};

#define RLIMIT_CPU     0
#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS      9
#define RLIMIT_LOCKS   10

#define PRIO_PROCESS 0
#define PRIO_PGRP    1
#define PRIO_USER    2

#ifdef __cplusplus
extern "C" {
#endif
int getrusage(int who, struct rusage *ru);
int getrlimit(int resource, struct rlimit *rlp);
int setrlimit(int resource, const struct rlimit *rlp);
int getpriority(int which, id_t who);
int setpriority(int which, id_t who, int prio);
pid_t wait3(int *status, int options, struct rusage *ru);
pid_t wait4(pid_t pid, int *status, int options, struct rusage *ru);
#ifdef __cplusplus
}
#endif

#endif /* !_SYS_RESOURCE_H_ */
