// peri_irq.c — IRQ_OUT drive (M25-3d).

#include "peri_irq.h"

#include "peri_regs.h"

#ifndef PERI_POT_HOST_SIM
#include "pico/stdlib.h"
#include "hardware/gpio.h"
#include "pinmap.h"
#endif

#ifdef PERI_POT_HOST_SIM
static int g_pin_level = 1;            // host sim shadow
#endif

void peri_irq_init(void) {
#ifndef PERI_POT_HOST_SIM
    // Open-drain on the IRQ_OUT pin: configure as output, drive 0
    // when asserting, release (input mode → external pull-up wins)
    // when deasserting. peri_link's spi_irq input has its own
    // pull-up; this side just controls the active-low pull.
    gpio_init(PERI_IRQ_OUT_PIN);
    gpio_set_dir(PERI_IRQ_OUT_PIN, GPIO_IN);   // released by default
    gpio_put(PERI_IRQ_OUT_PIN, 0);              // ready-to-drive value
#endif
    peri_irq_update();
}

void peri_irq_update(void) {
    // Active when any STATUS flag bit is set. STATUS layout (from
    // peri_regs.h): bit 0 = pot_done, bit 1 = sio_rx, bit 2 = sd_done.
    const uint8_t status   = peri_regs_get(PERI_R_STATUS);
    const int     asserted = (status != 0) ? 1 : 0;

#ifdef PERI_POT_HOST_SIM
    g_pin_level = asserted ? 0 : 1;
#else
    if (asserted) {
        gpio_set_dir(PERI_IRQ_OUT_PIN, GPIO_OUT);   // drive low
    } else {
        gpio_set_dir(PERI_IRQ_OUT_PIN, GPIO_IN);    // release
    }
#endif
}

#ifdef PERI_POT_HOST_SIM
int peri_irq_host_pin_level(void) { return g_pin_level; }
#endif
