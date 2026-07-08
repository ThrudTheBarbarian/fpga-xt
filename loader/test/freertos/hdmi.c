/*
 * hdmi.c — SiI9022A HDMI transmitter bring-up on a BARE PS-I2C0 driver.
 *
 * The loader is bare-BSP (no Xilinx XIicPs), so this is a register-level polled
 * I2C master at 0xE0004000 (Zynq-7000 TRM ch.20). The SiI9022 TPI register
 * sequence is ported verbatim from vitis/xtos (proven on the Z-Turn V2): MIO[51]
 * reset pulse, 1080p60 timings, AVI InfoFrame (VIC=16), TMDS on.
 *
 * Compiled into every build but ACTIVE only on the HW build (XT_HW) — qemu models
 * no SiI9022/I2C, so hdmi_init() is a no-op there. Runs at PL1, pre-scheduler.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"

void hdmi_init(void);
int  xt_i2c_send(uint8_t addr, const uint8_t *buf, int n);   /* 0=ok (see /OS/dev/i2c-0) */
int  xt_i2c_recv(uint8_t addr, uint8_t *buf, int n);         /* 0=ok */

#ifdef XT_HW

extern void klog(const char *);   /* -> /OS/var/log/system.log */
extern void putu(unsigned);

static void puthex8(uint8_t v)
{
    static const char h[] = "0123456789abcdef";
    char s[5] = "0x00";
    s[2] = h[(v >> 4) & 0xF]; s[3] = h[v & 0xF];
    klog(s);
}

static void puthex32(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    char s[11] = "0x00000000";
    for (int i = 0; i < 8; i++) s[2 + i] = h[(v >> ((7 - i) * 4)) & 0xF];
    klog(s);
}

/* last-transaction diagnostics (devid-FAIL localisation) */
static volatile uint32_t g_send_isr, g_recv_isr, g_recv_sr, g_send_sr, g_send_tsr;
static volatile int      g_send_rc, g_recv_rc, g_recv_got;

/* ---- A9 global timer busy-wait (free-running at PERIPHCLK = CPU/2 = 333 MHz) -- */
static void gt_delay_us(uint32_t us)
{
    volatile uint32_t *lo = (volatile uint32_t *)0xF8F00200u;   /* global timer counter[31:0] */
    uint32_t start = *lo, ticks = us * 333u;                    /* 333 ticks/us */
    while ((uint32_t)(*lo - start) < ticks) { }
}

/* ---- bare PS-I2C0 polled master (0xE0004000) ------------------------------ */
#define I2C_BASE 0xE0004000u
#define I2C_CR   (*(volatile uint32_t *)(I2C_BASE + 0x00))   /* control          */
#define I2C_SR   (*(volatile uint32_t *)(I2C_BASE + 0x04))   /* status           */
#define I2C_AR   (*(volatile uint32_t *)(I2C_BASE + 0x08))   /* address (START)  */
#define I2C_DR   (*(volatile uint32_t *)(I2C_BASE + 0x0C))   /* data fifo        */
#define I2C_ISR  (*(volatile uint32_t *)(I2C_BASE + 0x10))   /* irq status (w1c) */
#define I2C_TSR  (*(volatile uint32_t *)(I2C_BASE + 0x14))   /* transfer size    */
#define I2C_TOR  (*(volatile uint32_t *)(I2C_BASE + 0x1C))   /* timeout (SCL periods) */
#define I2C_IDR  (*(volatile uint32_t *)(I2C_BASE + 0x28))   /* interrupt disable */

#define CR_DIV_A(n) ((uint32_t)(n) << 14)
#define CR_DIV_B(n) ((uint32_t)(n) << 8)
#define CR_CLRFIFO  (1u << 6)
#define CR_HOLD     (1u << 4)   /* hold bus (no STOP) -> repeated START */
#define CR_ACKEN    (1u << 3)
#define CR_NEA      (1u << 2)   /* normal 7-bit addressing */
#define CR_MS       (1u << 1)   /* master */
#define CR_RW       (1u << 0)   /* 1 = read */
/* master, 7-bit, ack-enable; SCL ~78 kHz @ 111 MHz ref (<=100 kHz across plausible
 * PS I2C ref clocks — conservative for the SiI9022 100 kHz limit). */
#define CR_BASE (CR_DIV_A(0) | CR_DIV_B(63) | CR_ACKEN | CR_NEA | CR_MS)

#define SR_RXDV  (1u << 5)
#define SR_BA    (1u << 8)   /* bus active */
#define ISR_COMP (1u << 0)
#define ISR_NACK (1u << 2)

/* wait for the bus to go idle (STOP completed) — MUST run between transactions,
 * else a new START fires while the previous STOP is in flight and the transfer
 * is corrupted (vitis does this via XIicPs_BusIsBusy). */
static void i2c_wait_idle(void)
{
    uint32_t to = 2000000;
    while ((I2C_SR & SR_BA) && --to) { }
}

static void i2c_init(void)
{
    /* Full reset, mirroring XIicPs_Reset: clear CR, disable ALL interrupts (we
     * poll), set the timeout, clear status — THEN set divider + master mode.
     * (The bare driver previously skipped the interrupt-disable + CR reset.) */
    I2C_CR  = 0;
    I2C_IDR = 0x2FFu;           /* disable every interrupt source */
    I2C_TOR = 0x1Fu;            /* XIicPs default timeout */
    I2C_ISR = I2C_ISR;          /* w1c: clear stale status */
    I2C_CR  = CR_BASE | CR_CLRFIFO;   /* divider + master + ackEn + 7-bit, clear FIFO */
}

/* write n bytes to slave `addr` (single transaction, auto START..STOP). 0=ok */
static int i2c_send(uint8_t addr, const uint8_t *buf, int n)
{
    i2c_wait_idle();                         /* bus idle before START */
    I2C_CR  = CR_BASE | CR_CLRFIFO;          /* write mode (matches XIicPs SetupMaster) */
    I2C_ISR = I2C_ISR;
    for (int i = 0; i < n; i++) I2C_DR = buf[i];   /* fifo depth 16 (we send <=14) */
    g_send_sr  = I2C_SR;
    g_send_tsr = I2C_TSR;                      /* bytes queued in TX FIFO (should == n) */
    I2C_AR  = addr & 0x7Fu;                   /* address write -> START */
    uint32_t to = 2000000;
    while (!(I2C_ISR & (ISR_COMP | ISR_NACK)) && --to) { }
    g_send_isr = I2C_ISR;
    g_send_rc  = (to && !(I2C_ISR & ISR_NACK)) ? 0 : -1;
    i2c_wait_idle();                         /* let STOP finish before next txn */
    return g_send_rc;
}

/* read n bytes from slave `addr` into buf. 0=ok */
static int i2c_recv(uint8_t addr, uint8_t *buf, int n)
{
    i2c_wait_idle();                          /* bus idle before START */
    I2C_CR  = CR_BASE | CR_CLRFIFO | CR_RW;   /* read mode (matches XIicPs SetupMaster) */
    I2C_ISR = I2C_ISR;
    I2C_TSR = (uint32_t)n;                     /* TSR before ADDR (XIicPs CR996440) */
    I2C_AR  = addr & 0x7Fu;                   /* address read -> START */
    int got = 0; uint32_t to = 2000000;
    while (got < n && --to) {
        if (I2C_SR & SR_RXDV) { buf[got++] = (uint8_t)I2C_DR; to = 2000000; }
        if (I2C_ISR & ISR_NACK) break;
    }
    uint32_t t2 = 2000000;                     /* wait for transfer completion */
    while (!(I2C_ISR & (ISR_COMP | ISR_NACK)) && --t2) { }
    g_recv_isr = I2C_ISR; g_recv_sr = I2C_SR; g_recv_got = got;
    g_recv_rc  = (got == n) ? 0 : -1;
    i2c_wait_idle();
    return g_recv_rc;
}

/* ---- SiI9022A TPI access (7-bit 0x3b, CI2CA=1) ---------------------------- */
#define SII_ADDR 0x3Bu
static int sii_write(uint8_t reg, uint8_t val) { uint8_t b[2] = { reg, val }; return i2c_send(SII_ADDR, b, 2); }

/* TPI register read: write the offset (STOP), then read 1 byte (START) — the
 * XIicPs MasterSend + MasterRecv sequence (bus goes idle between, via i2c_*). */
static int sii_read(uint8_t reg, uint8_t *val)
{
    if (i2c_send(SII_ADDR, &reg, 1)) return -1;
    return i2c_recv(SII_ADDR, val, 1);
}

/* MIO[51] (GPIO bank1 bit19, MSW bit3) gates SiI9022 RESET#. Pulse LOW >=10 ms,
 * HIGH, then >=15 ms to stabilise (datasheet) — verbatim from vitis. */
static void sii9022_reset(void)
{
    volatile uint32_t *gpio = (volatile uint32_t *)0xE000A000u;
    gpio[0x244 / 4] = 0x00080000;   /* DIRM_1: MIO[51] output         */
    gpio[0x248 / 4] = 0x00080000;   /* OEN_1:  MIO[51] output enable   */
    gpio[0x00C / 4] = 0xFFF70000;   /* MASK_DATA_1_MSW: RESET# LOW     */
    gt_delay_us(10000);
    gpio[0x00C / 4] = 0xFFF70008;   /* RESET# HIGH (release)           */
    gt_delay_us(15000);
}

/* Establish the 1080p60 RGB output (TPI order; everything latches in D0). Ported
 * verbatim from vitis sii_enable_output(). */
static void sii_enable_output(void)
{
    sii_write(0x1A, 0x11);                          /* HDMI mode, TMDS off        */
    sii_write(0x1E, 0x00);                          /* power D0 (config latches)  */
    sii_write(0x00, 0xFC); sii_write(0x01, 0x39);   /* pixel clock 148.4375 MHz   */
    sii_write(0x02, 0x70); sii_write(0x03, 0x17);   /* vfreq 60.00 Hz             */
    sii_write(0x04, 0x98); sii_write(0x05, 0x08);   /* H total 2200               */
    sii_write(0x06, 0x65); sii_write(0x07, 0x04);   /* V total 1125               */
    sii_write(0x08, 0x70);                          /* input bus: TClk x1, rising */
    sii_write(0x09, 0x00); sii_write(0x0A, 0x00);   /* input/output format = RGB  */
    {                                               /* AVI InfoFrame: 1080p60 VIC=16 */
        uint8_t avi[14]; unsigned i; uint8_t sum;
        avi[0] = 0x00;                              /* checksum (filled below)    */
        avi[1] = 0x00; avi[2] = 0x28; avi[3] = 0x00;
        avi[4] = 16;   avi[5] = 0x00;               /* VIC=16, no pixel repeat    */
        for (i = 6; i < 14; i++) avi[i] = 0x00;
        sum = (uint8_t)(0x82 + 0x02 + 0x0D);
        for (i = 1; i < 14; i++) sum = (uint8_t)(sum + avi[i]);
        avi[0] = (uint8_t)(0x100u - sum);
        for (i = 0; i < 14; i++) sii_write((uint8_t)(0x0C + i), avi[i]);  /* 0x19 commits */
    }
    sii_write(0x60, 0x00);                          /* external sync (after AVI)  */
    sii_write(0x63, 0x00);                          /* DE generator OFF -> DE_IN  */
    sii_write(0xBC, 0x01); sii_write(0xBD, 0x82);   /* source termination on      */
    { uint8_t t = 0; sii_read(0xBE, &t); sii_write(0xBE, (uint8_t)(t | 0x01)); }
    sii_write(0x1A, 0x01);                          /* HDMI, TMDS ON (last)       */
    sii_write(0x3D, 0x03);                          /* clear any latched HPD/RSEN events — start
                                                     * the service loop clean (datasheet step 1) */

    klog("[hdmi] post-cfg 1A/1E/60/61=");
    { uint8_t a = 0, p = 0, s = 0, sp = 0;
      sii_read(0x1A, &a); sii_read(0x1E, &p); sii_read(0x60, &s); sii_read(0x61, &sp);
      puthex8(a); klog(" "); puthex8(p); klog(" "); puthex8(s); klog(" "); puthex8(sp); klog("\r\n"); }
}

void hdmi_init(void)
{
    sii9022_reset();
    i2c_init();
    sii_write(0xC7, 0x00);       /* enter TPI mode — SiI9022 powers up in non-TPI/DDC
                                  * pass-through; without this, TPI reads auto-increment
                                  * the wrong space (vitis main.c "step 1"). */
    gt_delay_us(1000);
    uint8_t devid = 0; int ok = 0;
    for (int i = 0; i < 50; i++) {                  /* poll TPI device-id 0x1B == 0xB0 */
        if (sii_read(0x1B, &devid) == 0 && devid == 0xB0) { ok = 1; break; }
        gt_delay_us(2000);
    }
    if (!ok) { klog("[hdmi] SiI9022 not responding (devid != 0xB0)\r\n"); return; }
    sii_enable_output();
    klog("[hdmi] SiI9022 devid=0xB0, 1080p60 enabled\r\n");
}

/* ---- post-boot I2C sharing --------------------------------------------------
 * Post-scheduler bus users: the fs task (devfs ioctls + /OS/proc/video reads)
 * and the HPD watcher task below.  One mutex serialises them (hdmi_init runs
 * pre-scheduler and needs none). */
static SemaphoreHandle_t s_i2c_mtx;
static void i2c_lock(void)   { if (s_i2c_mtx) xSemaphoreTake(s_i2c_mtx, portMAX_DELAY); }
static void i2c_unlock(void) { if (s_i2c_mtx) xSemaphoreGive(s_i2c_mtx); }

/* PS-I2C0 access for /OS/dev/i2c-0 (vfs_devfs.c). */
int xt_i2c_send(uint8_t addr, const uint8_t *buf, int n)
{ int r; i2c_lock(); r = i2c_send(addr, buf, n); i2c_unlock(); return r; }
int xt_i2c_recv(uint8_t addr, uint8_t *buf, int n)
{ int r; i2c_lock(); r = i2c_recv(addr, buf, n); i2c_unlock(); return r; }

/* one SiI9022 register for /OS/proc/video (-1 = read failed) */
int hdmi_sii_read(int reg)
{
    uint8_t v; int r;
    i2c_lock(); r = sii_read((uint8_t)reg, &v); i2c_unlock();
    return r == 0 ? (int)v : -1;
}

/* Board temp sensor (LM75-family) on I2C0 at 0x49.  Read reg 0x00 as 2 bytes =
 * signed Q8.8 degrees C (MSB = integer C as `i2cget 0 0x49 0x00` returns; LSB =
 * fraction, bit7 = 0.5C, lower bits finer if the part supports it).  Returns
 * milli-degrees C, or -1000000 on I2C error.  Shares the bus with the SiI9022
 * (0x3B) — a clean read to 0x49 doesn't touch it, but I2C traffic is a suspect
 * for the HDMI re-acquire (see /OS/proc/video-sii), hence a separate node. */
int hdmi_temp_i2c(void)
{
    uint8_t reg = 0x00, b[2]; int r;
    i2c_lock();
    r = i2c_send(0x49, &reg, 1);
    if (r == 0) r = i2c_recv(0x49, b, 2);
    i2c_unlock();
    if (r) return -1000000;
    int16_t raw = (int16_t)(((uint16_t)b[0] << 8) | b[1]);
    return (int)raw * 1000 / 256;               /* Q8.8 -> milli-C */
}

/* Soft REPLUG: a bare config rewrite doesn't recover a monitor that has given
 * up on the link (verified on HW — /OS/proc/video-kick did nothing while a
 * physical replug recovered).  Take TMDS down long enough for the sink to see
 * real signal loss, then bring the whole output back up (config + InfoFrame +
 * TMDS) so it re-acquires exactly as it would on a cable insert. */
void hdmi_reinit(void)
{
    i2c_lock();
    sii_write(0x1A, 0x11);                /* HDMI mode, TMDS OFF               */
    gt_delay_us(500000);                  /* 500 ms of dark — a real unplug    */
    sii_enable_output();
    i2c_unlock();
    klog("[hdmi] soft-replug: TMDS cycled + output re-enabled\r\n");
}

/* ---- receiver-sense watcher ------------------------------------------------
 * HPD is NOT reliably wired on this board: TPI 0x3D bit2 (Hot-Plug pin state)
 * reads LOW even with a live, powered sink — confirmed against RxSense=1 and the
 * SiI9022 TPI programmer's ref (bit2 = "display attached / EDID readable"; ours
 * is stuck 0 with the monitor plainly present).  So we IGNORE HPD and trust
 * RxSense (bit3, "TMDS lines pulled to 3.3 V by a powered receiver") as the only
 * honest sink-present signal.
 *
 * Per the TPI ref a real UNPLUG needs BOTH bits low (0x3D[3:2]==00); HPD-low with
 * RxSense-high is "connection instability", to be ignored — NOT a sink loss.  That
 * matters because with HPD stuck low, a DDR-burst power transient that briefly dips
 * RxSense would otherwise read as a confirmed unplug.  We DEBOUNCE RxSense-low so a
 * momentary dip never costs a gratuitous soft-replug; only a sustained loss (a real
 * unplug) re-acquires.  Poll once a second, silent while healthy. */
static void hdmi_watch_task(void *arg)
{
    (void)arg;
    int lost = 0;                                          /* consecutive 1s polls with RxSense low */
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        uint8_t st = 0;
        i2c_lock();
        int rd = sii_read(0x3D, &st);
        if (rd == 0 && (st & 0x03)) sii_write(0x3D, (uint8_t)(st & 0x03));   /* W1C the latched events */
        i2c_unlock();
        if (rd != 0) continue;                             /* I2C hiccup: skip this tick */
        if (st & 0x08) { lost = 0; continue; }             /* RxSense high = receiver present -> healthy */
        if (++lost < 3) continue;                          /* RxSense low <3 s: transient (DDR burst) — ride it out */
        if (lost == 3) {                                   /* 3 s of RxSense-low = a genuine unplug: re-acquire once */
            extern void gtimer_timeofday(uint32_t *, uint32_t *); extern void klog_u(unsigned);
            uint32_t s, u; gtimer_timeofday(&s, &u);
            klog("[hdmi] t+"); klog_u(s); klog("s receiver gone (RxSense low 3 s) — soft-replug\r\n");
            hdmi_reinit();
        }
    }
}

void hdmi_watch_init(void)
{
    s_i2c_mtx = xSemaphoreCreateMutex();
    xTaskCreate(hdmi_watch_task, "hdmiwatch", 512, 0, 1, 0);
}

#else  /* qemu: no SiI9022/I2C modelled */
void hdmi_init(void) { }
int xt_i2c_send(uint8_t addr, const uint8_t *buf, int n)
{ (void)addr; (void)buf; (void)n; return -1; }
int xt_i2c_recv(uint8_t addr, uint8_t *buf, int n)
{ (void)addr; (void)buf; (void)n; return -1; }
int hdmi_sii_read(int reg) { (void)reg; return -1; }
int hdmi_temp_i2c(void) { return -1000000; }
void hdmi_reinit(void) { }
void hdmi_watch_init(void) { }
#endif
