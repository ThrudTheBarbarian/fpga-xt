#pragma once

#include <stdint.h>
#include <stdbool.h>

// peri-RP register map. Mirrors the address space defined in the FPGA-
// side ../../../hdl/peri_link.sv header — drift between the two will
// cause silent miswrites, so any register-table change here MUST be
// reflected over there in the same commit.
//
// Frame format on the wire (16 bits, MSB-first, SPI MODE 0):
//
//   bit 15      : R/W   (1 = read,  0 = write)
//   bits 14..8  : addr  (7-bit register number — this file's enums)
//   bits 7..0   : data  (write payload OR read result on MISO)
//
// The FPGA is the bus master; peri-RP services every read by driving
// MISO bits 7..0 from `peri_regs[addr]`, and every write by storing
// the data byte into `peri_regs[addr]` (with side-effects for
// command-style addresses like CMD).

// Joystick / fire-button traffic moved off the peri-RP onto a
// dedicated PCAL9722 GPIO expander (see ../../../hdl/joy_link.sv).
// The peri-RP keeps POT / SIO / SD because those have hard timing
// requirements the PCAL9722's 5 MHz SPI ceiling can't service.

// ---- Read addresses (R/W bit set on the wire) ------------------------
typedef enum {
    PERI_R_STATUS    = 0x03,   // [0]=pot_done [1]=sio_rx [2]=sd_done
    PERI_R_ALLPOT    = 0x04,   // bit i = 1 while POT_i still scanning
    PERI_R_POT0      = 0x05,   // POT scan counts 0..7
    PERI_R_POT7      = 0x0C,
    PERI_R_SIO_IN    = 0x0D,   // byte received from SIO bus
    PERI_R_SIO_STAT  = 0x0E,   // SIO protocol status flags
    // 0x0F..0x1F reserved for SD-card window (M25-5)
} peri_read_addr_t;

// ---- Write addresses (R/W bit clear on the wire) ---------------------
typedef enum {
    PERI_W_POT_OE    = 0x04,   // POT discharge enable mask
    PERI_W_CMD       = 0x05,   // command pulse (0x01=POTGO 0x02=SIO_TX ...)
    PERI_W_SIO_OUT   = 0x06,   // byte to transmit on SIO
    // 0x07..0x1F reserved
} peri_write_addr_t;

// ---- Command byte values (written to PERI_W_CMD) ---------------------
typedef enum {
    PERI_CMD_POTGO   = 0x01,   // start a POT discharge/count cycle
    PERI_CMD_SIO_TX  = 0x02,   // start SIO byte transmission
} peri_cmd_t;

// ---- Status flag bits (read from PERI_R_STATUS) ----------------------
#define PERI_STATUS_POT_DONE  (1u << 0)   // ALLPOT all-clear since last read
#define PERI_STATUS_SIO_RX    (1u << 1)   // SIO_IN holds an unread byte
#define PERI_STATUS_SD_DONE   (1u << 2)   // SD operation complete

// ---- Public state ----------------------------------------------------
// 128-byte addressable register file. M25-3a backs everything in plain
// SRAM with no side-effects; M25-3b/c/d wires PORTA / PORTB / POT /
// SIO / SD into this table behind read-/write-hook callbacks.
#define PERI_REGS_SIZE 128

void peri_regs_init(void);

// SPI-side hook — called from the SPI slave polling loop with the
// 7-bit register address and either the byte to write (R/W = 0) or
// a placeholder 0 (R/W = 1, writes are ignored). The return value
// is the byte to send back on MISO during the data half of the same
// frame; it's only meaningful when is_read is true.
uint8_t peri_regs_handle(uint8_t addr, bool is_read, uint8_t wdata);

// Direct register-file access for the firmware's internal state
// (joystick / POT / IRQ updaters). These bypass the SPI hook —
// useful for the polled-shadow inputs and the IRQ-on-change check.
uint8_t peri_regs_get(uint8_t addr);
void    peri_regs_set(uint8_t addr, uint8_t value);
