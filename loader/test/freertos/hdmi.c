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

void hdmi_init(void);

#ifdef XT_HW

extern void puts0(const char *);
extern void putu(unsigned);

static void puthex8(uint8_t v)
{
    static const char h[] = "0123456789abcdef";
    char s[5] = "0x00";
    s[2] = h[(v >> 4) & 0xF]; s[3] = h[v & 0xF];
    puts0(s);
}

static void puthex32(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    char s[11] = "0x00000000";
    for (int i = 0; i < 8; i++) s[2 + i] = h[(v >> ((7 - i) * 4)) & 0xF];
    puts0(s);
}

/* last-transaction diagnostics (devid-FAIL localisation) */
static volatile uint32_t g_send_isr, g_recv_isr, g_recv_sr, g_send_sr;
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
    I2C_CR  = CR_BASE | CR_CLRFIFO;
    I2C_TOR = 0xFFu;             /* timeout (XIicPs sets this; omitting it can wedge) */
    I2C_ISR = I2C_ISR;          /* w1c: clear stale status */
}

/* write n bytes to slave `addr` (single transaction, auto START..STOP). 0=ok */
static int i2c_send(uint8_t addr, const uint8_t *buf, int n)
{
    i2c_wait_idle();                         /* bus idle before START */
    I2C_CR  = CR_BASE;                        /* write mode (FIFO already empty; do NOT
                                              * strobe CLR_FIFO here — its flush runs over
                                              * I2C-clock periods and eats the data byte) */
    I2C_ISR = I2C_ISR;
    for (int i = 0; i < n; i++) I2C_DR = buf[i];   /* fifo depth 16 (we send <=14) */
    g_send_sr = I2C_SR;                        /* TXDV(bit6) here => data queued before START */
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
    I2C_CR  = CR_BASE | CR_RW;                /* read mode (no per-txn CLR_FIFO — see send) */
    I2C_ISR = I2C_ISR;
    I2C_TSR = (uint32_t)n;
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

/* TPI random read via a REPEATED START: offset-write + read in ONE held
 * transaction (the I2C-correct sequence for a register read). stop-then-start
 * left the SiI's offset un-latched here (reads auto-incremented). */
static int sii_read(uint8_t reg, uint8_t *val)
{
    i2c_wait_idle();
    /* phase 1: START + addr(W) + offset byte, bus HELD (no STOP) */
    I2C_CR  = CR_BASE | CR_HOLD;
    I2C_ISR = I2C_ISR;
    I2C_DR  = reg;
    I2C_AR  = SII_ADDR & 0x7Fu;
    uint32_t to = 2000000;
    while (!(I2C_ISR & (ISR_COMP | ISR_NACK)) && --to) { }
    g_send_isr = I2C_ISR; g_send_sr = I2C_SR;
    if (!to || (I2C_ISR & ISR_NACK)) { I2C_CR &= ~CR_HOLD; i2c_wait_idle(); g_send_rc = -1; return -1; }
    g_send_rc = 0;
    /* phase 2: repeated START + addr(R), read 1 byte, drop HOLD -> STOP */
    I2C_CR  = CR_BASE | CR_HOLD | CR_RW;
    I2C_ISR = I2C_ISR;
    I2C_TSR = 1u;
    I2C_AR  = SII_ADDR & 0x7Fu;
    I2C_CR &= ~CR_HOLD;                  /* release so STOP follows the 1 byte */
    int got = 0; to = 2000000;
    while (got < 1 && --to) {
        if (I2C_SR & SR_RXDV) { *val = (uint8_t)I2C_DR; got = 1; }
        if (I2C_ISR & ISR_NACK) break;
    }
    g_recv_isr = I2C_ISR; g_recv_sr = I2C_SR; g_recv_got = got;
    g_recv_rc = got ? 0 : -1;
    i2c_wait_idle();
    return got ? 0 : -1;
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

    puts0("[hdmi] post-cfg 1A/1E/60/61=");
    { uint8_t a = 0, p = 0, s = 0, sp = 0;
      sii_read(0x1A, &a); sii_read(0x1E, &p); sii_read(0x60, &s); sii_read(0x61, &sp);
      puthex8(a); puts0(" "); puthex8(p); puts0(" "); puthex8(s); puts0(" "); puthex8(sp); puts0("\r\n"); }
}

void hdmi_init(void)
{
    puts0("[hdmi] SiI9022 bring-up (bare I2C0)...\r\n");
    sii9022_reset();
    i2c_init();
    puts0("[hdmi] i2c CR(readback)="); puthex32(I2C_CR); puts0("\r\n");
    { uint8_t rr[3] = { 0xEE, 0xEE, 0xEE };     /* vitis: 1B=B0 1C=02 1D=03 */
      sii_read(0x1B, &rr[0]); sii_read(0x1C, &rr[1]); sii_read(0x1D, &rr[2]);
      puts0("[hdmi] dump 1B/1C/1D="); puthex8(rr[0]); puts0(" "); puthex8(rr[1]);
      puts0(" "); puthex8(rr[2]);
      puts0("  send_sr(after fill)="); puthex32(g_send_sr); puts0("\r\n"); }
    uint8_t devid = 0; int ok = 0;
    for (int i = 0; i < 50; i++) {                  /* poll TPI device-id 0x1B == 0xB0 */
        if (sii_read(0x1B, &devid) == 0 && devid == 0xB0) { ok = 1; break; }
        gt_delay_us(2000);
    }
    puts0("[hdmi] devid="); puthex8(devid);
    puts0(ok ? " (OK)\r\n" : " (FAIL — no SiI9022 ACK on I2C0)\r\n");
    if (!ok) {
        puts0("[hdmi]   diag: send_rc=");  putu((unsigned)(g_send_rc & 0xFF));
        puts0(" send_isr=");  puthex32(g_send_isr);
        puts0("  recv_rc=");  putu((unsigned)(g_recv_rc & 0xFF));
        puts0(" recv_isr=");  puthex32(g_recv_isr);
        puts0(" recv_sr=");   puthex32(g_recv_sr);
        puts0(" got=");       putu((unsigned)g_recv_got); puts0("\r\n");
        return;
    }
    sii_enable_output();
    puts0("[hdmi] output enabled (1080p60)\r\n");
}

#else  /* qemu: no SiI9022/I2C modelled */
void hdmi_init(void) { }
#endif
