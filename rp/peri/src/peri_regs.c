// peri-RP register file — flat 128-byte addressable store with a
// few register-specific side-effect hooks. M25-3c adds the
// CMD-register POTGO handler; M25-4 / M25-5 will layer SIO + SD
// commands here too.

#include "peri_regs.h"

#include <string.h>

#include "peri_pot.h"
#include "peri_irq.h"
#include "peri_sio.h"

static uint8_t g_regs[PERI_REGS_SIZE];

void peri_regs_init(void) {
    memset(g_regs, 0, sizeof(g_regs));
    // No initial overrides yet — POT / SIO / SD shadows wake up at 0
    // and get populated by the firmware's scanners (M25-3c onwards).
}

uint8_t peri_regs_get(uint8_t addr) {
    return g_regs[addr & 0x7Fu];
}

void peri_regs_set(uint8_t addr, uint8_t value) {
    g_regs[addr & 0x7Fu] = value;
}

uint8_t peri_regs_handle(uint8_t addr, bool is_read, uint8_t wdata) {
    addr &= 0x7Fu;
    if (is_read) {
        // SIO_IN reads pop the head of the RX queue + refresh the
        // SIO_RX status bit. Do this BEFORE capturing the regs[]
        // value so we return the freshly-popped byte (the queue
        // updates g_regs[PERI_R_SIO_IN] each time the head moves).
        if (addr == (uint8_t)PERI_R_SIO_IN) {
            return peri_sio_handle_sio_in_read();
        }
        // Reads of STATUS clear the IRQ source (per peri_link.sv
        // "IRQ" header — software polls STATUS to ack peri-RP IRQs).
        uint8_t value = g_regs[addr];
        if (addr == (uint8_t)PERI_R_STATUS && value != 0u) {
            g_regs[addr] = 0u;
            peri_irq_update();        // STATUS = 0 → release IRQ_OUT
        }
        return value;
    }
    // Writes
    g_regs[addr] = wdata;
    // Side-effect hooks
    if (addr == (uint8_t)PERI_W_CMD) {
        peri_pot_handle_cmd(wdata);
        // M25-4: SIO_TX may also land via CMD = SIO_TX in future
        // protocol commands.
    }
    if (addr == (uint8_t)PERI_W_SIO_OUT) {
        peri_sio_handle_sio_out_write(wdata);
    }
    return 0;
}
