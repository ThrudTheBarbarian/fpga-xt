#pragma once

// Pin map for rp_antic_video.
//
// Two source-synchronous unidirectional buses connect the FPGA and
// the RP2354 (see ../../docs/wire-protocol.md § "FPGA<->RP bus"):
//
//   FPGA -> RP : 24 payload + 2 tag + 1 clk = 27 wires
//   RP   -> FPGA : 16 payload + 1 clk = 17 wires
//
// All payload + tag wires within each bus must be CONTIGUOUS so a
// single PIO state machine can OUT/IN the full word in one instruction.
//
// Dev-rig assignments (Adafruit Feather RP2350) below; production
// assignments land later when the custom RP2354 board is laid out.

// ---- FPGA -> RP (input to RP; PIO RX side) ---------------------------
// 27 contiguous GPIO numbers. The RP2354's PIO can OUT_PINS up to
// 32 contiguous, so 26 (24 payload + 2 tag) on a single SM works
// directly. The clk pin sits on its own GPIO triggering wait-on-pin.
#define BUS_RX_PAYLOAD_BASE   0u   // GPIO 0..23 = payload[23:0]
#define BUS_RX_PAYLOAD_COUNT  24
#define BUS_RX_TAG_BASE       24u  // GPIO 24..25 = tag[1:0]
#define BUS_RX_TAG_COUNT      2
#define BUS_RX_CLK            26u  // GPIO 26 = bus_rx_clk (FPGA-driven)

// ---- RP -> FPGA (output from RP; PIO TX side) ------------------------
// 17 GPIOs. 16 contiguous for payload + 1 for the RP-driven clock.
#define BUS_TX_PAYLOAD_BASE   27u  // GPIO 27..42 = payload[15:0]
#define BUS_TX_PAYLOAD_COUNT  16
#define BUS_TX_CLK            43u  // GPIO 43 = bus_tx_clk (RP-driven)

// ---- Spare control wires ---------------------------------------------
// 4 spare GPIOs (44..47) on the 48-pin variant. Provisional uses:
#define BUS_DRAW_FULL         44u  // RP -> FPGA. asserted when DRAW queue full
#define BUS_RESET_REQ         45u  // FPGA -> RP. soft-reset request
#define BUS_DIAG_TX           46u  // RP -> FPGA. low-rate diagnostic UART tx
#define BUS_DIAG_RX           47u  // FPGA -> RP. low-rate diagnostic UART rx

// ---- Feather-only ----------------------------------------------------
#define FEATHER_NEOPIXEL_PIN  21u  // not used in production; turned off at boot
