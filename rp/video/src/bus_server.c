// bus_server.c — production FETCH / SET / DRAW drain (M21).
//
// Boots the bus PIO state machines, claims SMs on pio0, configures
// pin directions, launches a drain loop on core 1 that pulls beats
// from the RX FIFO and dispatches by tag:
//
//   FETCH  → look up FB[addr..addr+1], push 16-bit response on TX SM
//   SET    → 2-beat sequence: latch addr, then write 2 FB bytes
//   DRAW   → forward to draw_beat() (rp/src/draw.c) which gathers
//            the per-opcode beat sequence and renders into the FB
//   NOP    → idle; resets any half-formed SET state
//
// The dispatch logic mirrors the host C model at rp/sim/tb_bus_pio.c —
// any bug found there or here gets reproduced on the other side, so
// the host test stays the development oracle.
//
// Framebuffer is currently in BSS (256 KB stub). Production board
// builds will move this to external PSRAM via the RP2354's QMI
// memory-mapped path; that's a board-file change, not a logic change.
//
// Wire format: ../../docs/wire-protocol.md § "FPGA<->RP bus".

#include "bus_server.h"
#include "draw.h"
#include "pinmap.h"

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/pio.h"
#include "hardware/gpio.h"

#include "bus.pio.h"   // generated from src/bus.pio by pico_generate_pio_header

#include <stdint.h>
#include <string.h>

volatile bus_server_stats_t bus_server_stats = {0};

// ---- Framebuffer (M3 stub, retained at M21) -------------------------------
// 256 KB upper-bound — covers the largest documented mode (800×200 fullres
// = 160 KB or 640×400 fullres = 256 KB). Production move to PSRAM is a
// board-file decision; the dispatch logic doesn't care where this lives.
static uint8_t framebuffer[FB_BYTES] __attribute__((aligned(4)));

// ---- Default FB geometry --------------------------------------------------
// 640×240 = ANTIC-compat line-doubled 640×480 source. The draw module
// uses these as the clip rectangle for primitive rendering. A future
// chiplet-extension write can update them at runtime if `OUTPUT_MODE`
// flips between resolution profiles.
#define FB_WIDTH  640u
#define FB_HEIGHT 240u

// ---- Draw dispatcher state ------------------------------------------------
static draw_ctx_t draw_ctx;

// ---- PIO assignments ------------------------------------------------------
// Both bus state machines fit on pio0: SM0 for RX (FPGA → RP), SM1 for TX
// (RP → FPGA responses). pio1 is free for future use (audio I2S, status
// blink, peripheral SPI).
#define BUS_PIO       pio0
#define BUS_RX_SM     0
#define BUS_TX_SM     1

// ---- SET 2-beat assembly state -------------------------------------------
// SET sequences are a SET-tagged address beat followed by a SET-tagged data
// beat. Anything that breaks the pair (NOP / FETCH / DRAW between them, or
// reset) clears the half-state — the contract from wire-protocol.md says
// the FPGA pads with NOP rather than splitting a SET, so this should never
// fire in practice; the clear is belt-and-braces.
static uint32_t set_addr_pending;
static uint32_t set_addr;

// ---- PIO initialisation --------------------------------------------------
static void bus_rx_init(void) {
    // Configure GPIO 0..26 as PIO-controlled inputs (24 payload + 2 tag + 1 clk).
    for (uint i = BUS_RX_PAYLOAD_BASE; i <= BUS_RX_CLK; i++) {
        pio_gpio_init(BUS_PIO, i);
    }
    pio_sm_set_consecutive_pindirs(BUS_PIO, BUS_RX_SM,
                                   BUS_RX_PAYLOAD_BASE,
                                   (BUS_RX_CLK - BUS_RX_PAYLOAD_BASE + 1),
                                   /*is_out=*/false);

    const uint offset = pio_add_program(BUS_PIO, &bus_rx_skel_program);
    pio_sm_config c = bus_rx_skel_program_get_default_config(offset);
    // IN pins start at GPIO 0; we read 26 bits (24 payload + 2 tag) per beat.
    sm_config_set_in_pins(&c, BUS_RX_PAYLOAD_BASE);
    // Shift right (LSB-first), no autopush — the program issues an explicit
    // `push` when the 26-bit beat is assembled.
    sm_config_set_in_shift(&c, /*shift_right=*/true,
                            /*autopush=*/false,
                            /*push_threshold=*/26);
    pio_sm_init(BUS_PIO, BUS_RX_SM, offset, &c);
    pio_sm_set_enabled(BUS_PIO, BUS_RX_SM, true);
}

static void bus_tx_init(void) {
    // Configure GPIO 27..43 as PIO-controlled outputs (16 payload + 1 clk).
    for (uint i = BUS_TX_PAYLOAD_BASE; i <= BUS_TX_CLK; i++) {
        pio_gpio_init(BUS_PIO, i);
    }
    pio_sm_set_consecutive_pindirs(BUS_PIO, BUS_TX_SM,
                                   BUS_TX_PAYLOAD_BASE,
                                   BUS_TX_PAYLOAD_COUNT,
                                   /*is_out=*/true);
    pio_sm_set_consecutive_pindirs(BUS_PIO, BUS_TX_SM,
                                   BUS_TX_CLK, 1, /*is_out=*/true);

    const uint offset = pio_add_program(BUS_PIO, &bus_tx_skel_program);
    pio_sm_config c = bus_tx_skel_program_get_default_config(offset);
    sm_config_set_out_pins(&c, BUS_TX_PAYLOAD_BASE, BUS_TX_PAYLOAD_COUNT);
    sm_config_set_set_pins(&c, BUS_TX_CLK, 1);
    sm_config_set_out_shift(&c, /*shift_right=*/true,
                             /*autopull=*/true,
                             /*pull_threshold=*/16);
    pio_sm_init(BUS_PIO, BUS_TX_SM, offset, &c);
    pio_sm_set_enabled(BUS_PIO, BUS_TX_SM, true);
}

// ---- Drain loop (core 1) -------------------------------------------------
// Blocks on the RX FIFO; wakes per beat. Dispatch is a single switch on
// the 2-bit tag, with state flowing through the file-static SET assembly
// vars and the global `bus_server_stats` / `draw_ctx`.
static void __attribute__((noreturn)) bus_drain_loop(void) {
    while (true) {
        const uint32_t word    = pio_sm_get_blocking(BUS_PIO, BUS_RX_SM);
        const uint8_t  tag     = (uint8_t)((word >> 24) & 0x3u);
        const uint32_t payload = word & 0xFFFFFFu;

        switch (tag) {
            case BUS_TAG_NOP:
                set_addr_pending = 0;
                break;

            case BUS_TAG_FETCH: {
                const uint32_t a = payload;
                uint16_t r = 0;
                if (a + 1u < FB_BYTES) {
                    r = (uint16_t)framebuffer[a]
                      | ((uint16_t)framebuffer[a + 1u] << 8);
                }
                pio_sm_put_blocking(BUS_PIO, BUS_TX_SM, r);
                bus_server_stats.fetch_count++;
                set_addr_pending = 0;
                break;
            }

            case BUS_TAG_SET:
                if (!set_addr_pending) {
                    set_addr_pending = 1;
                    set_addr         = payload;
                    if (payload & 1u) bus_server_stats.set_misalign_count++;
                } else {
                    if (set_addr + 1u < FB_BYTES) {
                        framebuffer[set_addr]      = (uint8_t)(payload & 0xFFu);
                        framebuffer[set_addr + 1u] = (uint8_t)((payload >> 8) & 0xFFu);
                    }
                    bus_server_stats.set_count++;
                    set_addr_pending = 0;
                }
                break;

            case BUS_TAG_DRAW:
                draw_beat(&draw_ctx, payload);
                bus_server_stats.draw_count++;
                set_addr_pending = 0;
                break;

            default:
                bus_server_stats.bad_tag_count++;
                set_addr_pending = 0;
                break;
        }
    }
}

// ---- Public entry point --------------------------------------------------
void bus_server_start(void) {
    // Deterministic FB pattern at boot — first scan-out shows something
    // recognisable rather than uninitialised PSRAM.
    for (uint32_t i = 0; i < FB_BYTES; i++) {
        framebuffer[i] = (uint8_t)(i & 0xFFu);
    }

    // Initialise the draw dispatcher with the FB geometry.
    draw_init(&draw_ctx, framebuffer, FB_WIDTH, FB_HEIGHT);

    // Claim + configure PIO state machines.
    pio_sm_claim(BUS_PIO, BUS_RX_SM);
    pio_sm_claim(BUS_PIO, BUS_TX_SM);
    bus_rx_init();
    bus_tx_init();

    // Hand the drain loop to core 1; core 0 returns to main() for
    // diagnostics + USB CDC heartbeat.
    multicore_launch_core1(bus_drain_loop);
}
