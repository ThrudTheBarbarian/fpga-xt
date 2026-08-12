/* spi_link.h — FPGA<->STM32 register map and link API; see spi_link.c.
 *
 * Addresses follow the draft map in docs/OS/sio-bridge.md.  The PORTA/PORTB/
 * TRIG block that once lived at $00-$02 went to a PCAL9722 expander and is now
 * retired; joysticks come back here at $10 because this MCU reads them
 * directly off GPIOD.
 */
#ifndef SPI_LINK_H
#define SPI_LINK_H

#include <stdint.h>

/* reads (cmd bit 7 = 1) */
#define SPI_REG_STATUS      0x03    /* flag byte; write-1-to-clear          */
#define SPI_REG_ALLPOT      0x04    /* pot scan-complete mask               */
#define SPI_REG_POT0        0x05    /* $05..$0C = POT0..POT7, POKEY 0..228  */
#define SPI_REG_SIO_IN      0x0D
#define SPI_REG_SIO_STAT    0x0E
#define SPI_REG_JOY0        0x10    /* $10..$13 = ILL, IL, IR, IRR          */
#define SPI_REG_KBD_CODE    0x14    /* Atari KBCODE                         */
#define SPI_REG_KBD_STAT    0x15
#define SPI_REG_MOUSE_DX    0x16    /* signed 8-bit delta since last read   */
#define SPI_REG_MOUSE_DY    0x17
#define SPI_REG_MOUSE_BTN   0x18

/* writes (cmd bit 7 = 0) */
#define SPI_REG_POT_OE      0x04
#define SPI_REG_CMD         0x05    /* PIA CB2 command strobe               */
#define SPI_REG_SIO_OUT     0x06

/* STATUS bits — the FPGA reads STATUS to find out why the doorbell rang */
#define SPI_STATUS_KBD      0x01
#define SPI_STATUS_MOUSE    0x02
#define SPI_STATUS_SIO      0x04
#define SPI_STATUS_JOY      0x08

#define SPI_SIO_STAT_TX_PENDING 0x01

void     spi_link_init(void);
void     spi_link_post_key(uint8_t kbcode, uint8_t stat);
void     spi_link_post_mouse(int8_t dx, int8_t dy, uint8_t buttons);
void     spi_link_post_sio(uint8_t byte);
void     spi_link_status(void);
uint32_t spi_link_transactions(void);
uint32_t spi_link_resyncs(void);

#endif /* SPI_LINK_H */
