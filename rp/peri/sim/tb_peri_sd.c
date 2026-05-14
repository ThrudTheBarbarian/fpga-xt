// tb_peri_sd.c — host-side scaffolding test for the peri-RP SD
// driver state machine.
//
// Coverage:
//   A — init flow: UNINIT → INITIALISING → READY (via injected OK)
//   B — block read: READY → BUSY → READY on injected done +
//                   STATUS.sd_done set
//   C — request rejection: cannot enqueue while BUSY
//   D — init error: INITIALISING → ERROR

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "peri_regs.h"
#include "peri_pot.h"
#include "peri_sio.h"
#include "peri_irq.h"
#include "peri_sd.h"

static int fail_count = 0;

#define EXPECT_EQ(label, got, want) do {                                  \
    unsigned _g = (unsigned)(got);                                         \
    unsigned _w = (unsigned)(want);                                        \
    if (_g != _w) {                                                        \
        fprintf(stderr, "FAIL %s: got=$%02x expected=$%02x\n",             \
                (label), _g, _w);                                          \
        fail_count++;                                                      \
    }                                                                      \
} while (0)

#define EXPECT_TRUE(label, cond) do {                                      \
    if (!(cond)) {                                                         \
        fprintf(stderr, "FAIL %s: condition false\n", (label));            \
        fail_count++;                                                      \
    }                                                                      \
} while (0)

int main(void) {
    printf("=== M25-5 peri_sd ===\n");

    peri_regs_init();
    peri_pot_init();
    peri_sio_init();
    peri_irq_init();
    peri_sd_init();

    // ----- A — init flow ----------------------------------------
    printf("[A] init flow\n");
    EXPECT_EQ("A.state.uninit",       peri_sd_state(), PERI_SD_UNINIT);
    (void)peri_sd_service();
    EXPECT_EQ("A.state.initialising", peri_sd_state(), PERI_SD_INITIALISING);
    peri_sd_inject_init_ok();
    EXPECT_EQ("A.state.ready",        peri_sd_state(), PERI_SD_READY);

    // ----- B — block read -> done -------------------------------
    printf("[B] block read\n");
    {
        uint8_t scratch[PERI_SD_BLOCK_BYTES];
        EXPECT_TRUE("B.read.kick", peri_sd_read_block(42, scratch));
        EXPECT_EQ("B.state.busy", peri_sd_state(), PERI_SD_BUSY);
        peri_sd_inject_block_done();
        (void)peri_sd_service();
        EXPECT_EQ("B.state.ready.again", peri_sd_state(), PERI_SD_READY);
        EXPECT_EQ("B.STATUS.sd_done",
                  peri_regs_get(PERI_R_STATUS) & PERI_STATUS_SD_DONE,
                  PERI_STATUS_SD_DONE);
        EXPECT_EQ("B.IRQ.asserted", peri_irq_host_pin_level(), 0);
        // SPI read of STATUS clears + releases IRQ.
        EXPECT_EQ("B.STATUS.read.flag",
                  peri_regs_handle(PERI_R_STATUS, true, 0) & PERI_STATUS_SD_DONE,
                  PERI_STATUS_SD_DONE);
        EXPECT_EQ("B.IRQ.released", peri_irq_host_pin_level(), 1);
    }

    // ----- C — request rejection while BUSY ---------------------
    printf("[C] request rejection while BUSY\n");
    {
        uint8_t scratch[PERI_SD_BLOCK_BYTES];
        EXPECT_TRUE("C.read.kick.first", peri_sd_read_block(99, scratch));
        EXPECT_TRUE("C.read.reject.busy", !peri_sd_read_block(100, scratch));
        EXPECT_TRUE("C.write.reject.busy", !peri_sd_write_block(101, scratch));
        // Drain
        peri_sd_inject_block_done();
        (void)peri_sd_service();
    }

    // ----- D — init error ---------------------------------------
    printf("[D] init error\n");
    peri_sd_init();
    (void)peri_sd_service();        // → INITIALISING
    peri_sd_inject_init_err();
    EXPECT_EQ("D.state.error", peri_sd_state(), PERI_SD_ERROR);
    {
        uint8_t scratch[PERI_SD_BLOCK_BYTES];
        EXPECT_TRUE("D.read.reject.error", !peri_sd_read_block(0, scratch));
    }

    if (fail_count == 0) {
        printf("*** PERI_SD OK *** all checks passed\n");
        return 0;
    }
    fprintf(stderr, "*** PERI_SD FAIL *** %d failures\n", fail_count);
    return 1;
}
