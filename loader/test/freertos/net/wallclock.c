/* wallclock.c — real time for the kernel: SNTP hands us the unix epoch once
 * (and every re-sync), we keep it as an offset from the boot-relative global
 * timer. gettimeofday and FatFs timestamps read through here; unsynced = 0
 * (callers keep their old behaviour until the first sync). */
#include <stdint.h>

extern void gtimer_timeofday(uint32_t *sec, uint32_t *usec);
extern void puts0(const char *);
extern void putu(unsigned);

static volatile uint32_t g_wall_off;      /* unix_sec - uptime_sec; 0 = unsynced */

void xt_wallclock_set(uint32_t unix_sec)
{
    uint32_t s, u;
    gtimer_timeofday(&s, &u);
    int first = (g_wall_off == 0);
    g_wall_off = unix_sec - s;
    if (first) {
        /* one civil-time line so the boot log shows the sync happened */
        uint32_t days = unix_sec / 86400u, rem = unix_sec % 86400u;
        /* days since 1970-01-01 -> y/m/d (Howard Hinnant's civil_from_days) */
        uint32_t z = days + 719468u;
        uint32_t era = z / 146097u, doe = z % 146097u;
        uint32_t yoe = (doe - doe / 1460u + doe / 36524u - doe / 146096u) / 365u;
        uint32_t y = yoe + era * 400u, doy = doe - (365u * yoe + yoe / 4u - yoe / 100u);
        uint32_t mp = (5u * doy + 2u) / 153u, d = doy - (153u * mp + 2u) / 5u + 1u;
        uint32_t m = mp < 10u ? mp + 3u : mp - 9u;
        if (m <= 2u) y++;
        puts0("[net] time "); putu(y); puts0("-"); putu(m); puts0("-"); putu(d);
        puts0(" "); putu(rem / 3600u); puts0(":"); putu((rem / 60u) % 60u); puts0(" UTC\n");
    }
}

uint32_t xt_wallclock_unix(void)          /* 0 until the first SNTP sync */
{
    if (!g_wall_off) return 0;
    uint32_t s, u;
    gtimer_timeofday(&s, &u);
    return s + g_wall_off;
}

uint32_t xt_wallclock_off(void) { return g_wall_off; }
