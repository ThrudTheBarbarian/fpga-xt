// tb_peri_sio.c — host-side test for the peri-RP SIO C state machine.
//
// PIO program is hardware-only; this exercises the queue logic + the
// register-side hooks (peri_regs_handle on SIO_OUT/SIO_IN/STATUS).
//
// Coverage:
//   A — TX path: writes to SIO_OUT push into TX queue, busy bit set.
//   B — RX path: injected bytes show up on SIO_IN reads in order;
//                STATUS.sio_rx tracks queue non-empty.
//   C — RX overrun: queue full → SIO_STAT.OVERRUN bit.
//   D — Mixed framing/break flags surface in SIO_STAT.

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "peri_regs.h"
#include "peri_pot.h"
#include "peri_sio.h"
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

int main(void) {
    printf("=== M25-4 peri_sio ===\n");

    peri_regs_init();
    peri_pot_init();
    peri_sio_init();
    peri_irq_init();

    // ----- A — TX: writes to SIO_OUT enqueue + flag busy ----------
    printf("[A] TX queue + busy flag\n");
    EXPECT_EQ("A.tx.empty.pre", peri_sio_tx_queue_len(), 0);
    (void)peri_regs_handle(PERI_W_SIO_OUT, /*is_read*/false, 0x55);
    EXPECT_EQ("A.tx.len.1",     peri_sio_tx_queue_len(), 1);
    EXPECT_EQ("A.SIO_STAT.busy",
              peri_regs_get(PERI_R_SIO_STAT) & 0x04, 0x04);
    (void)peri_regs_handle(PERI_W_SIO_OUT, false, 0xAA);
    EXPECT_EQ("A.tx.len.2",     peri_sio_tx_queue_len(), 2);
    EXPECT_EQ("A.tx.head.55",   peri_sio_tx_queue_pop(), 0x55);
    EXPECT_EQ("A.tx.head.AA",   peri_sio_tx_queue_pop(), 0xAA);
    // After draining TX, busy flag goes away on next service tick.
    (void)peri_sio_service();
    EXPECT_EQ("A.SIO_STAT.busy.cleared",
              peri_regs_get(PERI_R_SIO_STAT) & 0x04, 0x00);

    // ----- B — RX: injected bytes pop in order via SIO_IN read ----
    printf("[B] RX queue + sio_rx flag\n");
    EXPECT_EQ("B.STATUS.idle", peri_regs_get(PERI_R_STATUS) & PERI_STATUS_SIO_RX, 0);
    peri_sio_inject_rx(0xC3);
    EXPECT_EQ("B.STATUS.rx", peri_regs_get(PERI_R_STATUS) & PERI_STATUS_SIO_RX,
              PERI_STATUS_SIO_RX);
    EXPECT_EQ("B.IRQ.asserted", peri_irq_host_pin_level(), 0);
    peri_sio_inject_rx(0x42);
    peri_sio_inject_rx(0x99);
    EXPECT_EQ("B.read.C3", peri_regs_handle(PERI_R_SIO_IN, true, 0), 0xC3);
    EXPECT_EQ("B.read.42", peri_regs_handle(PERI_R_SIO_IN, true, 0), 0x42);
    EXPECT_EQ("B.read.99", peri_regs_handle(PERI_R_SIO_IN, true, 0), 0x99);
    // Queue empty → sio_rx flag cleared, IRQ released (assuming no
    // other STATUS bits set).
    EXPECT_EQ("B.STATUS.cleared",
              peri_regs_get(PERI_R_STATUS) & PERI_STATUS_SIO_RX, 0);
    EXPECT_EQ("B.IRQ.released", peri_irq_host_pin_level(), 1);

    // ----- C — RX overrun ----------------------------------------
    printf("[C] RX overrun\n");
    peri_sio_init();              // fresh state
    peri_irq_init();
    // Fill the queue (size 16, max items = 15 with single-headroom).
    for (int i = 0; i < (int)PERI_SIO_RX_QUEUE_SIZE - 1; i++) {
        peri_sio_inject_rx((uint8_t)i);
    }
    EXPECT_EQ("C.SIO_STAT.no_overrun.yet",
              peri_regs_get(PERI_R_SIO_STAT) & 0x02, 0x00);
    // One more push triggers overrun.
    peri_sio_inject_rx(0xFF);
    EXPECT_EQ("C.SIO_STAT.overrun",
              peri_regs_get(PERI_R_SIO_STAT) & 0x02, 0x02);

    // ----- D — Framing + break flags ------------------------------
    printf("[D] framing + break flags\n");
    peri_sio_init();
    peri_irq_init();
    peri_sio_inject_framing_err();
    peri_sio_inject_break();
    peri_sio_inject_rx(0x77);
    EXPECT_EQ("D.SIO_STAT.framing",
              peri_regs_get(PERI_R_SIO_STAT) & 0x01, 0x01);
    EXPECT_EQ("D.SIO_STAT.break",
              peri_regs_get(PERI_R_SIO_STAT) & 0x08, 0x08);
    EXPECT_EQ("D.byte_in_pipe",
              peri_regs_handle(PERI_R_SIO_IN, true, 0), 0x77);

    if (fail_count == 0) {
        printf("*** PERI_SIO OK *** all checks passed\n");
        return 0;
    }
    fprintf(stderr, "*** PERI_SIO FAIL *** %d failures\n", fail_count);
    return 1;
}
