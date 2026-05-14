// rp_antic_peri — main. Brings up the system clock, USB CDC for the
// banner, and hands the SPI slave polling loop off to core 1. Core 0
// stays free for POT scan / SIO / SD service (M25-3b/c + M25-4 + M25-5).
// Joystick is now handled by the PCAL9722 (linked directly to the
// FPGA), so the peri-RP doesn't see joystick GPIO at all.
//
// M25-3a ship criterion: UF2 flashes, USB CDC connects, banner prints
// the configured sys_clk and the SPI slave reaches its core-1 loop.
// Functional verification of the SPI link itself happens on hardware
// against the FPGA-side peri_link / peri_bridge.

#include <stdio.h>
#include <stdint.h>

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/clocks.h"

#include "clock.h"
#include "peri_regs.h"
#include "peri_spi_slave.h"
#include "peri_pot.h"
#include "peri_irq.h"
#include "peri_sio.h"
#include "peri_sd.h"

static void print_banner(void) {
    const uint32_t sys_hz = clock_get_hz(clk_sys);
    printf("\n");
    printf("rp_antic_peri — fpga-antic peripheral RP (POT/SIO/SD)\n");
    printf("clock: %s\n", clock_mode_label());
    printf("sys_clk read-back: %lu Hz\n", (unsigned long)sys_hz);
    printf("SPI slave: SCK=GPIO%u MOSI=GPIO%u MISO=GPIO%u CS=GPIO%u IRQ=GPIO%u\n",
           10u, 11u, 12u, 13u, 14u);
    printf("\n");
    fflush(stdout);
}

int main(void) {
    clock_init();
    stdio_init_all();

    sleep_ms(2000);   // generous USB-enumeration sleep

    print_banner();

    // Bring up register file + SPI slave + POT scanner on core 0,
    // then launch the tight RX/TX polling loop on core 1.
    peri_regs_init();
    peri_pot_init();
    peri_sio_init();
    peri_sd_init();
    peri_irq_init();
    peri_spi_slave_init();
    multicore_launch_core1(peri_spi_slave_run);

    // Core 0 main loop: poll the POT scanner for completion + commit
    // results into peri_regs. M25-4 / M25-5 will add SIO + SD service
    // calls alongside.
    for (;;) {
        (void)peri_pot_service();
        (void)peri_sio_service();
        (void)peri_sd_service();
        // Light cooperative pacing — services are ~10 cycles each
        // when no work is pending, so even a tight loop is cheap.
    }
}
