#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// peri-RP SIO bus servicing (M25-4).
//
// The SIO bus is the Atari peripheral bus — DATAIN / DATAOUT / /COMMAND
// / /MOTOR / /PROCEED / /INTERRUPT / /READY / CLOCK_IN / CLOCK_OUT etc
// (DB-13 connector). Standard rate is 19.2 kbaud async UART; fast
// accessories (Black Box, MIO, USB-SIO bridges) push to 38.4-1024 kbaud.
//
// This module is the C side of the SIO firmware:
//
//   - Owns a small RX queue. The PIO state machine pushes received
//     bytes into it; the FPGA-side `peri_bridge` drains via SPI reads
//     of SIO_IN ($0D).
//   - Owns a small TX queue. SPI writes to SIO_OUT ($06) push bytes
//     in; the PIO state machine pops and shifts them onto DATAOUT.
//   - Maintains the STATUS.sio_rx flag (set while RX queue non-empty,
//     cleared on the read that drains the last byte) and the
//     SIO_STAT register (framing_err / input_overrun / input_busy /
//     break_key bits).
//
// PIO program (peri_sio.pio) handles bit-level UART framing on the
// DATAIN / DATAOUT pins. Stubbed today — needs hardware to calibrate
// the per-baud-rate sm clock divider against a real SIO peripheral.

#define PERI_SIO_RX_QUEUE_SIZE  16
#define PERI_SIO_TX_QUEUE_SIZE  16

void peri_sio_init(void);

// Called from the SPI service path on writes to SIO_OUT. Pushes the
// byte into the TX queue (or drops it if full — flagged via SIO_STAT
// bit eventually).
void peri_sio_handle_sio_out_write(uint8_t byte);

// Called when SPI reads SIO_IN — pops the head of the RX queue, or
// returns 0 if empty. Updates STATUS.sio_rx + SIO_STAT.
uint8_t peri_sio_handle_sio_in_read(void);

// Polled from core 0's main loop; services any pending TX/RX queue
// work + updates SIO_STAT bits. Returns true if state changed.
bool peri_sio_service(void);

#ifdef PERI_POT_HOST_SIM
// Test hooks. Production firmware: PIO ISRs feed the queue.
void peri_sio_inject_rx(uint8_t byte);
void peri_sio_inject_break(void);
void peri_sio_inject_framing_err(void);
void peri_sio_inject_overrun(void);
size_t peri_sio_tx_queue_len(void);
uint8_t peri_sio_tx_queue_pop(void);
#endif
