#pragma once

// Pin map for rp_antic_peri.
//
// The peri-RP owns 4 logical pin groups, all sharing 3.3 V IOVDD:
//
//   1. SPI slave + IRQ to FPGA (4 pins) — peri_link wire format,
//      see ../../../hdl/peri_link.sv for the protocol.
//   2. Joystick PORTA + PORTB + 4 fire (20 pins) — bidirectional per
//      bit on PORTA/PORTB (XEP80, mouse, bit-banged serial).
//   3. POT 0..7 (8 pins) — open-drain bidir, peri-RP discharges via
//      drive-low + tristate to count rise time. See
//      ../../../docs/hardware-notes.md "Paddle / POT scan".
//   4. SIO + SD (added in M25-4 / M25-5).
//
// Dev-rig assignments (Adafruit Feather RP2350) below; production
// assignments land when the custom RP2354B board is laid out. We
// keep contiguous ranges so PIO state machines can OUT/IN whole
// groups in one instruction (joystick scan, POT discharge).

// ---- FPGA SPI slave + IRQ (M25-2 / M25-3) -----------------------------
// 4-pin SPI MODE 0 (CPOL=0, CPHA=0): FPGA = master, peri-RP = slave.
// /CS-delimited 8-bit frames so the PL022 hardware peripheral handles
// it without PIO. IRQ_OUT is open-drain, active-low, asserted by
// peri-RP when any input register changes.
//
// SCK / MOSI / MISO / /CS must be SPI0-capable + contiguous so the
// pinmap layout is shared by both the GPIO routing setup and the
// pico-sdk's `spi_init` helper.
#define PERI_SPI_SCK_PIN     10u   // input  — SPI clock from FPGA
#define PERI_SPI_MOSI_PIN    11u   // input  — MOSI from FPGA
#define PERI_SPI_MISO_PIN    12u   // output — MISO to FPGA
#define PERI_SPI_CSN_PIN     13u   // input  — active-low slave-select
#define PERI_IRQ_OUT_PIN     14u   // output — open-drain IRQ to FPGA

// ---- POT 0..7 (M25-3c — placeholder) ---------------------------------
// 8 open-drain bidir pins. peri-RP drives low to discharge, then
// tristates and counts cycles until the line rises through the GPIO
// input threshold (~1.65 V at 3.3 V IOVDD). Replicates POKEY's M23-5
// algorithm.
#define PERI_POT_BASE        34u   // GPIO 34..41 = POT[7:0]

// ---- SIO + SD (reserved for M25-4 / M25-5) ---------------------------
// SIO: DATAIN / DATAOUT / /COMMAND / /MOTOR / /PROCEED / /INTERRUPT /
// /READY + 2× clock = 9 pins. SD card SPI = 4 pins (CK, CMD, D0, /CS;
// 4-bit mode is M25-5+). Pin assignments TBD.
