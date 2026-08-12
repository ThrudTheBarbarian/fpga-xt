/* main.c — the STM32F411 I/O companion for the Atari-XT motherboard.
 *
 * Responsibilities, in the order they come up during bring-up:
 *   - console + REPL, over SWD (RTT) and over USART2 to the Zynq
 *   - four joystick ports and eight paddle pots
 *   - fan PWM with a tachometer PID loop
 *   - USB host: hub plus HID keyboard and mouse
 *   - SPI slave link to the FPGA, with a doorbell
 *   - Atari SIO host controller on the physical DIN port    (task #10)
 *
 * The loop is a cooperative poll rather than an RTOS: every subsystem here is
 * either interrupt-driven or a short state machine.  Anything with real timing
 * requirements — the paddle sampler, the tachometer, the console UART — lives in
 * an interrupt precisely so the loop's latency cannot reach it.
 */
#include "board.h"
#include "clock.h"
#include "console.h"
#include "fan.h"
#include "fault.h"
#include "joystick.h"
#include "pots.h"
#include "repl.h"
#include "spi_link.h"
#include "usb.h"

#define CONTROL_BAUD    115200U

int main(void)
{
    fault_init();
    board_init();
    console_init(CONTROL_BAUD);

    joystick_init();
    pots_init();
    fan_init();
    spi_link_init();

    /* 24 MHz on PA8 before the hub leaves reset, in case it is being clocked
     * from here rather than from Y2 (see motherboard/README.md). */
    clock_mco_24mhz(1);

    repl_banner();

    /* usb_init() cycles the hub itself, and refuses to start at all if the
     * crystal did not come up — 48 MHz off the HSI is not within USB spec. */
    usb_init();

    uint32_t last_ms = clock_millis();

    for (;;) {
        repl_poll();
        usb_task();
        fan_poll();

        uint32_t now = clock_millis();
        if (now != last_ms) {               /* 1 kHz work */
            last_ms = now;
            joystick_poll();
        }
    }
}
