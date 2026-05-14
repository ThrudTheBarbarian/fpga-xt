#pragma once

#include <stdbool.h>

// peri_spi_slave — PIO + C polling-loop pair that services the FPGA
// peri_link's SPI master. Owns one PIO state machine and one core
// (the polling loop runs on core 1; core 0 stays free for joystick /
// POT / SIO / SD service).
//
// Lifecycle:
//   peri_spi_slave_init() — runs on core 0. Loads the PIO program,
//       configures the state machine, sets up GPIOs.
//   peri_spi_slave_run() — entry point handed to multicore_launch_core1().
//       Never returns; runs the RX → decode → TX push loop forever.

void peri_spi_slave_init(void);
void peri_spi_slave_run(void);
