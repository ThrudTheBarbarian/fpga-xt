// tb_peri_pot.c — host-side test for the peri-RP POT scanner glue.
//
// Skips the PIO program (only validatable on hardware) and
// exercises the C state machine + peri_regs side-effects:
//
//   - Writing CMD = $01 (POTGO_SLOW) kicks the scanner with
//     fast_scan = false.
//   - Writing CMD = $11 (POTGO_FAST) kicks with fast_scan = true.
//   - The bridge contract requires ALLPOT to read $FF immediately
//     after POTGO (every channel "scanning"); confirm that.
//   - Injecting a fake "scan done" event commits the per-channel
//     counts + ALLPOT mask into peri_regs.
//   - STATUS.pot_done is set on completion; reading STATUS clears
//     it (peri_link.sv "IRQ" contract).

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "peri_regs.h"
#include "peri_pot.h"
#include "peri_irq.h"

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
    printf("=== M25-3c peri_pot ===\n");

    peri_regs_init();
    peri_pot_init();
    peri_irq_init();
    EXPECT_EQ("init.IRQ.released", peri_irq_host_pin_level(), 1);

    // ----- A — slow-scan POTGO ------------------------------------
    printf("[A] slow-scan POTGO\n");
    EXPECT_EQ("A.state.idle.pre", peri_pot_state(), PERI_POT_IDLE);
    (void)peri_regs_handle(PERI_W_CMD, /*is_read*/false, 0x01u);
    EXPECT_EQ("A.state.running",   peri_pot_state(), PERI_POT_RUNNING);
    EXPECT_TRUE("A.fast_scan_false", !peri_pot_last_kick_was_fast());
    // Per the FPGA-side contract: writing POTGO sets ALLPOT to
    // all-1s immediately so the bridge's read of ALLPOT during the
    // scan window reports "every channel scanning".
    EXPECT_EQ("A.ALLPOT.during",   peri_regs_get(PERI_R_ALLPOT), 0xFFu);
    EXPECT_EQ("A.STATUS.during",   peri_regs_get(PERI_R_STATUS), 0x00u);

    // Inject "scan done" with per-channel counts.
    {
        uint8_t counts[8] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};
        peri_pot_inject_done(counts, /*allpot=*/0x00u);
    }
    EXPECT_TRUE("A.service.committed", peri_pot_service());
    EXPECT_EQ("A.state.idle.post", peri_pot_state(), PERI_POT_IDLE);
    // pot_done flag set → IRQ_OUT pulled low.
    EXPECT_EQ("A.IRQ.asserted",   peri_irq_host_pin_level(), 0);
    EXPECT_EQ("A.POT0", peri_regs_get(PERI_R_POT0 + 0), 0x11u);
    EXPECT_EQ("A.POT1", peri_regs_get(PERI_R_POT0 + 1), 0x22u);
    EXPECT_EQ("A.POT7", peri_regs_get(PERI_R_POT0 + 7), 0x88u);
    EXPECT_EQ("A.ALLPOT.done", peri_regs_get(PERI_R_ALLPOT), 0x00u);

    // STATUS.pot_done was set; reading STATUS via the SPI handle
    // path clears it (IRQ-ack semantics) and releases IRQ_OUT.
    EXPECT_EQ("A.STATUS.flag",
              peri_regs_handle(PERI_R_STATUS, /*is_read*/true, 0),
              PERI_STATUS_POT_DONE);
    EXPECT_EQ("A.STATUS.cleared.after.read",
              peri_regs_get(PERI_R_STATUS), 0x00u);
    EXPECT_EQ("A.IRQ.released.after.read",
              peri_irq_host_pin_level(), 1);

    // ----- B — fast-scan POTGO ------------------------------------
    printf("[B] fast-scan POTGO\n");
    (void)peri_regs_handle(PERI_W_CMD, false, 0x11u);
    EXPECT_EQ("B.state.running",     peri_pot_state(), PERI_POT_RUNNING);
    EXPECT_TRUE("B.fast_scan_true",  peri_pot_last_kick_was_fast());

    {
        uint8_t counts[8] = {0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x10, 0x20};
        peri_pot_inject_done(counts, /*allpot=*/0x0Fu);
    }
    EXPECT_TRUE("B.service.committed", peri_pot_service());
    EXPECT_EQ("B.POT0",        peri_regs_get(PERI_R_POT0), 0xAAu);
    EXPECT_EQ("B.ALLPOT.partial", peri_regs_get(PERI_R_ALLPOT), 0x0Fu);

    // Drain STATUS again
    (void)peri_regs_handle(PERI_R_STATUS, true, 0);

    // ----- C — non-POTGO command bytes ignored --------------------
    printf("[C] non-POTGO CMD ignored\n");
    EXPECT_EQ("C.state.idle.pre", peri_pot_state(), PERI_POT_IDLE);
    (void)peri_regs_handle(PERI_W_CMD, false, 0x02u);   // SIO_TX = $02
    EXPECT_EQ("C.state.idle.post", peri_pot_state(), PERI_POT_IDLE);
    (void)peri_regs_handle(PERI_W_CMD, false, 0x55u);   // unknown
    EXPECT_EQ("C.state.idle.unk",  peri_pot_state(), PERI_POT_IDLE);

    // ----- D — service is no-op when not in LATCHING -------------
    printf("[D] service idle no-op\n");
    EXPECT_TRUE("D.service.idle_returns_false", !peri_pot_service());
    // Trigger a scan but don't inject done — service should still
    // be a no-op.
    (void)peri_regs_handle(PERI_W_CMD, false, 0x01u);
    EXPECT_TRUE("D.service.running_returns_false", !peri_pot_service());
    EXPECT_EQ("D.state.still.running", peri_pot_state(), PERI_POT_RUNNING);

    if (fail_count == 0) {
        printf("*** PERI_POT OK *** all checks passed\n");
        return 0;
    }
    fprintf(stderr, "*** PERI_POT FAIL *** %d failures\n", fail_count);
    return 1;
}
