// peri_rp_idle.sv — SIM-ONLY behavioral model of an IDLE peripheral RP for
// tb_boot.  Models the peri-RP2354B SPI slave (frame format per peri_link.sv)
// with NO peripheral attached: no joysticks/POTs, no SIO device, no BREAK.
//
// Why this exists: tb_boot has no RP.  Leaving spi_miso undriven (or tied high)
// lets peri_bridge fabricate bogus status off the floating line — MISO=1 reads
// back STATUS=$FF, i.e. a spurious SIO_RX + BREAK every poll, which churns
// POKEY's irq and starves the OS deferred VBLANK so the editor's fine-scroll
// wait (VSFLAG) never completes.  A proper slave that answers the protocol with
// clean idle data ($00 everywhere) keeps the VBLANK and the display path honest.
//
// This is a faithful "nothing plugged in" model: every register reads $00
// (POT_DONE=0, SIO_RX=0, BREAK=0, ...).  The boot's three device-probes
// (cassette ACB / disk ADB / handler-poll PHR) are stubbed in the OS ROM by
// tb_boot, so no SIO command frame is ever sent here — the slave only ever has
// to return idle status.
//
// SPI: MODE 0 (CPOL=0, CPHA=0), MSB-first, two 8-bit /CS pulses per transaction
// (cmd byte {R/W, addr[6:0]} then data byte).  For reads the slave drives MISO
// during the data half; the master (peri_link) samples it on the rising edges.

`default_nettype none

module peri_rp_idle (
    input  wire rst,
    input  wire spi_clk,     // from peri_link master
    input  wire spi_cs_n,    // active-low frame select
    input  wire spi_mosi,
    output wire spi_miso
);
    logic [7:0] rx      = 8'h00;   // MOSI shift-in (cmd byte / write data)
    logic [7:0] tx      = 8'h00;   // MISO shift-out (read response)
    logic [7:0] cmd     = 8'h00;   // captured cmd byte {R/W, addr}
    logic       in_data = 1'b0;    // 0 = cmd half, 1 = data half

    assign spi_miso = tx[7];

    // /CS falling: begin a byte half.  For the data half of a READ, preload the
    // response so MISO presents the MSB before the first SCK rising edge
    // (CPHA=0).  Idle peripheral ⇒ every register reads $00.
    always @(negedge spi_cs_n) begin
        rx <= 8'h00;
        tx <= 8'h00;
    end

    // Sample MOSI on rising SCK; advance MISO on falling SCK (MODE 0).
    always @(posedge spi_clk)  rx <= {rx[6:0], spi_mosi};
    always @(negedge spi_clk)  tx <= {tx[6:0], 1'b0};

    // /CS rising: byte complete.  First pulse = cmd, second = data (ignored;
    // idle slave has nothing to act on).
    always @(posedge spi_cs_n or posedge rst) begin
        if (rst) begin
            cmd <= 8'h00; in_data <= 1'b0;
        end else if (!in_data) begin
            cmd     <= rx;       // captured command byte
            in_data <= 1'b1;
        end else begin
            in_data <= 1'b0;
        end
    end
endmodule

`default_nettype wire
