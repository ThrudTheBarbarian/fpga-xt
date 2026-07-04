/* sys/timex.h — minimal adjtimex surface for toybox sntp. XTOS has no slewing
 * clock (the wall time is an offset from the A9 global timer), so a single-shot
 * offset is applied immediately rather than gradually; the periodic fields are
 * accepted and ignored. */
#ifndef _XT_COMPAT_SYS_TIMEX_H
#define _XT_COMPAT_SYS_TIMEX_H

#include <time.h>

struct timex {
    int      modes;      /* mode selector (ADJ_* below) */
    long     offset;     /* time offset (microseconds) */
    long     freq;
    long     maxerror;
    long     esterror;
    int      status;
    long     constant;
    long     precision;
    long     tolerance;
    long     tick;
};

#define ADJ_OFFSET             0x0001
#define ADJ_FREQUENCY          0x0002
#define ADJ_OFFSET_SINGLESHOT  0x8001

#define TIME_OK 0

int adjtimex(struct timex *buf);

#endif
