/*
 * xtos/main.c — fpga-xt bring-up Phase 3 hello world.
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
 * the IDE).  Result: workspace/xtos/build/xtos.elf.
 */

#include <stdint.h>
#include <stdlib.h>          /* strtoul (REPL hex parsing) */
#include <string.h>          /* strcmp  (REPL dispatch)    */
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"       /* Xil_DCacheInvalidateRange — coherent DDR peeks */
#include "usb_hid.h"          /* TinyUSB host (USB0) bring-up */
#include "sleep.h"           /* usleep — paces the REPL loop (1 ms/iter) */
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

/* Internal (indexed) register read: select page 0 via 0xBC, offset via 0xBD,
 * data at 0xBE.  Used for the TCLK-stable status (0x72).  (Indexed *writes* —
 * e.g. source termination 0x82 — are done inline / via the REPL's `iw`.) */
static uint8_t sii_read_idx(uint8_t offset)
{
    sii_write(0xBC, 0x01); sii_write(0xBD, offset);
    uint8_t v = 0; sii_read(0xBE, &v);
    return v;
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

/* ====================================================================
 * Serial REPL — interactive debug console on UART1.
 *
 * The bring-up tax this pays off: instead of editing C, rebuilding, and
 * re-flashing to poke one register, you poke it live and watch the result.
 *   mr/mw  = peek/poke ANY 32-bit address (Xil_In32/Out32): PL GP0 regs
 *            (blitter 0x43C0xxxx, diag, test-pattern ctrl), MIO GPIO, PS regs.
 *   ir/iw/id = SiI9022 I2C read / write / dump (over PS I2C0).
 * plus convenience wrappers (bars, hdmi, diag, mon) and 'help'.
 * ==================================================================== */
static int g_mon = 0;        /* periodic status tick on/off */
/* Shadow of gp0_ctrl (43C0001C is write-only as a control reg — the read at
 * that offset returns the diag word, not the ctrl bits — so the PS must track
 * the byte it last wrote).  Resets to match the bitstream default (0x00 =
 * compositor/desktop, scale field 0 => XL_SCALE default).  bit0 = HDMI bars
 * (debug only now); bits[3:1] = XL plane scale (0 => default 3). */
static u8 g_gp0 = 0x00;

/* Serial-console -> Atari keyboard bridge (while the USB host is out of service):
 * each typed char is translated to an Atari KBCODE and poked to POKEY via the GP0
 * keyboard-inject ($D4CF) + release ($D4CD), so typing in the terminal lands in
 * BASIC.  A literal '{' enters passthrough, '}' ends it — braces aren't on the
 * Atari keyboard, so they never collide with a pasted listing (even mid-line). */
#define XT_KBD_INJECT   (XT_BLITTER_BASE + 0x1Fu)   /* $D4CF: KBCODE + keyboard IRQ */
#define XT_KBD_RELEASE  (XT_BLITTER_BASE + 0x1Du)   /* $D4CD: all-keys-up (no auto-repeat) */
#define XT_KBD_BREAK    (XT_BLITTER_BASE + 0x1Bu)   /* $D4CB: Atari BREAK (POKEY IRQST b7) */
static int      g_key_passthru = 0;

/* Lightweight UART1 char I/O (no FIFO reset, unlike uart1_raw_puts) so it
 * interleaves cleanly with xil_printf.  UART1 @0xE0001000: SR @0x2C
 * (bit1=RXEMPTY, bit4=TXFULL), data FIFO @0x30, CR @0x00. */
static void uart1_putc(char ch)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    while (u[0x2C / 4] & 0x10u) { }          /* spin while TX FIFO full */
    u[0x30 / 4] = (uint32_t)(unsigned char)ch;
}
static void uart1_puts(const char *s) { while (*s) uart1_putc(*s++); }

/* Enable the UART1 receiver — ps7_init sets baud/mode, but the early TX-only
 * CR write in uart1_raw_puts cleared RX_EN, so turn it back on for the REPL. */
static void uart1_rx_enable(void)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    u[0x00 / 4] = 0x03;                      /* RXRST|TXRST (self-clearing) */
    u[0x00 / 4] = 0x14;                      /* RX_EN|TX_EN                 */
}
/* Non-blocking: returns the next RX byte, or -1 if the FIFO is empty. */
static int uart1_getc(void)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    if (u[0x2C / 4] & 0x02u) return -1;      /* SR bit1 = RXEMPTY */
    return (int)(u[0x30 / 4] & 0xFFu);
}

static void repl_help(void)
{
    uart1_puts(
      "\r\ncommands (all values are HEX):\r\n"
      "  mr <addr> [n]    memory read n words (Xil_In32), default n=1\r\n"
      "  mw <addr> <val>  memory write, 32-bit (Xil_Out32)\r\n"
      "  ir <reg>         SiI9022 I2C register read\r\n"
      "  iw <reg> <val>   SiI9022 I2C register write\r\n"
      "  id [start] [n]   SiI9022 I2C dump (default start=00, n=20)\r\n"
      "  fill             blitter solid-rect to DDR 0x30000000 (PL->DDR test)\r\n"
      "  sync             fire blitter SYNC; SEQ counter moves if FSM alive\r\n"
      "  prod             ANTIC-frame + HP3-writeback counters (emulator alive?)\r\n"
      "  rdp              plane_fetch read-path counters (HP0/HP3 AR + R-beats)\r\n"
      "  rda              plane_fetch first-AR addresses (HP3/XL, HP0/desktop)\r\n"
      "  hpread           HP2 isolated PL->DDR read-test (success/timeout/rdata)\r\n"
      "  deskfill [rgba]  fill desktop plane-0 surface (0x30000000); default black\r\n"
      "  bars <0|1>       HDMI test pattern off/on (writes 43C0001C)\r\n"
      "  scale <1..5>     XL plane scale (gp0_ctrl[3:1]); sweep for blend correlation\r\n"
      "  dmactl <0|1>     honour DMACTL screen-blank (gp0_ctrl[4]); 1=real Atari, 0=legacy\r\n"
      "  hdmi             re-run SiI9022 output init (sii_enable_output)\r\n"
      "  diag             decode GP0 diag word + measured H_RES/V_RES\r\n"
      "  { ... }          serial->Atari keyboard passthrough ('key' or '{' in, '}' out)\r\n"
      "  speed <n>        CPU speed = n x real Atari (DECIMAL); 1=real/boot-safe, 56=max turbo\r\n"
      "  mon <0|1>        periodic 1s status tick off/on\r\n"
      "  reset            soft-reset the PS (SLCR) -> full reboot (FSBL/DDR/PL)\r\n"
      "  help             this list\r\n"
      "e.g.  mr 43c0001c  |  iw 1a 01  |  id 00 20  |  bars 0\r\n");
}

/* One decoded status line: GP0 diag word (clock-lock / clk_pix-alive / vbeam
 * frames) + the SiI9022's live HPD/RxSense/TCLK and measured input sync. */
static void repl_status(void)
{
    uint32_t d = Xil_In32(XT_BLITTER_BASE + 0x1Cu);
    uint8_t  st = 0, tclk, hl = 0, hh = 0, vl = 0, vh = 0;
    (void)sii_read(0x3D, &st);
    tclk = sii_read_idx(0x72);
    sii_read(0x6A, &hl); sii_read(0x6B, &hh);
    sii_read(0x6C, &vl); sii_read(0x6D, &vh);
    xil_printf("diag=%08x m1=%u m2=%u pixalive=%u frames=%u | "
               "HPD=%u RxSense=%u tclk=%02x H_RES=%u V_RES=%u\r\n",
               (unsigned)d, (unsigned)(d & 1u), (unsigned)((d >> 1) & 1u),
               (unsigned)((d >> 8) & 0xFFu), (unsigned)((d >> 24) & 0xFFu),
               (unsigned)((st >> 2) & 1u), (unsigned)((st >> 3) & 1u), tclk,
               ((unsigned)(hh & 0x0F) << 8) | hl,
               ((unsigned)(vh & 0x0F) << 8) | vl);
}

/* ASCII -> Atari KBCODE (bit6 = Shift, bit7 = Ctrl); 0xFF = no Atari key.
 * Letters map to the unshifted key so the Atari's power-on caps gives uppercase
 * (BASIC-friendly); shifted symbols carry bit6.  Rare graphics symbols may need
 * tweaking vs the exact XL layout, but all of BASIC's character set is here. */
static u8 ascii_to_kbcode(int c)
{
    static const u8 LET[26] = {  /* A..Z key codes */
      0x3F,0x15,0x12,0x3A,0x2A,0x38,0x3D,0x39,0x0D,0x01,0x05,0x00,0x25,
      0x23,0x08,0x0A,0x2F,0x28,0x3E,0x2D,0x0B,0x10,0x2E,0x16,0x2B,0x17 };
    static const u8 DIG[10] = {  /* 0..9 unshifted */
      0x32,0x1F,0x1E,0x1A,0x18,0x1D,0x1B,0x33,0x35,0x30 };
    if (c >= 'a' && c <= 'z') return LET[c - 'a'];
    if (c >= 'A' && c <= 'Z') return LET[c - 'A'];   /* both -> uppercase */
    if (c >= '0' && c <= '9') return DIG[c - '0'];
    switch (c) {
      case ' ':  return 0x21;
      case '\r': case '\n': return 0x0C;             /* Return */
      case 0x08: case 0x7F: return 0x34;             /* Backspace/Delete */
      case '\t': return 0x2C;                        /* Tab */
      case 0x1B: return 0x1C;                        /* Esc */
      case '-': return 0x0E;  case '=': return 0x0F;  case ';': return 0x02;
      case ',': return 0x20;  case '.': return 0x22;  case '/': return 0x26;
      case '+': return 0x06;  case '*': return 0x07;  case '<': return 0x36;
      case '>': return 0x37;
      case '!': return 0x1F|0x40;  case '"': return 0x1E|0x40;
      case '#': return 0x1A|0x40;  case '$': return 0x18|0x40;
      case '%': return 0x1D|0x40;  case '&': return 0x1B|0x40;
      case '\'':return 0x33|0x40;  case '@': return 0x35|0x40;
      case '(': return 0x30|0x40;  case ')': return 0x32|0x40;
      case ':': return 0x02|0x40;  case '?': return 0x26|0x40;
      case '[': return 0x20|0x40;  case ']': return 0x22|0x40;
      case '_': return 0x0E|0x40;  case '|': return 0x0F|0x40;
      case '\\':return 0x06|0x40;  case '^': return 0x07|0x40;
      default:  return 0xFF;
    }
}

/* Inject one serial char as a keystroke: KBCODE down then up (release stops the
 * OS auto-repeat).  No pacing here — the loop meters chars out of the ring (see
 * key_paste_tick), so the UART RX FIFO is drained every pass and never overflows. */
static void key_inject_ascii(int c)
{
    if (c == 0x03) { Xil_Out8(XT_KBD_BREAK, 0); return; }   /* Ctrl-C -> Atari BREAK */
    u8 kb = ascii_to_kbcode(c);
    if (kb == 0xFFu) return;
    Xil_Out8(XT_KBD_INJECT,  kb);
    Xil_Out8(XT_KBD_RELEASE, 0);
}


/* Paste ring buffer.  The REPL loop drains the UART into here every pass (fast,
 * non-blocking) so a fast paste can't overflow the 64-byte UART RX FIFO; chars
 * are then metered OUT at keyboard pace below.  8 KB holds a big listing. */
static char     s_kr[8192];
static unsigned s_kr_head, s_kr_tail, s_kr_pace;
static void kr_push(char c) { unsigned n = (s_kr_head + 1u) & (sizeof(s_kr)-1u);
                              if (n != s_kr_tail) { s_kr[s_kr_head] = c; s_kr_head = n; } }
static int  kr_pop(void)    { if (s_kr_tail == s_kr_head) return -1;
                              int c = (unsigned char)s_kr[s_kr_tail];
                              s_kr_tail = (s_kr_tail + 1u) & (sizeof(s_kr)-1u); return c; }
static int  kr_peek(void)   { return (s_kr_tail == s_kr_head) ? -1 : (unsigned char)s_kr[s_kr_tail]; }

/* One loop pass of metered paste injection (loop runs ~1 ms/pass, so the pace
 * counts are ~milliseconds): ~20 ms between chars (~50 cps), 60 ms before a
 * repeated key (beat the OS KEYDEL debounce), 100 ms after Return (let BASIC
 * tokenize the line before the next one arrives). */
static void key_paste_tick(void)
{
    if (s_kr_pace) { s_kr_pace--; return; }
    int c = kr_pop();
    if (c < 0) return;
    if (c == '}') {                       /* '}' ends passthrough (not an Atari key) */
        g_key_passthru = 0; s_kr_head = s_kr_tail = 0;
        uart1_puts("\r\n>> key passthrough OFF\r\n> ");
        return;
    }
    key_inject_ascii(c);
    int nx = kr_peek();
    u8  kbc = ascii_to_kbcode(c);
    u8  kbn = (nx >= 0) ? ascii_to_kbcode(nx) : 0xFFu;
    if      (c == '\r' || c == '\n')          s_kr_pace = 100u;  /* tokenize gap   */
    else if (kbn != 0xFFu && kbn == kbc)      s_kr_pace = 60u;   /* repeated key   */
    else                                      s_kr_pace = 20u;   /* ~50 cps        */
}

/* Parse + run one command line (modified in place by the tokenizer). */
static void repl_exec(char *cmd)
{
    char *argv[5]; int argc = 0;
    char *p = cmd;
    while (*p && argc < 5) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        if (*p) *p++ = '\0';
    }
    if (argc == 0) return;

    if (!strcmp(argv[0], "help")) { repl_help(); return; }

    if (!strcmp(argv[0], "key")) {       /* "key" = enter passthrough (same as '{') */
        g_key_passthru = 1;
        uart1_puts(">> key passthrough ON — '}' ends it; Ctrl-C = BREAK\r\n");
        return;
    }

    if (!strcmp(argv[0], "speed")) {     /* SALLY clock_mult (DECIMAL) -> $D4CA */
        if (argc < 2) {
            uart1_puts("  usage: speed <n>  (decimal; n = x real Atari; 1 = real/boot-safe)\r\n"
                       "  clean grades: 1 2 4 7 8 14 28 56 (56 = full turbo 100MHz; others fall back to 1x)\r\n");
            return;
        }
        unsigned n = strtoul(argv[1], NULL, 10);
        Xil_Out8(XT_BLITTER_BASE + 0x1Au, (u8)n);
        xil_printf("  SALLY clock_mult = %u (boot at 1, raise after READY)\r\n", n);
        return;
    }

    if (!strcmp(argv[0], "mr")) {
        if (argc < 2) { uart1_puts("usage: mr <addr> [n]\r\n"); return; }
        uint32_t a = (uint32_t)strtoul(argv[1], NULL, 16);
        unsigned n = (argc >= 3) ? (unsigned)strtoul(argv[2], NULL, 16) : 1u;
        /* Invalidate the A9 cache for this range first: the PL writes DDR over
         * HP-AXI (not snooped by the A9 cache), so without this a cached read
         * returns stale data and never sees what the PL put there.  No-op for
         * the device-mapped GP0 region (uncached). */
        Xil_DCacheInvalidateRange((INTPTR)a, (unsigned)(n * 4u));
        for (unsigned i = 0; i < n; i++)
            xil_printf("  [%08x] = %08x\r\n", (unsigned)(a + 4u * i),
                       (unsigned)Xil_In32(a + 4u * i));
        return;
    }
    if (!strcmp(argv[0], "mw")) {
        if (argc < 3) { uart1_puts("usage: mw <addr> <val>\r\n"); return; }
        uint32_t a = (uint32_t)strtoul(argv[1], NULL, 16);
        uint32_t v = (uint32_t)strtoul(argv[2], NULL, 16);
        xil_printf("  writing [%08x] <= %08x ...\r\n", (unsigned)a, (unsigned)v);
        Xil_Out32(a, v);                 /* if no "ok" prints, this write HUNG */
        uart1_puts("  ok\r\n");
        return;
    }
    if (!strcmp(argv[0], "ir")) {
        if (argc < 2) { uart1_puts("usage: ir <reg>\r\n"); return; }
        uint8_t r = (uint8_t)strtoul(argv[1], NULL, 16), v = 0;
        sii_read(r, &v);
        xil_printf("  i2c[%02x] = %02x\r\n", r, v);
        return;
    }
    if (!strcmp(argv[0], "iw")) {
        if (argc < 3) { uart1_puts("usage: iw <reg> <val>\r\n"); return; }
        uint8_t r = (uint8_t)strtoul(argv[1], NULL, 16);
        uint8_t v = (uint8_t)strtoul(argv[2], NULL, 16);
        sii_write(r, v);
        xil_printf("  i2c[%02x] <= %02x\r\n", r, v);
        return;
    }
    if (!strcmp(argv[0], "id")) {
        unsigned s = (argc >= 2) ? (unsigned)strtoul(argv[1], NULL, 16) : 0x00u;
        unsigned n = (argc >= 3) ? (unsigned)strtoul(argv[2], NULL, 16) : 0x20u;
        for (unsigned i = 0; i < n; i++) {
            uint8_t v = 0; sii_read((uint8_t)(s + i), &v);
            if ((i & 7u) == 0) xil_printf("\r\n  %02x:", s + i);
            xil_printf(" %02x", v);
        }
        uart1_puts("\r\n");
        return;
    }
    if (!strcmp(argv[0], "fill")) {
        /* Blitter solid-rect fill to FB_BASE (0x3000_0000) — tests the PL->DDR
         * HP-AXI write path with no 6502/ANTIC involved.  64x16 px of
         * 0xFFE04010 (R=10,G=40,B=E0,A=FF) at (0,0).  Then `mr 30000000 10`:
         * repeating FFE04010 => HP->DDR write works; still FF/00 => it doesn't. */
        unsigned g = 0;
        while (xt_blitter_busy() && g++ < 1000000u) { }     /* wait idle */
        xt_blitter_set_dst(0, 0, 64, 16);
        xt_blitter_set_pat_log(0, 0);                       /* 1x1 = solid colour */
        { uint8_t px[4] = { 0x10, 0x40, 0xE0, 0xFF };       /* R,G,B,A */
          xt_blitter_write_pat(px, 4); }
        xt_blitter_set_raster_op(0x0F);                     /* copy */
        xt_blitter_fire(0x01);                              /* rect fill */
        g = 0; while (xt_blitter_busy() && g++ < 1000000u) { }   /* wait done */
        uart1_puts("  blitter fill fired: 64x16 @ 0x30000000, px=0xFFE04010\r\n"
                   "  check: mr 30000000 10  (repeating FFE04010 = PL->DDR works)\r\n");
        return;
    }
    if (!strcmp(argv[0], "sync")) {
        /* Fire a blitter SYNC barrier (CMD=0x07) — bumps the SEQ counter if the
         * blitter FSM is alive, with NO DDR access.  Bisects "blitter didn't
         * run" from "PL->DDR write broken": SEQ changes => FSM alive (so a fill
         * that didn't land means HP1->DDR is the problem); SEQ static => the
         * blitter isn't processing commands at all. */
        uint8_t lo0 = xt_blitter_read8(XT_BL_SEQ_LO);
        uint8_t hi0 = xt_blitter_read8(XT_BL_SEQ_HI);
        uint8_t st  = xt_blitter_read8(XT_BL_STATUS);
        xt_blitter_fire(0x07);
        usleep(2000);
        uint8_t lo1 = xt_blitter_read8(XT_BL_SEQ_LO);
        uint8_t hi1 = xt_blitter_read8(XT_BL_SEQ_HI);
        xil_printf("  STATUS=%02x  SEQ %02x%02x -> %02x%02x  (%s)\r\n",
                   st, hi0, lo0, hi1, lo1,
                   (lo0 != lo1 || hi0 != hi1) ? "FSM ALIVE" : "FSM NOT RESPONDING");
        return;
    }
    if (!strcmp(argv[0], "prod")) {
        /* Production-chain counters (diag2 @ GP0 0x18): [7:0] ANTIC frame_done
         * count, [15:8] HP3 writeback write-beat count.  Run a few times — if
         * ANTIC frames climb, the 6502+ANTIC are alive on silicon; if HP3 beats
         * climb, the writeback is DMA-ing pixels to DDR. */
        uint32_t d2 = Xil_In32(XT_BLITTER_BASE + 0x18u);
        xil_printf("  ANTIC frames=%u  HP3 write-beats=%u  (run again; climbing = alive)\r\n",
                   (unsigned)(d2 & 0xFFu), (unsigned)((d2 >> 8) & 0xFFu));
        return;
    }
    if (!strcmp(argv[0], "rdp")) {
        /* Read-path counters (diag3 @ GP0 0x14): {hp0_ar, hp0_rbeat, hp3_ar,
         * hp3_rbeat}.  plane_fetch DDR reads -> compositor; the half we've never
         * validated on silicon (both planes scan out black).  Run twice:
         *   AR climbs, R-beats DON'T => PS not returning read data (HP read ch);
         *   both climb but screen black => line-buf->pixel CDC drops it;
         *   AR static => plane_fetch never issues reads (line_start CDC / FSM). */
        uint32_t d3 = Xil_In32(XT_BLITTER_BASE + 0x14u);
        xil_printf("  HP0(desk) AR=%u R-beats=%u   HP3(XL) AR=%u R-beats=%u  (run again)\r\n",
                   (unsigned)((d3 >> 24) & 0xFFu), (unsigned)((d3 >> 16) & 0xFFu),
                   (unsigned)((d3 >> 8) & 0xFFu),  (unsigned)(d3 & 0xFFu));
        return;
    }
    if (!strcmp(argv[0], "rda")) {
        /* First-AR address latches (diag4 @ 0x10 = HP3/XL, diag5 @ 0x0C =
         * HP0/desktop).  Confirms plane_fetch drives a sane read address on
         * silicon: HP3 ~3100xxxx/3110xxxx, HP0 ~3000xxxx.  Garbage/0 => an
         * addressing/startup bug; sane => the AR is well-formed and the hang
         * is in the PS read-data path. */
        uint32_t xl   = Xil_In32(XT_BLITTER_BASE + 0x10u);
        uint32_t desk = Xil_In32(XT_BLITTER_BASE + 0x0Cu);
        xil_printf("  first AR addr: HP3(XL)=%08x  HP0(desk)=%08x  (sane ~3100xxxx / ~3000xxxx)\r\n",
                   (unsigned)xl, (unsigned)desk);
        return;
    }
    if (!strcmp(argv[0], "hpread")) {
        /* HP2 read-test probe (auto-running, isolated single-beat reads of
         * 0x31000000).  diag6 @0x04 = {success[15:0], timeout[12:0], to_in_r,
         * rresp[1:0]}; diag7 @0x08 = last rdata.  Run twice:
         *   success climbing      => isolated PL->DDR reads WORK (the bug is
         *                            in plane_fetch / bursting / CDC)
         *   timeout climbing, succ=0, to_in_r=1
         *                         => AR accepted but PS returns no data: the
         *                            read-data path is fundamentally dead. */
        /* diag6 @0x04 = {succ1[31:24], to1[23:16], succ8[15:8], to8[7:0]}.
         * succ1 climbs + succ8 frozen/to8 climbs => MULTI-BEAT reads are the
         * plane_fetch bug (single-beat works); both succ climbing => burst
         * length is not the cause (look at CDC/ping-pong). */
        uint32_t s = Xil_In32(XT_BLITTER_BASE + 0x04u);
        uint32_t d = Xil_In32(XT_BLITTER_BASE + 0x08u);
        xil_printf("  HP2 probe: 1-beat succ=%u to=%u   8-beat succ=%u to=%u   rdata=%08x  (run again)\r\n",
                   (unsigned)((s >> 24) & 0xFFu), (unsigned)((s >> 16) & 0xFFu),
                   (unsigned)((s >> 8) & 0xFFu),  (unsigned)(s & 0xFFu), (unsigned)d);
        return;
    }
    if (!strcmp(argv[0], "deskfill")) {
        /* Fill the desktop plane-0 surface (0x30000000; plane_fetch0 reads it
         * via HP0, stride 8192 = 2048 words/row, 1080 rows) with a solid RGBA
         * word, then flush the A9 cache so the non-coherent PL read sees it.
         * Replaces the uninitialized-DDR garbage around the Atari window with a
         * clean field, and tests whether the surround flicker is just garbage
         * (-> goes static) or a plane-0 read issue (-> still flickers).
         * Word = 0xRRGGBBaa (compositor takes [31:8] as RGB, ignores alpha);
         * default 0x00000000 = black. */
        uint32_t c = (argc >= 2) ? (uint32_t)strtoul(argv[1], NULL, 16) : 0x00000000u;
        volatile uint32_t *p = (volatile uint32_t *)0x30000000u;
        uint32_t words = 1080u * 2048u;          /* 1080 rows x 8192-byte stride */
        for (uint32_t i = 0; i < words; i++) p[i] = c;
        Xil_DCacheFlushRange((INTPTR)0x30000000u, (INTPTR)(words * 4u));
        xil_printf("  desktop @0x30000000 filled = %08x (%u words) + cache flushed\r\n",
                   (unsigned)c, (unsigned)words);
        return;
    }
    if (!strcmp(argv[0], "bars")) {
        unsigned on = (argc >= 2) ? (unsigned)strtoul(argv[1], NULL, 16) : 1u;
        g_gp0 = (u8)((g_gp0 & ~0x01u) | (on ? 0x01u : 0x00u));  /* preserve scale bits */
        xil_printf("  writing gp0_ctrl=%02x (bars=%u) ...\r\n", g_gp0, on ? 1u : 0u);
        Xil_Out32(XT_BLITTER_BASE + 0x1Cu, (u32)g_gp0);
        uart1_puts("  ok\r\n");
        return;
    }
    if (!strcmp(argv[0], "scale")) {
        /* XL plane vertical/horizontal scale (gp0_ctrl[3:1]).  n in 1..5
         * (PL clamps to 5; 0 => default 3).  An intermittent wrong-row
         * scan-out fetch offsets the picture by exactly `scale` output
         * lines, so sweep this and watch whether the READY blend tracks. */
        if (argc < 2) { xil_printf("usage: scale <1..5>   (cur=%u)\r\n",
                                   (g_gp0 >> 1) & 0x7u); return; }
        unsigned n = (unsigned)strtoul(argv[1], NULL, 10) & 0x7u;
        g_gp0 = (u8)((g_gp0 & ~0x0Eu) | ((n & 0x7u) << 1));    /* preserve bar bit */
        xil_printf("  writing gp0_ctrl=%02x (scale=%u, bars=%u) ...\r\n",
                   g_gp0, n, g_gp0 & 1u);
        Xil_Out32(XT_BLITTER_BASE + 0x1Cu, (u32)g_gp0);
        uart1_puts("  ok\r\n");
        return;
    }
    if (!strcmp(argv[0], "dmactl")) {
        /* gp0_ctrl[4] = honour DMACTL screen-blanking (playfield/DL DMA off ->
         * COLBK), like real ANTIC.  0 = legacy (always render).  The desktop
         * sets this per-app; games that blank-while-drawing need it on. */
        unsigned on = (argc >= 2) ? (unsigned)strtoul(argv[1], NULL, 10) : 1u;
        g_gp0 = (u8)((g_gp0 & ~0x10u) | (on ? 0x10u : 0x00u));  /* preserve bars+scale */
        xil_printf("  writing gp0_ctrl=%02x (dmactl-honor=%u) ...\r\n", g_gp0, on ? 1u : 0u);
        Xil_Out32(XT_BLITTER_BASE + 0x1Cu, (u32)g_gp0);
        uart1_puts("  ok\r\n");
        return;
    }
    if (!strcmp(argv[0], "hdmi")) {
        sii_enable_output();
        uart1_puts("  sii_enable_output() done\r\n");
        return;
    }
    if (!strcmp(argv[0], "diag")) { repl_status(); return; }
    if (!strcmp(argv[0], "mon")) {
        if (argc < 2) { uart1_puts("usage: mon <0|1>\r\n"); return; }
        g_mon = (strtoul(argv[1], NULL, 16) != 0);
        xil_printf("  mon %s\r\n", g_mon ? "ON" : "OFF");
        return;
    }
    if (!strcmp(argv[0], "reset")) {
        /* SLCR software reset of the whole PS -> BootROM -> FSBL (ps7_init/DDR
         * re-init) -> bitstream reload -> app.  A convenient cold-boot-like
         * reboot for repeat testing without a physical power-cycle.  Unlock the
         * SLCR (key 0xDF0D @ 0xF8000008), then set PSS_RST_CTRL.SOFT_RST
         * (0xF8000200 bit0).  Does not return. */
        uart1_puts("  PS soft reset (SLCR) — rebooting...\r\n");
        Xil_Out32(0xF8000008u, 0x0000DF0Du);   /* SLCR_UNLOCK */
        Xil_Out32(0xF8000200u, 0x00000001u);   /* PSS_RST_CTRL.SOFT_RST */
        for (;;) { }                            /* wait for the reset to land */
    }
    uart1_puts("? unknown — type 'help'\r\n");
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

    /* gp0_ctrl now resets to 0x00 in the bitstream = COMPOSITOR (desktop) — bars
     * are a debug option only (`bars 1`), never the default, even after a PS
     * `reset` / cold boot.  Still DON'T write gp0_ctrl here in early boot (a GP0
     * write before the REPL is up historically hung the CPU); the deferred
     * desktop-clear block below pokes it at ~0.5 s where writes are proven safe. */
    xil_printf("display: COMPOSITOR/desktop (bitstream default; 'bars 1' for test pattern)\r\n");

    /* NOTE: a desktop-surface memset (0x30000000, 8 MB) to clear the plane-0
     * power-on garbage is NOT done here — doing it in early boot reset-looped
     * (large DDR write before the system settled, while PL->DDR was ungated and
     * flaky after reset).  It is now done DEFERRED in the REPL loop at ~2 s
     * uptime (search "desktop @0x30000000 auto-cleared"), safely past the
     * ~224 ms ddr_warm PL->DDR gate + HDMI bring-up.  `deskfill` still does it
     * on demand (any colour). */

    /* ---- Serial REPL ----------------------------------------------------
     * Interactive debug console.  The loop is non-blocking: it polls UART for
     * a command line and dispatches on Enter, paced by a 1 ms usleep so a ~1s
     * counter still services hot-plug (auto-enable output on HDMI plug),
     * toggles the liveness LED, and prints a status line when `mon` is on. */
    uart1_rx_enable();
    /* The USB0 host (TinyUSB) is not started here.  Keyboard input comes via the
     * serial '{ }' passthrough, and USB HID will live on an external companion;
     * leaving the ChipIdea host's ISR armed serves no purpose and draws bus power. */
    /* usb_hid_init(); */
    repl_help();
    uart1_puts("> ");

    char     line[80];
    unsigned ll = 0;
    unsigned out_on = 0, tick = 0, ms = 0;
    unsigned desk_cleared = 0;          /* one-shot deferred desktop clear */

    while (1) {
        /* usb_hid_task(); */           /* USB host not started (see above) */
        /* Interactive: drain RX, echo, dispatch on CR/LF. */
        int c;
        while ((c = uart1_getc()) >= 0) {
            if (g_key_passthru) { kr_push((char)c); continue; }   /* drain fast -> ring */
            if (c == '{') {                                       /* enter passthrough */
                g_key_passthru = 1;
                uart1_puts("\r\n>> key passthrough ON — '}' ends it; Ctrl-C = BREAK\r\n");
                continue;
            }
            if (c == '\r' || c == '\n') {
                uart1_puts("\r\n");
                line[ll] = '\0';
                if (ll > 0) repl_exec(line);
                ll = 0;
                uart1_puts("> ");
            } else if (c == 0x08 || c == 0x7F) {        /* backspace / DEL */
                if (ll > 0) { ll--; uart1_puts("\b \b"); }
            } else if (c >= 0x20 && c < 0x7F && ll < sizeof(line) - 1) {
                line[ll++] = (char)c;
                uart1_putc((char)c);
            }
        }

        if (g_key_passthru) key_paste_tick();   /* meter one queued paste char out */

        usleep(1000);                       /* 1 ms — pace the loop (echo ≤1ms) */

        /* Periodic (~1s): hot-plug service + LED + optional mon status feed. */
        if (++ms >= 1000) {
            ms = 0;
            ps_led1_set(tick & 1u);

            uint8_t st = 0; (void)sii_read(0x3D, &st);
            unsigned hpd = (st >> 2) & 1u;
            if (hpd && !out_on) {                       /* plug: enable output */
                sii_enable_output();
                out_on = 1;
                uart1_puts("\r\n>> HPD high: output enabled\r\n> ");
                for (unsigned k = 0; k < ll; k++) uart1_putc(line[k]);
            } else if (!hpd) {
                out_on = 0;                             /* unplug: re-arm */
            }

            if (g_mon) {                                /* live status feed */
                uart1_puts("\r\n");
                repl_status();
                uart1_puts("> ");
                for (unsigned k = 0; k < ll; k++) uart1_putc(line[k]);
            }
            tick++;
        }

        /* One-shot: clear the desktop plane-0 surface (0x30000000) ~0.5 s into
         * the loop — gated on the free-running ms counter (not the 1 s tick) so
         * it fires mid-first-second, well past the ~224 ms ddr_warm PL->DDR gate
         * + HDMI bring-up.  Replaces power-on DDR garbage with a clean black
         * field.  DEFERRED (not early boot): the early-boot memset reset-looped
         * when the then-ungated PL pounded DDR at t=0; same code path as the
         * working `deskfill` REPL command. */
        if (!desk_cleared && ms >= 500u) {
            volatile uint32_t *p = (volatile uint32_t *)0x30000000u;
            uint32_t words = 1080u * 2048u;     /* 1080 rows x 8192-byte stride */
            for (uint32_t i = 0; i < words; i++) p[i] = 0x00000000u;
            Xil_DCacheFlushRange((INTPTR)0x30000000u, (INTPTR)(words * 4u));
            /* Belt-and-braces: assert the compositor (bit0=0) + default scale.
             * The bitstream now resets gp0_ctrl to 0x00 (compositor) so this is
             * usually a no-op, but it keeps g_gp0 consistent and guarantees the
             * desktop is shown clean even if something poked bars earlier.  GP0
             * writes are proven safe here (deferred in the REPL loop, not the
             * early-boot window that used to hang). */
            g_gp0 = 0x00u;
            Xil_Out32(XT_BLITTER_BASE + 0x1Cu, (u32)g_gp0);
            desk_cleared = 1u;
            xil_printf("\r\ndesktop cleared + compositor on (off bars) at boot+~0.5s\r\n> ");
            for (unsigned k = 0; k < ll; k++) uart1_putc(line[k]);
        }
    }

    /* Unreachable, but make the compiler happy. */
    return 0;
}
