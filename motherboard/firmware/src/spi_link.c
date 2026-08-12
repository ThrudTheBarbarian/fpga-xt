/* spi_link.c — the byte-level link to the FPGA.
 *
 * The FPGA is the SPI master (hdl/peri_link.sv); we are the only slave. A
 * transaction is two 8-bit frames, MSB-first, SPI mode 0:
 *
 *     frame 1 (cmd)   MOSI = R/W in bit 7, addr in bits 6..0;  MISO ignored
 *     frame 2 (data)  MOSI = write payload;  MISO = read response
 *
 * with a master-controlled gap between them so we can decode the command and
 * load the response before the data frame is clocked.
 *
 * NO HARDWARE NSS.  PA4, which would be SPI1_NSS, carries the STM->FPGA
 * doorbell instead — the master cannot be interrupted by a slave, so that line
 * is the only way we can start a conversation.  We therefore run with software
 * slave management (SSM=1, SSI=0: permanently selected) and the SPI peripheral
 * gives us no framing at all; it simply shifts a byte at a time forever.
 *
 * That works because the master always clocks clean multiples of eight from
 * idle, but it has one failure mode: lose or gain a single byte and the
 * cmd/data phase is inverted for ever, with nothing to resynchronise it.  So
 * the phase is also gated on time — transactions are a few microseconds long
 * and the gaps between them are far longer, so a byte arriving after a long
 * idle is unambiguously a command byte.  One glitch costs one transaction
 * instead of the link.
 */
#include "spi_link.h"

#include "board.h"
#include "clock.h"
#include "console.h"
#include "joystick.h"
#include "pots.h"

/* A whole transaction is ~4 us at 5 MHz. Anything arriving more than this
 * after the previous byte cannot be the second half of one. */
#define RESYNC_IDLE_US  50U

enum { PHASE_CMD, PHASE_DATA };

static volatile uint8_t  s_phase;
static volatile uint8_t  s_addr;
static volatile uint8_t  s_is_read;
static volatile uint32_t s_last_cycle;
static volatile uint32_t s_transactions;
static volatile uint32_t s_resyncs;

/* Register file mirrored to the FPGA.  Addresses follow the draft map in
 * docs/OS/sio-bridge.md; the joystick, keyboard and mouse blocks are new,
 * replacing the retired PCAL9722 expander path. */
static volatile uint8_t s_status;
static volatile uint8_t s_sio_in;
static volatile uint8_t s_sio_stat;
static volatile uint8_t s_kbd_code;
static volatile uint8_t s_kbd_stat;
static volatile int8_t  s_mouse_dx, s_mouse_dy;
static volatile uint8_t s_mouse_btn;

void spi_link_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;
    RCC->APB2ENR |= RCC_APB2ENR_SPI1;

    gpio_af(GPIO_SPI, PIN_STM_SCLK, AF_SPI1);
    gpio_af(GPIO_SPI, PIN_STM_MISO, AF_SPI1);
    gpio_af(GPIO_SPI, PIN_STM_MOSI, AF_SPI1);
    gpio_speed(GPIO_SPI, PIN_STM_MISO, GPIO_SPEED_HIGH);
    /* SCK and MOSI are driven by the master; no pulls, they are never floating
     * once the FPGA is configured. */
    gpio_pull(GPIO_SPI, PIN_STM_SCLK, GPIO_PULL_NONE);
    gpio_pull(GPIO_SPI, PIN_STM_MOSI, GPIO_PULL_NONE);

    /* Slave, mode 0 (CPOL=0/CPHA=0), 8-bit, MSB first, software slave
     * management asserted so the peripheral considers itself selected. */
    SPI1->CR1 = SPI_CR1_SSM;                /* MSTR=0, SSI=0 => selected */
    SPI1->CR2 = SPI_CR2_RXNEIE;
    SPI1->DR  = 0;                          /* preload MISO with a known byte */
    SPI1->CR1 |= SPI_CR1_SPE;

    /* Above USB: missing an SPI byte desynchronises the link, whereas USB
     * tolerates a few microseconds of latency. */
    nvic_priority(IRQ_SPI1, 2);
    nvic_enable(IRQ_SPI1);

    s_phase      = PHASE_CMD;
    s_last_cycle = clock_cycles();
}

/* Read side of the register file.  Runs in the SPI ISR, so it must not block
 * and must not touch anything a lower-priority context might be mid-update on
 * — everything here is a single byte read. */
static uint8_t reg_read(uint8_t addr)
{
    switch (addr) {
    case SPI_REG_STATUS:    return s_status;
    case SPI_REG_ALLPOT:    return 0xFF;            /* all pots always scanned */
    case SPI_REG_SIO_IN:    return s_sio_in;
    case SPI_REG_SIO_STAT:  return s_sio_stat;
    case SPI_REG_KBD_CODE:  return s_kbd_code;
    case SPI_REG_KBD_STAT:  return s_kbd_stat;
    case SPI_REG_MOUSE_DX:  return (uint8_t)s_mouse_dx;
    case SPI_REG_MOUSE_DY:  return (uint8_t)s_mouse_dy;
    case SPI_REG_MOUSE_BTN: return s_mouse_btn;
    default:
        break;
    }

    if (addr >= SPI_REG_POT0 && addr < SPI_REG_POT0 + 8)
        return pots_value(addr - SPI_REG_POT0);
    if (addr >= SPI_REG_JOY0 && addr < SPI_REG_JOY0 + JOY_PORTS)
        return joystick_state(addr - SPI_REG_JOY0);

    return 0xFF;
}

static void reg_write(uint8_t addr, uint8_t data)
{
    switch (addr) {
    case SPI_REG_SIO_OUT:
        /* SIO transmit lands here; the SIO layer picks it up (task #10). */
        s_sio_stat |= SPI_SIO_STAT_TX_PENDING;
        s_sio_in    = data;
        break;

    case SPI_REG_CMD:
        /* PIA CB2 command strobe, mirrored onto the DIN connector. */
        gpio_write(GPIO_SIO_CTL, PIN_SIO_CMD, !(data & 1U));
        break;

    case SPI_REG_STATUS:
        /* Writing STATUS acknowledges the flags the FPGA has consumed. */
        s_status &= (uint8_t)~data;
        break;

    default:
        break;
    }
}

void spi1_handler(void)
{
    uint32_t sr = SPI1->SR;

    if (sr & SPI_SR_OVR) {
        (void)SPI1->DR;                     /* DR-then-SR read clears OVR */
        (void)SPI1->SR;
        s_phase = PHASE_CMD;
        s_resyncs++;
        return;
    }
    if (!(sr & SPI_SR_RXNE))
        return;

    uint8_t  byte = (uint8_t)SPI1->DR;
    uint32_t now  = clock_cycles();

    /* Time-based resync: a byte this long after the last one starts a new
     * transaction whatever we thought the phase was. */
    if ((now - s_last_cycle) > RESYNC_IDLE_US * (SYSCLK_HZ / 1000000UL)) {
        if (s_phase != PHASE_CMD)
            s_resyncs++;
        s_phase = PHASE_CMD;
    }
    s_last_cycle = now;

    if (s_phase == PHASE_CMD) {
        s_is_read = (byte & 0x80U) != 0U;
        s_addr    = byte & 0x7FU;

        /* Load MISO now so the data frame finds it ready — this is what the
         * master's inter-frame gap exists for. */
        SPI1->DR = s_is_read ? reg_read(s_addr) : 0U;
        s_phase  = PHASE_DATA;
    } else {
        if (!s_is_read)
            reg_write(s_addr, byte);
        SPI1->DR = 0;                       /* known idle byte on MISO */
        s_phase  = PHASE_CMD;
        s_transactions++;
    }
}

/* ------------------------------------------------------------ producers ---*/

void spi_link_post_key(uint8_t kbcode, uint8_t stat)
{
    s_kbd_code = kbcode;
    s_kbd_stat = stat;
    s_status  |= SPI_STATUS_KBD;
    board_doorbell();
}

void spi_link_post_mouse(int8_t dx, int8_t dy, uint8_t buttons)
{
    s_mouse_dx  = dx;
    s_mouse_dy  = dy;
    s_mouse_btn = buttons;
    s_status   |= SPI_STATUS_MOUSE;
    board_doorbell();
}

void spi_link_post_sio(uint8_t byte)
{
    s_sio_in  = byte;
    s_status |= SPI_STATUS_SIO;
    board_doorbell();
}

/* ------------------------------------------------------------- reporting -*/

void spi_link_status(void)
{
    console_printf("transactions %lu  resyncs %lu\r\n",
                   s_transactions, s_resyncs);
    console_printf("status %02x  phase %s  sck %d mosi %d\r\n",
                   s_status, s_phase == PHASE_CMD ? "cmd" : "data",
                   gpio_read(GPIO_SPI, PIN_STM_SCLK),
                   gpio_read(GPIO_SPI, PIN_STM_MOSI));
    console_printf("fpga command in %d  interrupt out %d  proceed out %d\r\n",
                   gpio_read(GPIO_FPGA_CTL, PIN_FPGA_COMMAND),
                   gpio_read(GPIO_FPGA_CTL, PIN_FPGA_INTERRUPT),
                   gpio_read(GPIO_FPGA_CTL, PIN_FPGA_PROCEED));
}

uint32_t spi_link_transactions(void) { return s_transactions; }
uint32_t spi_link_resyncs(void)      { return s_resyncs; }
