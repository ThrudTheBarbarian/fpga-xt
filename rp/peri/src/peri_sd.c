// peri_sd.c — SD card driver scaffold (M25-5).

#include "peri_sd.h"

#include <string.h>

#include "peri_regs.h"
#include "peri_irq.h"

static peri_sd_state_t g_state;
static bool            g_block_done_pending;

// Queued request — only one in flight at a time. Production firmware:
// PIO/hardware SPI ISR drives the actual byte transfer; this layer
// just bookkeeps the request shape.
static bool     g_request_active;
static bool     g_request_is_write;
static uint32_t g_request_lba;
static uint8_t *g_request_dst;
static const uint8_t *g_request_src;

static void set_sd_done(bool done) {
    uint8_t status = peri_regs_get(PERI_R_STATUS);
    if (done) {
        peri_regs_set(PERI_R_STATUS, status | PERI_STATUS_SD_DONE);
    } else {
        peri_regs_set(PERI_R_STATUS, status & (uint8_t)~PERI_STATUS_SD_DONE);
    }
    peri_irq_update();
}

void peri_sd_init(void) {
    g_state              = PERI_SD_UNINIT;
    g_block_done_pending = false;
    g_request_active     = false;
    g_request_is_write   = false;
    g_request_lba        = 0;
    g_request_dst        = NULL;
    g_request_src        = NULL;
    set_sd_done(false);
}

bool peri_sd_service(void) {
    bool changed = false;
    // PERI_SD_UNINIT → kick INITIALISING. Production: enqueue CMD0;
    // host sim: peri_sd_inject_init_ok() flips us to READY.
    if (g_state == PERI_SD_UNINIT) {
        g_state = PERI_SD_INITIALISING;
        changed = true;
    }
    if (g_block_done_pending) {
        g_block_done_pending = false;
        g_request_active     = false;
        g_state              = PERI_SD_READY;
        set_sd_done(true);
        changed              = true;
    }
    return changed;
}

bool peri_sd_read_block(uint32_t block_lba, uint8_t *dst) {
    if (g_state != PERI_SD_READY) return false;
    if (g_request_active)         return false;
    g_request_active   = true;
    g_request_is_write = false;
    g_request_lba      = block_lba;
    g_request_dst      = dst;
    g_state            = PERI_SD_BUSY;
    return true;
}

bool peri_sd_write_block(uint32_t block_lba, const uint8_t *src) {
    if (g_state != PERI_SD_READY) return false;
    if (g_request_active)         return false;
    g_request_active   = true;
    g_request_is_write = true;
    g_request_lba      = block_lba;
    g_request_src      = src;
    g_state            = PERI_SD_BUSY;
    return true;
}

#ifdef PERI_POT_HOST_SIM
peri_sd_state_t peri_sd_state(void) { return g_state; }

void peri_sd_inject_init_ok(void) {
    if (g_state == PERI_SD_INITIALISING) g_state = PERI_SD_READY;
}
void peri_sd_inject_init_err(void) {
    g_state = PERI_SD_ERROR;
}
void peri_sd_inject_block_done(void) {
    if (g_state == PERI_SD_BUSY) g_block_done_pending = true;
}
#endif
