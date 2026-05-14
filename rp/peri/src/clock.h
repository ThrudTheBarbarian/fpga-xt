#pragma once

#include <stdint.h>

// sys_clk target for rp_antic_peri. Configured at build time via
// -DRP_PERI_SYS_MHZ=<n>. Default 252 MHz — the SPI slave PIO needs at
// most ~10× the FPGA's 5 MHz SPI rate to keep the read-response
// latency budget healthy. Going higher (360+ MHz) buys headroom but
// adds the vreg walk-up + QMI flash retune dance.
//
// At ≤ 252 MHz the chip runs at default vreg with no QMI flash retune.
// Above 252 MHz the vreg level is auto-selected from the target.

#ifndef RP_PERI_SYS_MHZ
#define RP_PERI_SYS_MHZ 252
#endif

#define RP_PERI_SYS_HZ   ((uint32_t)RP_PERI_SYS_MHZ * 1000000u)

#define RP_PERI_NEEDS_VREG_WALKUP  (RP_PERI_SYS_MHZ > 252)

void clock_init(void);

const char *clock_mode_label(void);
