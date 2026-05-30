#pragma once

#include <stdint.h>
#include <stdbool.h>

// peri-RP POT scanner — replaces POKEY's M23-5 HDL discharge counter
// (was gutted in M25-3c-shadow). Owns the POT_n GPIO pins and the
// timing for discharge + count cycles.
//
// Two scan rates per Altirra §5.9:
//   - **Slow (default)**: 15 kHz reference clock, with a discharge
//     prologue (~7 ticks driving lines low). Counter clamps at 228.
//   - **Fast (SKCTL[2]=1)**: 1.79 MHz machine clock, no discharge
//     prologue (the discharge transistors are disabled in POKEY's
//     fast mode). Counter clamps at 229.
//
// Both rates are implemented by a PIO state machine running per-pin
// timers; this header is the C-side glue that:
//   - reacts to a CMD=POTGO write on the FPGA SPI bus
//   - kicks the PIO with the right scan-rate config
//   - on PIO completion, latches the per-channel counts into the
//     peri_regs POT0..7 + ALLPOT slots and sets STATUS.pot_done

// Lifecycle state. Visible for the host sim — production firmware
// keeps this opaque.
typedef enum {
    PERI_POT_IDLE      = 0,    // no scan in flight
    PERI_POT_RUNNING   = 1,    // PIO kicked; waiting for done event
    PERI_POT_LATCHING  = 2,    // PIO done, results being committed
} peri_pot_state_t;

void peri_pot_init(void);

// Called from the SPI service path when CMD register gets a POTGO
// value. `cmd` is the raw byte: bit 4 = fast_scan flag, low nibble
// = command id (0x1 for POTGO).
void peri_pot_handle_cmd(uint8_t cmd);

// Polled from core 0's main loop. If a scan is in flight and the
// PIO has signalled completion, copies per-channel counts into
// peri_regs and sets STATUS.pot_done. Returns true if state changed
// this call (mostly for the host sim).
bool peri_pot_service(void);

// Test hooks (host sim only — the PIO emulator needs to inject
// "scan complete" events from outside the firmware loop).
#ifdef PERI_POT_HOST_SIM
void peri_pot_inject_done(const uint8_t counts[8], uint8_t allpot);
peri_pot_state_t peri_pot_state(void);
bool peri_pot_last_kick_was_fast(void);
#endif
