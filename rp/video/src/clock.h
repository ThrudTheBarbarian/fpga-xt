#pragma once

#include <stdint.h>

// sys_clk target. Configured at build time via -DRP_VIDEO_SYS_MHZ=<n>.
// Default 360 MHz with vreg + QMI retune — the rp-antic-validated
// 360 MHz baseline (matches the FPGA<->RP bus prefetch budget).
//
// At ≤ 252 MHz the chip runs at default vreg with no QMI flash retune.
// Higher targets trigger the vreg walk-up + QMI retune dance, with the
// vreg level auto-selected from the target. See ../../docs/roadmap.md.
//
// Forgetting any step (vreg walk-up before set_sys_clock_khz, or QMI
// retune to keep flash SCK below the W25Q128JV 133 MHz spec) causes
// silent boot hang — USB CDC never appears. Reflash with a lower
// target to recover.

#ifndef RP_VIDEO_SYS_MHZ
#define RP_VIDEO_SYS_MHZ 360
#endif

#define RP_VIDEO_SYS_HZ   ((uint32_t)RP_VIDEO_SYS_MHZ * 1000000u)

#define RP_VIDEO_NEEDS_VREG_WALKUP  (RP_VIDEO_SYS_MHZ > 252)

void clock_init(void);

// Human-readable description of the active clock setpoint, used in
// the boot banner. Resolved at compile time.
const char *clock_mode_label(void);
