// tb_peri_regs — host-side test of the peri-RP register file behind
// the SPI slave's polling loop. Exercises peri_regs_handle() with
// the same R/W + addr + data argument shape the polling loop hands
// to it.
//
// Coverage:
//   A — write-then-read round-trip on a basic address
//   B — initial reset state (everything zero now that joystick has
//       moved to the PCAL9722 — peri-RP's reset shadows are all 0)
//   C — full address-space sweep — write i, read i, expect i for all
//       128 addresses
//   D — peri_regs_set / peri_regs_get bypass (firmware-internal path)

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

#include "peri_regs.h"

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
    printf("=== M25-3a peri_regs ===\n");

    peri_regs_init();

    // ----- A — write-then-read round-trip --------------------------
    printf("[A] write/read round-trip via peri_regs_handle\n");
    (void)peri_regs_handle(PERI_W_POT_OE, /*is_read*/false, 0x5A);
    EXPECT_EQ("A.POT_OE.write+read",
              peri_regs_handle(PERI_W_POT_OE, true, 0), 0x5A);

    (void)peri_regs_handle(PERI_W_CMD, false, 0x01);
    EXPECT_EQ("A.CMD.write+read",
              peri_regs_handle(PERI_W_CMD, true, 0), 0x01);

    // ----- B — reset state -----------------------------------------
    printf("[B] reset-state — all shadows zero\n");
    peri_regs_init();
    EXPECT_EQ("B.STATUS.idle",
              peri_regs_handle(PERI_R_STATUS, true, 0), 0x00);
    EXPECT_EQ("B.ALLPOT.idle",
              peri_regs_handle(PERI_R_ALLPOT, true, 0), 0x00);
    EXPECT_EQ("B.POT0.idle",
              peri_regs_handle(PERI_R_POT0, true, 0), 0x00);

    // ----- C — full-address-space sweep ----------------------------
    // Skip addresses that have register-level side effects on read
    // or write — those are exercised in their own dedicated tests
    // (peri_pot_handle_cmd at $05, STATUS-clear-on-read at $03,
    // SIO TX/RX hooks at $06 / $0D, SIO_STAT mirror at $0E):
    //   $03 STATUS — read clears
    //   $05 CMD    — write triggers POTGO
    //   $06 SIO_OUT — write pushes TX queue + mutates STATUS/SIO_STAT
    //   $0D SIO_IN  — read pops RX queue
    //   $0E SIO_STAT — written by peri_sio service path
    printf("[C] 128-address sweep (side-effect addrs skipped)\n");
    peri_regs_init();
    for (unsigned i = 0; i < 128; i++) {
        if (i == 0x03 || i == 0x05 || i == 0x06 ||
            i == 0x0D || i == 0x0E) continue;
        uint8_t pattern = (uint8_t)(0xA5 ^ i);
        (void)peri_regs_handle((uint8_t)i, false, pattern);
    }
    for (unsigned i = 0; i < 128; i++) {
        if (i == 0x03 || i == 0x05 || i == 0x06 ||
            i == 0x0D || i == 0x0E) continue;
        uint8_t expect = (uint8_t)(0xA5 ^ i);
        char label[40];
        snprintf(label, sizeof(label), "C.sweep[%u]", i);
        EXPECT_EQ(label, peri_regs_handle((uint8_t)i, true, 0), expect);
    }

    // ----- D — peri_regs_set / peri_regs_get bypass -----------------
    // Firmware-internal updaters (POT scanner etc.) write the input
    // shadows directly, then SPI reads observe the same value.
    printf("[D] direct set/get bypass\n");
    peri_regs_init();
    peri_regs_set(PERI_R_POT0,    0x42);
    peri_regs_set(PERI_R_ALLPOT,  0xC3);
    peri_regs_set(PERI_R_STATUS,  PERI_STATUS_POT_DONE);
    EXPECT_EQ("D.POT0.set",
              peri_regs_handle(PERI_R_POT0, true, 0), 0x42);
    EXPECT_EQ("D.ALLPOT.set",
              peri_regs_handle(PERI_R_ALLPOT, true, 0), 0xC3);
    EXPECT_EQ("D.STATUS.set",
              peri_regs_handle(PERI_R_STATUS, true, 0), PERI_STATUS_POT_DONE);
    EXPECT_EQ("D.peri_regs_get",
              peri_regs_get(PERI_R_POT0), 0x42);

    if (fail_count == 0) {
        printf("*** PERI_REGS OK *** all checks passed\n");
        return 0;
    }
    fprintf(stderr, "*** PERI_REGS FAIL *** %d failures\n", fail_count);
    return 1;
}
