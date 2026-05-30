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
#include "xiicps.h"          /* PS I2C0 (EMIO) -> SiI9022A control bus */

#include "xt_blitter.h"

/* ---- SiI9022A HDMI transmitter over PS I2C0 (EMIO -> P15/P16) -------------
 * Replaces the old PL bit-bang.  7-bit address 0x3b (CI2CA strapped high).
 * Mirrors MyIR's proven init sequence (same registers the PL seq_rom used). */
#define SII_ADDR        0x3bu        /* 7-bit; CI2CA=1 */
#define SII_DEVID_REG   0x1Bu        /* TPI device ID — expect 0xB0 */

/* Vitis 2025.x (SDT flow) drops XPAR_*_DEVICE_ID; XIicPs_LookupConfig takes the
 * base address.  PS I2C0 on Zynq-7000 is at 0xE0004000. */
#ifndef XPAR_XIICPS_0_BASEADDR
#define XPAR_XIICPS_0_BASEADDR  0xE0004000u
#endif

static XIicPs Iic;

static int sii_init_i2c(void)
{
    XIicPs_Config *cfg = XIicPs_LookupConfig(XPAR_XIICPS_0_BASEADDR);
    if (!cfg) return XST_FAILURE;
    if (XIicPs_CfgInitialize(&Iic, cfg, cfg->BaseAddress) != XST_SUCCESS)
        return XST_FAILURE;
    XIicPs_SetSClk(&Iic, 100000);    /* 100 kHz */
    return XST_SUCCESS;
}

static int sii_write(uint8_t reg, uint8_t val)
{
    uint8_t b[2] = { reg, val };
    int s = XIicPs_MasterSendPolled(&Iic, b, 2, SII_ADDR);
    while (XIicPs_BusIsBusy(&Iic)) { }
    return s;                        /* XST_SUCCESS if the chip ACK'd */
}

/* Read one TPI register: write the offset, then read a byte. */
static int sii_read(uint8_t reg, uint8_t *val)
{
    int s = XIicPs_MasterSendPolled(&Iic, &reg, 1, SII_ADDR);
    while (XIicPs_BusIsBusy(&Iic)) { }
    if (s != XST_SUCCESS) return s;
    s = XIicPs_MasterRecvPolled(&Iic, val, 1, SII_ADDR);
    while (XIicPs_BusIsBusy(&Iic)) { }
    return s;
}

/* Internal (indexed) register access: page 0 via 0xBC, offset via 0xBD, data
 * at 0xBE.  Used for source termination (0x82) and the TCLK-stable status (0x72). */
static uint8_t sii_read_idx(uint8_t offset)
{
    sii_write(0xBC, 0x01); sii_write(0xBD, offset);
    uint8_t v = 0; sii_read(0xBE, &v);
    return v;
}
static void sii_write_idx(uint8_t offset, uint8_t val)
{
    sii_write(0xBC, 0x01); sii_write(0xBD, offset); sii_write(0xBE, val);
}

/* Hot-Plug Service: (re)establish the video output once a sink is attached
 * (HPD high).  The TPI doc puts power-up + video-mode + DVI/HDMI selection in
 * the hot-plug service, triggered by the HPD event — NOT statically at boot.
 * The DVI/HDMI mode + power state only latch on a 0x1E=0 write, so we set the
 * mode (0x1A) then write 0x1E=0 last.  Called on every HPD 0->1 transition. */
static void sii_enable_output(void)
{
    /* Whole config runs HERE, in D0, in the documented TPI order.  Doing it at
     * boot (in D2) silently dropped every write — video-mode + sync registers
     * only latch in D0.  Order per the SiI9022A TPI ref:
     *   power D0 -> video mode -> input/output format -> AVI commit (0x19)
     *   -> sync method (0x60, MUST be after the AVI InfoFrame) -> TMDS on last. */
    sii_write(0x1A, 0x11);                          /* HDMI mode, TMDS off (bit4)*/
    sii_write(0x1E, 0x00);                          /* power D0 (config latches) */
    sii_write(0x00, 0xFC); sii_write(0x01, 0x39);   /* pixel clock 148.4375 MHz  */
    sii_write(0x02, 0x70); sii_write(0x03, 0x17);   /* vfreq 60.00 Hz            */
    sii_write(0x04, 0x98); sii_write(0x05, 0x08);   /* H total 2200              */
    sii_write(0x06, 0x65); sii_write(0x07, 0x04);   /* V total 1125              */
    sii_write(0x08, 0x70);                          /* input bus: TClk x1, rising*/
    sii_write(0x09, 0x00); sii_write(0x0A, 0x00);   /* input/output format = RGB */
    /* AVI InfoFrame (TPI 0x0C-0x19) for 1080p60 RGB, VIC=16.  The TPI ref's
     * hot-plug step 4 says an HDMI sink REQUIRES the AVI InfoFrame — bare DVI
     * (which we sent before) is what a modern HDMI panel wakes to but won't
     * lock.  Writing 0x19 (the last byte) commits the InfoFrame AND latches
     * 0x09/0x0A.  Checksum per the HDMI spec: header(0x82 type + 0x02 version
     * + 0x0D length) + all 13 data bytes + checksum == 0 (mod 256). */
    {
        uint8_t avi[14];                 /* avi[i] -> TPI reg 0x0C + i          */
        unsigned i; uint8_t sum;
        avi[0]  = 0x00;                  /* 0x0C DByte0 = checksum (filled below)*/
        avi[1]  = 0x00;                  /* 0x0D DByte1: Y=RGB(00), no scan/bars */
        avi[2]  = 0x28;                  /* 0x0E DByte2: 16:9 (M=10), AFAR=same  */
        avi[3]  = 0x00;                  /* 0x0F DByte3: default RGB quant range  */
        avi[4]  = 16;                    /* 0x10 DByte4: VIC=16 (1080p60)        */
        avi[5]  = 0x00;                  /* 0x11 DByte5: no pixel repetition     */
        for (i = 6; i < 14; i++) avi[i] = 0x00;   /* 0x12-0x19 bar info = none  */
        sum = (uint8_t)(0x82 + 0x02 + 0x0D);      /* InfoFrame header bytes      */
        for (i = 1; i < 14; i++) sum = (uint8_t)(sum + avi[i]);
        avi[0] = (uint8_t)(0x100u - sum);         /* two's-complement checksum   */
        for (i = 0; i < 14; i++) sii_write((uint8_t)(0x0C + i), avi[i]);  /* 0x19 commits */
    }
    /* Sync method: 0x60[7]=0 = EXTERNAL sync, bit2 DE_ADJ#=0 (recommended), no
     * YC-mux.  TPI ref: 0x60 "must be written after the AVI InfoFrame is set"
     * (0x19) and in D0 — so it lives here, after 0x19. */
    sii_write(0x60, 0x00);
    /* DE: use our EXTERNAL DE pin (vbeam drives rgb_de = in_active, perfectly
     * aligned), NOT the internal DE generator.  Per the TPI ref (Fig 4 + "Sync
     * Generation Options"), the DE generator (0x62-0x6D, enabled by 0x63[6]) is
     * ONLY for sources that DON'T provide explicit DE — it synthesises DE from
     * HS/VS.  We provide HS/VS/DE all three, so the chip should consume DE_IN
     * directly; a *generated* DE can be a pixel/line off and corrupt the
     * blanking-period sync symbols -> monitor wakes but can't lock.  0x19 resets
     * 0x63 to its default (DE-gen disabled); write it explicitly to be sure. */
    sii_write(0x63, 0x00);                          /* DE generator OFF -> use DE_IN */
    /* source termination (recommended): internal page0/0x82 bit0 */
    sii_write(0xBC, 0x01); sii_write(0xBD, 0x82);
    { uint8_t t = 0; sii_read(0xBE, &t); sii_write(0xBE, (uint8_t)(t | 0x01)); }
    sii_write(0x1A, 0x01);                          /* HDMI, TMDS ON (last)      */

    /* Confirm the writes stuck now that we're in D0.  0x61 is READ-ONLY: it
     * reports the sync polarity the chip DETECTS on our input — if it shows
     * detected H/V sync, our sync is physically reaching the chip; if 0x61 is
     * dead while 0x60=0x00, sync isn't arriving (board/pin/level issue). */
    xil_printf("sii9022 post-cfg:");
    for (unsigned r = 0x00; r <= 0x0A; r++) {
        uint8_t v = 0; (void)sii_read((uint8_t)r, &v);
        xil_printf(" %02x=%02x", r, v);
    }
    { uint8_t a = 0, p = 0, s = 0, sp = 0;
      sii_read(0x1A, &a); sii_read(0x1E, &p); sii_read(0x60, &s); sii_read(0x61, &sp);
      xil_printf("  1A=%02x 1E=%02x 60=%02x 61=%02x\r\n", a, p, s, sp); }
    /* H_RES (0x6A/0x6B) and V_RES (0x6C/0x6D) are RO and measure the chip's view
     * of the INCOMING sync: H_RES = pixels between HSYNC edges (expect ~2200),
     * V_RES = lines between VSYNC edges (expect ~1125).  If these read the right
     * totals, our HS/VS physically reach the chip and the DE gen will lock. */
    usleep(50000);    /* let the V_RES measurement settle over ~3 full frames */
    { uint8_t hl = 0, hh = 0, vl = 0, vh = 0;
      sii_read(0x6A, &hl); sii_read(0x6B, &hh); sii_read(0x6C, &vl); sii_read(0x6D, &vh);
      unsigned hres = ((unsigned)(hh & 0x0F) << 8) | hl;
      unsigned vres = ((unsigned)(vh & 0x0F) << 8) | vl;
      xil_printf("sii9022 measured: H_RES=%u (exp 2200)  V_RES=%u (exp 1125)\r\n",
                 hres, vres); }
}

/* Release the SiI9022A HDMI transmitter from reset.
 *
 * On the Z-Turn V2 the SiI9022's RESET# (SIL9022_RESETn, schematic net
 * PS_501_RESET_OUTn) is driven from the PS, not the PL — so the PL
 * hdmi_config can only program the chip over I2C once the PS has
 * deasserted this reset.  MIO[51] (PS bank 501, pin B9) is the GPIO that
 * gates it; driving it high releases the chip.
 *
 * Proper hardware-reset PULSE per the SiI9022 datasheet: drive RESET# LOW for
 * >=10 ms, then HIGH, then wait >=15 ms for the bandgap references + internal
 * registers to stabilise before any I2C access.  (We previously only drove it
 * high with a 2.5 ms wait — no low pulse, and short of the 15 ms stabilisation,
 * so the analog/TMDS section may never have come up cleanly.)
 * MIO[51] = GPIO bank1 bit19 (MSW bit3); MASK_DATA_1_MSW @0x00C masks all but
 * bit3 (0xFFF7) and writes the data bit (0x0008=high, 0x0000=low).
 */
static void sii9022_reset(void)
{
    Xil_Out32(0xE000A000 + 0x244, 0x00080000); /* DIRM_1: MIO[51] = output        */
    Xil_Out32(0xE000A000 + 0x248, 0x00080000); /* OEN_1:  MIO[51] = output enable  */
    Xil_Out32(0xE000A000 + 0x00C, 0xFFF70000); /* RESET# LOW  (assert)             */
    usleep(10000);                              /* hold reset >= 10 ms              */
    Xil_Out32(0xE000A000 + 0x00C, 0xFFF70008); /* RESET# HIGH (release)            */
    usleep(15000);                              /* stabilise >= 15 ms (bandgap/regs)*/
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
     * can program it over I2C.  See sii9022_reset() above. */
    sii9022_reset();
    xil_printf("sii9022: hardware reset pulsed (10ms low, 15ms settle)\r\n");

    /* Configure the SiI9022A over PS I2C0 (EMIO -> P15/P16).  First read back
     * the TPI device ID (reg 0x1B) to PROVE the chip answers on I2C @0x3b —
     * the thing the old PL bit-bang never managed. */
    if (sii_init_i2c() != XST_SUCCESS) {
        xil_printf("sii9022: I2C0 init FAILED\r\n");
    } else {
        (void)sii_write(0xC7, 0x00);            /* step 1: reset / enter TPI  */

        /* Step 2: POLL device-ID reg 0x1B until it reads 0xB0 — the doc's
         * "TPI subsystem is ready when 0x1B reads correctly".  Don't assume the
         * chip resets instantly; loop (bounded) until ready before any config
         * write.  Each sii_read is a full I2C transaction (~0.3 ms @100 kHz),
         * so ~200 tries spans ~60 ms — ample for a soft reset. */
        uint8_t devid = 0x00;
        unsigned tries = 0;
        do {
            (void)sii_read(SII_DEVID_REG, &devid);
            tries++;
        } while (devid != 0xB0 && tries < 200);
        xil_printf("sii9022: device ID = 0x%02x after %u read%s (expect 0xB0)\r\n",
                   devid, tries, (tries == 1) ? "" : "s");

        /* Interrupt service config.  NOTE: the chip powers up in D2, where the
         * video-mode / input-bus / sync registers do NOT latch — so ALL of that
         * config now lives in sii_enable_output() (run on HPD, in D0, in the
         * documented order), NOT here.  Doing it here was a silent no-op. */
        sii_write(0x3C, 0x01);   /* interrupt service config                    */
        xil_printf("sii9022: input init done; output enabled on HPD\r\n");

        /* Read the chip's own status to see WHY there's no output.  The
         * SiI9022 won't drive TMDS unless it detects the sink:
         *   0x3D = TPI interrupt status: bit2 = HPD state (sink attached),
         *          bit3 = RxSense state (receiver powered).
         *   0x1A = system control readback (TMDS on/off, output mode).
         * Also read back the format regs to confirm the writes stuck. */
        uint8_t st = 0, sc = 0, pw = 0;
        (void)sii_read(0x3D, &st);
        (void)sii_read(0x1A, &sc);
        (void)sii_read(0x1E, &pw);
        xil_printf("sii9022: 0x3D=0x%02x (HPD=%u RxSense=%u)  0x1A=0x%02x  "
                   "0x1E=0x%02x\r\n",
                   st, (unsigned)((st>>2)&1u), (unsigned)((st>>3)&1u), sc, pw);

        /* Full register dump (you asked what state the chip is in): video mode
         * 0x00-0x07 (pixclk/vfreq/H/V totals), input/output fmt 0x08-0x0A,
         * device ID 0x1B-0x1D. */
        xil_printf("sii9022 dump:");
        for (unsigned r = 0x00; r <= 0x0A; r++) {
            uint8_t v = 0; (void)sii_read((uint8_t)r, &v);
            xil_printf(" %02x=%02x", r, v);
        }
        for (unsigned r = 0x1B; r <= 0x1D; r++) {
            uint8_t v = 0; (void)sii_read((uint8_t)r, &v);
            xil_printf(" %02x=%02x", r, v);
        }
        xil_printf("\r\n");
    }

    /* PL diagnostic word over GP0 @ XT_BLITTER_BASE + 0x1C (built in
     * fpga_xt_top).  Definitive clock-lock readout — no LED-colour guessing:
     *   [0]     mmcm1_locked  (clk_sally/clk_sys MMCM)
     *   [1]     mmcm2_locked  (clk_pix MMCM)
     *   [15:8]  clk_pix-alive count — climbs while clk_pix toggles; STUCK
     *           between ticks => clk_pix dead (e.g. mmcm2 not locked)
     *   [23:16] mmcm2 unlock-event count — 0 => it never dropped lock */
    xil_printf("PL diag @0x%08x (m1/m2 lock, clk_pix-alive, m2-unlocks)\r\n",
               (unsigned)(XT_BLITTER_BASE + 0x1Cu));

    uint32_t tick = 0, prev_pix = 0, prev_frm = 0;
    unsigned out_on = 0;          /* output enabled for the current plug? */
    while (1) {
        ps_led1_set(tick & 1u);   /* blink PS_USER_LED1 each second — PS-alive proof */

        uint32_t d        = Xil_In32(XT_BLITTER_BASE + 0x1Cu);
        unsigned m1       = (d >> 0) & 1u;
        unsigned m2       = (d >> 1) & 1u;
        unsigned pixalive = (d >> 8) & 0xFFu;
        unsigned m2unlk   = (d >> 16) & 0xFFu;
        unsigned frames   = (d >> 24) & 0xFFu;   /* vbeam frame count */
        unsigned pixmoving = (tick && pixalive != prev_pix);   /* changed since last tick */
        unsigned vbrun     = (tick && frames != prev_frm);     /* vbeam advancing? */
        prev_pix = pixalive;
        prev_frm = frames;

        /* Live SiI9022 hot-plug status (0x3D bit2=HPD, bit3=RxSense). */
        uint8_t st = 0;
        (void)sii_read(0x3D, &st);
        unsigned hpd = (st >> 2) & 1u;

        /* HOT-PLUG SERVICE (the doc's "must"): enable the video output when a
         * sink is present, re-running on each plug.  out_on starts 0 so the
         * output is (re)enabled on the FIRST HPD-high seen here — i.e. AFTER
         * HPD is confirmed, not statically at boot. */
        if (hpd && !out_on) {
            sii_enable_output();
            out_on = 1;
            xil_printf(">> HPD high: output enabled (hot-plug service)\r\n");
        } else if (!hpd) {
            out_on = 0;            /* unplug: re-enable on next plug */
        }

        /* TMDS clock stability: indexed page0/0x72 bit1 = TCLK_STABLE change
         * interrupt.  Read it, then clear (write 1).  If it stays clear after
         * clearing, the TMDS clock is stable (chip locked to our IDCK); if it
         * keeps re-asserting, the clock is flapping -> the pixel clock we feed
         * the chip isn't usable. */
        uint8_t tclk = sii_read_idx(0x72);
        if (tclk & 0x02) sii_write_idx(0x72, 0x02);   /* W1C the change flag */

        /* Live H_RES/V_RES — the chip's measured input sync.  Unlike the one-shot
         * post-cfg read (taken mid-frame, so V_RES was a partial count), this
         * samples once/sec after the measurement has settled: H_RES~2200,
         * V_RES~1125 means the chip sees a clean 1080p60 raster on our HS/VS. */
        uint8_t hl = 0, hh = 0, vl = 0, vh = 0;
        sii_read(0x6A, &hl); sii_read(0x6B, &hh);
        sii_read(0x6C, &vl); sii_read(0x6D, &vh);
        unsigned hres = ((unsigned)(hh & 0x0F) << 8) | hl;
        unsigned vres = ((unsigned)(vh & 0x0F) << 8) | vl;

        xil_printf("tick %2u  clk_pix=%s  vbeam=%s (frm=%u)  "
                   "HPD=%u RxSense=%u  tclk=0x%02x  H_RES=%u V_RES=%u\r\n",
                   tick,
                   pixmoving ? "RUNNING" : (tick ? "STUCK" : "?"),
                   vbrun ? "FRAMING" : (tick ? "STUCK" : "?"), frames,
                   hpd, (unsigned)((st>>3)&1u),
                   tclk, hres, vres);
        (void)m1; (void)m2; (void)m2unlk; (void)pixalive;
        (void)m1; (void)m2;
        tick++;
        sleep(1);   /* 1 second */
    }

    /* Unreachable, but make the compiler happy. */
    return 0;
}
