#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// peri-RP SD card driver scaffold (M25-5).
//
// SD card hangs off the peri-RP's hardware SPI peripheral on
// dedicated pins (CK + CMD + DAT0 + /CS — see pinmap.h, M25-5
// reservation). The peri-RP runs the standard SPI-mode SD init
// sequence (CMD0 → CMD8 → ACMD41 → CMD58) and serves blocks
// (CMD17 read / CMD24 write) via a small command queue that the
// SIO firmware (M25-4) can call into for SIO-disk emulation, and
// that the FPGA can call into directly via a chiplet-extension
// SD-window (M25-5+, not in this commit).
//
// Production state machine, hardware SPI configuration, FAT32 layer,
// and the SIO-disk-emulation glue all land at hardware bring-up —
// this commit is just the C-side state shell so STATUS.sd_done can
// flow end-to-end through peri_regs / peri_irq / peri_bridge.

typedef enum {
    PERI_SD_UNINIT     = 0,    // power-on / not yet probed
    PERI_SD_INITIALISING = 1,  // running CMD0 / CMD8 / ACMD41 chain
    PERI_SD_READY      = 2,    // card responded; ready for blocks
    PERI_SD_BUSY       = 3,    // mid-block read or write
    PERI_SD_ERROR      = 4,    // init or block I/O failed
} peri_sd_state_t;

#define PERI_SD_BLOCK_BYTES 512

void peri_sd_init(void);

// Polled from core 0; advances the SD state machine, drains any
// queued block I/O requests, sets STATUS.sd_done on completion.
// Returns true if state changed this call.
bool peri_sd_service(void);

// Block-level API (callable from peri_sio.c for SIO-disk emulation
// and from a future SD-window register handler).
//
// Read/write are async: they enqueue and return immediately;
// completion is signalled by peri_sd_service() flipping the state
// out of PERI_SD_BUSY and setting STATUS.sd_done.
bool peri_sd_read_block(uint32_t block_lba, uint8_t *dst);
bool peri_sd_write_block(uint32_t block_lba, const uint8_t *src);

#ifdef PERI_POT_HOST_SIM
peri_sd_state_t peri_sd_state(void);

// Test hooks — production firmware: hardware SPI ISR fires these.
void peri_sd_inject_init_ok(void);
void peri_sd_inject_init_err(void);
void peri_sd_inject_block_done(void);
#endif
