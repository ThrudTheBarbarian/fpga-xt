/* main.c — the STM32F411 I/O companion for the Atari-XT motherboard.
 *
 * Responsibilities, in the order they come up during bring-up:
 *   - console + REPL, over SWD (RTT) and over USART2 to the Zynq
 *   - four joystick ports and eight paddle pots
 *   - fan PWM with a tachometer PID loop
 *   - USB host: hub plus HID keyboard and mouse            (task #7)
 *   - SPI slave link to the FPGA, with a doorbell           (task #8)
 *   - Atari SIO host controller on the physical DIN port    (task #10)
 *
 * The loop is a cooperative poll rather than an RTOS: every subsystem here is
 * either interrupt-driven or a short state machine, and the paddle reads want
 * to be revisited quickly rather than on a fixed tick.
 */
#include "board.h"
#include "clock.h"
#include "console.h"
#include "fan.h"
#include "fault.h"
#include "joystick.h"
#include "pots.h"
#include "repl.h"

#define CONTROL_BAUD    115200U

int main(void)
{
    fault_init();
    board_init();
    console_init(CONTROL_BAUD);

    joystick_init();
    pots_init();
    fan_init();

    repl_banner();

    /* Release the USB hub once the rails have settled.  Enumeration itself
     * waits for usb_init() (task #7); this just stops the hub sitting in
     * reset, so a scope on the port shows something sensible today. */
    board_hub_cycle();

    uint32_t last_ms = clock_millis();

    for (;;) {
        repl_poll();
        pots_poll();
        fan_poll();

        uint32_t now = clock_millis();
        if (now != last_ms) {               /* 1 kHz work */
            last_ms = now;
            joystick_poll();
        }
    }
}
