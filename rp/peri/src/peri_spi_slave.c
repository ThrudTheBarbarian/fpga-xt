// peri-RP SPI slave servicing — PL022 hardware SPI in slave mode plus
// a tight RX-FIFO polling loop on core 1.
//
// Wire format (from ../../../hdl/peri_link.sv):
//
//   /CS-delimited pairs of 8-bit MSB-first frames, SPI MODE 0:
//     Frame 1 (cmd):  R/W(MSB) + 7-bit addr → MOSI; slave MISO ignored.
//     Frame 2 (data): write payload → MOSI; read response ← MISO.
//   Master inserts a HALF_GAP between the two /CS pulses (~32 cycles
//   ≈ 200 ns at 162 MHz) so the slave can decode the cmd byte and
//   load the read response into the PL022 TX FIFO before the data
//   half starts.
//
// The PL022 in slave mode pushes RX FIFO on /CS-rise and drains TX
// FIFO on /CS-fall. Our polling loop:
//
//   while (1) {
//     cmd = recv();           // blocks until cmd byte arrives
//     decode, fetch response;
//     send(response);         // PL022 TX FIFO; drained on next /CS-fall
//     data = recv();          // blocks until data byte arrives
//     decode, store on writes;
//   }

#include "peri_spi_slave.h"

#include "pico/stdlib.h"
#include "hardware/spi.h"
#include "hardware/gpio.h"

#include "peri_regs.h"
#include "pinmap.h"

// PL022 instance for the FPGA peri_link slave. M25-3 doesn't need the
// other SPI controller (spi1) — reserved for SD-card master in M25-5.
#define PERI_SPI spi0

void peri_spi_slave_init(void) {
    _Static_assert(PERI_SPI_MOSI_PIN == PERI_SPI_SCK_PIN + 1u,
                   "peri SPI assumes MOSI = SCK + 1");
    _Static_assert(PERI_SPI_MISO_PIN == PERI_SPI_SCK_PIN + 2u,
                   "peri SPI assumes MISO = SCK + 2");
    _Static_assert(PERI_SPI_CSN_PIN  == PERI_SPI_SCK_PIN + 3u,
                   "peri SPI assumes /CS = SCK + 3");

    // Initialise PL022 in slave mode at a baud the master never
    // reaches — slave mode ignores the rate setting beyond min/max
    // bounds, but spi_init insists on a value.
    spi_init(PERI_SPI, 1u * 1000u * 1000u);
    spi_set_slave(PERI_SPI, true);
    // 8-bit Motorola SPI MODE 0 (CPOL=0, CPHA=0 — sample on rising,
    // change on falling).
    spi_set_format(PERI_SPI, 8, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);

    // Route SCK / MOSI / MISO / /CS to the PL022.
    gpio_set_function(PERI_SPI_SCK_PIN,  GPIO_FUNC_SPI);
    gpio_set_function(PERI_SPI_MOSI_PIN, GPIO_FUNC_SPI);
    gpio_set_function(PERI_SPI_MISO_PIN, GPIO_FUNC_SPI);
    gpio_set_function(PERI_SPI_CSN_PIN,  GPIO_FUNC_SPI);
}

void peri_spi_slave_run(void) {
    for (;;) {
        // ---- Frame 1: cmd byte -----------------------------------
        // spi_read_blocking forces a TX byte too — but slave mode TX
        // FIFO is what the master sees on MISO during this half. We
        // push 0 (don't-care for the cmd half).
        uint8_t cmd_tx = 0u;
        uint8_t cmd    = 0u;
        spi_write_read_blocking(PERI_SPI, &cmd_tx, &cmd, 1);

        bool    is_read = (cmd & 0x80u) != 0u;
        uint8_t addr    = (uint8_t)(cmd & 0x7Fu);

        // Prepare the response (or a 0 placeholder for writes) and
        // load it into the PL022 TX FIFO. The master's HALF_GAP
        // (~200 ns) is plenty for this branch + MMIO write.
        uint8_t response = is_read
            ? peri_regs_handle(addr, /* is_read */ true, /* wdata */ 0)
            : 0u;

        // ---- Frame 2: data byte ----------------------------------
        // The response is shifted out on MISO during this frame; the
        // master either ignores it (write) or returns it on
        // xfer_rdata (read).
        uint8_t data = 0u;
        spi_write_read_blocking(PERI_SPI, &response, &data, 1);

        if (!is_read) {
            (void)peri_regs_handle(addr, /* is_read */ false, data);
        }
    }
}
