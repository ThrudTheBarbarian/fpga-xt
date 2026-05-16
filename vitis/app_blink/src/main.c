/*
 * app_blink/main.c — fpga-xt bring-up Phase 3 hello world.
 *
 * Smallest possible Zynq-7000 bare-metal app that proves:
 *   1. FSBL ran, jumped to us, and we're executing from DDR3.
 *   2. The PS UART is alive — "fpga-xt boot OK" reaches the serial
 *      console.
 *   3. We can read the global timer and run a wall-clock blink loop.
 *
 * No GPIO toggling yet — the on-board PS-side LEDs sit on MIO bits
 * that vary between Z-Turn revisions.  Once we lock down the carrier
 * wiring we'll extend this to drive a real MIO LED instead of the
 * UART-only heartbeat printf.  Until then, watching the UART line
 * for the period "tick" messages is the proof-of-life signal.
 *
 * Expected output (115200 8N1):
 *
 *     fpga-xt boot OK
 *     tick 0
 *     tick 1
 *     tick 2
 *     ...
 *
 * Build: `vitis -s ../scripts/create_platform.py` (one-time platform
 * setup), then `vitis -s ../scripts/build_app.py` (or rebuild inside
 * the IDE).  Result: workspace/app_blink/build/app_blink.elf.
 */

#include <stdint.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "sleep.h"

/* sleep() comes from the standalone BSP's sleep.h.  No xtime_l.h
 * dependency — we don't read the global timer directly, just block
 * for whole seconds.
 */

int main(void)
{
    /* The standalone BSP's print() and xil_printf() route to whichever
     * UART the Vitis platform was generated against.  On Z-Turn that's
     * UART1 via the on-SOM FTDI bridge.
     */
    xil_printf("\r\n");
    xil_printf("fpga-xt boot OK\r\n");
    xil_printf("build: " __DATE__ " " __TIME__ "\r\n");

    uint32_t tick = 0;
    while (1) {
        xil_printf("tick %u\r\n", tick++);
        sleep(1);   /* 1 second */
    }

    /* Unreachable, but make the compiler happy. */
    return 0;
}
