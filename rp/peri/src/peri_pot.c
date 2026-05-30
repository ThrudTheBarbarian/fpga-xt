// peri_pot.c — POT scanner C state machine.
//
// PIO program lives in peri_pot.pio (referenced by the production
// build path). The .pio is *not* exercised by the host sim — only
// the C state machine + the peri_regs glue is tested there. Hardware
// bring-up validates the PIO timing.

#include "peri_pot.h"

#include <string.h>

#include "peri_regs.h"
#include "peri_irq.h"

// ---- Internal state -------------------------------------------------
static peri_pot_state_t g_state;
static bool             g_last_kick_fast;
static uint8_t          g_pending_cmd;     // 0 = none

// Cached scan results. The PIO drops counts here via DMA in the
// production path; the host sim writes them via peri_pot_inject_done.
static uint8_t          g_count[8];
static uint8_t          g_allpot;
static bool             g_results_ready;

// ---- Public API -----------------------------------------------------

void peri_pot_init(void) {
    g_state          = PERI_POT_IDLE;
    g_last_kick_fast = false;
    g_pending_cmd    = 0;
    g_results_ready  = false;
    memset(g_count, 0, sizeof(g_count));
    g_allpot         = 0;
    // Initial peri_regs state: all POT0..7 / ALLPOT zero, STATUS clear.
    for (uint8_t i = 0; i < 8; i++) peri_regs_set(PERI_R_POT0 + i, 0);
    peri_regs_set(PERI_R_ALLPOT, 0);
    peri_regs_set(PERI_R_STATUS, 0);
}

void peri_pot_handle_cmd(uint8_t cmd) {
    // Decode: low nibble = command id, bit 4 = fast/slow scan.
    if ((cmd & 0x0Fu) != 0x01u) {
        // Not a POTGO. Future commands (SIO_TX etc.) land here too;
        // this handler ignores them.
        return;
    }
    g_last_kick_fast = (cmd & 0x10u) != 0u;
    g_pending_cmd    = cmd;

    // Software contract on the FPGA side: writing POTGO sets ALLPOT
    // to all-1s immediately. Mirror that on the peri-RP side so the
    // first poll reads the "all scanning" mask while the PIO is still
    // running.
    g_allpot = 0xFFu;
    peri_regs_set(PERI_R_ALLPOT, 0xFFu);
    // Also clear any prior pot_done flag so the bridge knows to wait.
    {
        uint8_t status = peri_regs_get(PERI_R_STATUS);
        peri_regs_set(PERI_R_STATUS, status & (uint8_t)~PERI_STATUS_POT_DONE);
    }

    g_state = PERI_POT_RUNNING;

    // Production firmware: configure PIO sm clock divider for slow
    // (15 kHz tick) vs fast (1.79 MHz) scan, restart the PIO program,
    // arm the per-channel result FIFO. Stubbed here — the host sim
    // injects results via peri_pot_inject_done().
}

bool peri_pot_service(void) {
    if (g_state != PERI_POT_LATCHING) return false;

    // PIO has finished — copy results into peri_regs.
    for (uint8_t i = 0; i < 8; i++) {
        peri_regs_set((uint8_t)(PERI_R_POT0 + i), g_count[i]);
    }
    peri_regs_set(PERI_R_ALLPOT, g_allpot);
    {
        uint8_t status = peri_regs_get(PERI_R_STATUS);
        peri_regs_set(PERI_R_STATUS, status | PERI_STATUS_POT_DONE);
        peri_irq_update();        // STATUS gained pot_done → assert IRQ_OUT
    }

    g_state         = PERI_POT_IDLE;
    g_pending_cmd   = 0;
    g_results_ready = false;
    return true;
}

#ifdef PERI_POT_HOST_SIM
void peri_pot_inject_done(const uint8_t counts[8], uint8_t allpot) {
    memcpy(g_count, counts, sizeof(g_count));
    g_allpot        = allpot;
    g_results_ready = true;
    g_state         = PERI_POT_LATCHING;
}

peri_pot_state_t peri_pot_state(void) { return g_state; }
bool peri_pot_last_kick_was_fast(void) { return g_last_kick_fast; }
#endif
