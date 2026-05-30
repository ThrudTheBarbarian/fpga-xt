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
#include "xil_io.h"
#include "sleep.h"

#include "xt_blitter.h"

/* Release the SiI9022A HDMI transmitter from reset.
 *
 * On the Z-Turn V2 the SiI9022's RESET# (SIL9022_RESETn, schematic net
 * PS_501_RESET_OUTn) is driven from the PS, not the PL — so the PL
 * hdmi_config can only program the chip over I2C once the PS has
 * deasserted this reset.  MIO[51] (PS bank 501, pin B9) is the GPIO that
 * gates it; driving it high releases the chip.
 *
 * Sequence lifted verbatim from MyIR's proven sii9022_init() (which drives
 * HDMI on this board).  The two EMIO bank-2 writes are inert in our config
 * (we don't route EMIO GPIO to the PL); the MASK_DATA_1_MSW write that
 * drives MIO[51] high is the effective reset release.
 */
static void sii9022_reset_release(void)
{
    Xil_Out32(0xE000A000 + 0x244, 0x00080000); /* DIRM_2 (EMIO bank2): bit19 = output     */
    Xil_Out32(0xE000A000 + 0x248, 0x00080000); /* OEN_2  (EMIO bank2): bit19 = out enabled */
    Xil_Out32(0xE000A000 + 0x00C, 0xFFF70008); /* MASK_DATA_1_MSW: drive MIO[51] high (RESET# deassert) */
    usleep(2500);
}

/* Direct write to UART1's TX FIFO, bypassing the BSP STDOUT routing
 * entirely.  Diagnostic: if this string appears on serial but the
 * xil_printf() banner below does NOT, the BSP STDOUT isn't mapped to
 * UART1 (the platform picked the wrong/none UART).  If neither appears,
 * the app isn't running at all (FSBL handoff failed).  UART1 @0xE0001000:
 * Channel Status Reg (0x2C) bit4 = TXFULL; TX/RX FIFO @0x30. */
static void uart1_raw_puts(const char *s)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    /* ps7_init sets baud/mode, but a non-debug FSBL may leave the TX path
     * disabled — so explicitly reset the TX FIFO and enable TX before
     * writing.  CR @0x00: bit1 = TXRES (self-clearing), bit4 = TXEN. */
    u[0x00 / 4] = (1u << 1) | (1u << 4);
    while (*s) {
        while (u[0x2C / 4] & 0x10u) { }          /* spin while TX FIFO full (SR bit4) */
        u[0x30 / 4] = (uint32_t)(unsigned char)*s++;
    }
}

/* Drive PS_USER_LED1 (MIO0, GPIO bank0 bit0) — a PS-software liveness signal
 * that, unlike the PL heartbeat (pure fabric), only changes if PS code is
 * actually executing.  ps7_init already muxes MIO0 to GPIO; we set it as an
 * enabled output.  GPIO @0xE000A000: DIRM_0=0x204, OEN_0=0x208, DATA_0=0x040. */
static void ps_led1_init(void)
{
    Xil_Out32(0xE000A000 + 0x204, Xil_In32(0xE000A000 + 0x204) | 0x1u); /* MIO0 -> output    */
    Xil_Out32(0xE000A000 + 0x208, Xil_In32(0xE000A000 + 0x208) | 0x1u); /* MIO0 -> out-enable */
}
static void ps_led1_set(int on)
{
    uint32_t d = Xil_In32(0xE000A000 + 0x040);
    Xil_Out32(0xE000A000 + 0x040, on ? (d | 0x1u) : (d & ~0x1u));
}

int main(void)
{
    /* PS-software liveness LED, FIRST thing — before anything that could hang
     * (UART, blitter, sleep).  If PS_USER_LED1 (MIO0) lights, the FSBL handed
     * off and the app reached main(); if it stays dark, PS code never ran.
     * This is independent of UART and of the PL heartbeat. */
    ps_led1_init();
    ps_led1_set(1);

    /* Raw UART1 probe FIRST — independent of the BSP STDOUT mapping. */
    uart1_raw_puts("\r\n[app] RAW UART1 alive\r\n");

    /* The standalone BSP's print() and xil_printf() route to whichever
     * UART the Vitis platform was generated against.  On Z-Turn that's
     * UART1 via the on-SOM FTDI bridge.
     */
    xil_printf("\r\n");
    xil_printf("fpga-xt boot OK\r\n");
    xil_printf("build: " __DATE__ " " __TIME__ "\r\n");

    /* Deassert the SiI9022A reset (PS-side, MIO[51]) so the PL hdmi_config
     * can program it over I2C.  See sii9022_reset_release() above. */
    sii9022_reset_release();
    xil_printf("sii9022: RESET# deasserted (MIO[51] high)\r\n");

    /* GP0 -> axi_blitter_bridge smoke-test is DISABLED for now.  A read of the
     * bridge @0x43C00000 hangs the CPU: the PL slave isn't responding (no AXI
     * RVALID), and PS GP0 reads have no timeout, so the app would never reach
     * the tick loop.  That GP0 hang is the current Phase-4 (PS<->PL AXI) bug
     * being debugged separately; skip it so we can prove the rest of the app
     * runs (tick loop + LED1 blink).  Re-enable once the GP0 path is fixed. */
    xil_printf("(blitter GP0 read deferred to tick 5 -- watch for a hang there)\r\n");

    uint32_t tick = 0;
    while (1) {
        ps_led1_set(tick & 1u);   /* blink PS_USER_LED1 each second — PS-alive proof */
        xil_printf("tick %u\r\n", tick++);

        /* GP0 probe: try the blitter STATUS read ONCE, after proving the loop
         * runs.  If GP0/clk_sys is alive we print STATUS and ticks continue;
         * if the GP0 read hangs (no AXI RVALID — clk_sys dead / rst_sys stuck)
         * the ticks stop right here, pinpointing GP0 as the culprit. */
        if (tick == 5) {
            xil_printf(">> GP0 probe: reading blitter STATUS @0x%08x ...\r\n",
                       (unsigned)XT_BLITTER_BASE);
            uint8_t st = xt_blitter_status();
            xil_printf(">> GP0 OK: blitter STATUS = 0x%02x\r\n", st);
        }
        sleep(1);   /* 1 second */
    }

    /* Unreachable, but make the compiler happy. */
    return 0;
}
