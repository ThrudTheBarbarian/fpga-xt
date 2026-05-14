// Clock initialisation for rp_antic_peri. Same vreg + QMI walk-up
// pattern as rp_antic_video; this firmware just defaults to the
// no-walk-up 252 MHz setpoint.

#include "clock.h"

#include "pico/stdlib.h"
#include "hardware/clocks.h"

#if RP_PERI_NEEDS_VREG_WALKUP
#include "hardware/sync.h"
#include "hardware/vreg.h"
#include "hardware/structs/qmi.h"
#include "hardware/regs/addressmap.h"

#if RP_PERI_SYS_MHZ <= 360
#define RP_PERI_VREG  VREG_VOLTAGE_1_35
#elif RP_PERI_SYS_MHZ <= 432
#define RP_PERI_VREG  VREG_VOLTAGE_1_40
#elif RP_PERI_SYS_MHZ <= 480
#define RP_PERI_VREG  VREG_VOLTAGE_1_50
#elif RP_PERI_SYS_MHZ <= 528
#define RP_PERI_VREG  VREG_VOLTAGE_1_60
#else
#error "RP_PERI_SYS_MHZ exceeds 528; refusing to set vreg blindly."
#endif

static uint32_t qmi_clkdiv_for_sys_hz(uint32_t sys_hz) {
    const uint32_t SCK_MAX_HZ = 90u * 1000u * 1000u;
    uint32_t d = (sys_hz + SCK_MAX_HZ - 1u) / SCK_MAX_HZ;
    if (d < 2u) d = 2u;
    return d;
}

static void __no_inline_not_in_flash_func(qmi_set_m0_timing)(uint32_t clkdiv,
                                                              uint32_t rxdelay) {
    uint32_t save = save_and_disable_interrupts();
    qmi_hw->m[0].timing =
        (1u      << QMI_M0_TIMING_COOLDOWN_LSB) |
        (rxdelay << QMI_M0_TIMING_RXDELAY_LSB)  |
        (clkdiv  /* LSB = 0 */);
    (void)*((volatile uint32_t *)XIP_BASE);
    __dmb();
    restore_interrupts(save);
}
#endif

void clock_init(void) {
#if RP_PERI_NEEDS_VREG_WALKUP
    const uint32_t clkdiv  = qmi_clkdiv_for_sys_hz(RP_PERI_SYS_HZ);
    const uint32_t rxdelay = (clkdiv <= 3u) ? 1u : clkdiv;
    qmi_set_m0_timing(clkdiv, rxdelay);

    vreg_disable_voltage_limit();
    vreg_set_voltage(RP_PERI_VREG);
    busy_wait_us(500);
#endif
    set_sys_clock_khz(RP_PERI_SYS_HZ / 1000u, true);
}

#define _MK_LABEL(MHZ, V) #MHZ " MHz (vreg " V ")"
#define _LBL_FOR(MHZ, V)  _MK_LABEL(MHZ, V)

const char *clock_mode_label(void) {
#if !RP_PERI_NEEDS_VREG_WALKUP
    return _LBL_FOR(RP_PERI_SYS_MHZ, "default, no QMI retune");
#elif RP_PERI_SYS_MHZ <= 360
    return _LBL_FOR(RP_PERI_SYS_MHZ, "1.35 V + QMI retune");
#elif RP_PERI_SYS_MHZ <= 432
    return _LBL_FOR(RP_PERI_SYS_MHZ, "1.40 V + QMI retune");
#elif RP_PERI_SYS_MHZ <= 480
    return _LBL_FOR(RP_PERI_SYS_MHZ, "1.50 V + QMI retune");
#else
    return _LBL_FOR(RP_PERI_SYS_MHZ, "1.60 V + QMI retune, near datasheet max");
#endif
}
