// tb_smoke.sv — M0 smoke test.
//
// Instantiates antic_top, holds /G_RST low for several bus_clk cycles,
// releases reset, runs for 1 ms simulated, prints SMOKE OK.
//
// No checks beyond "did anything blow up?" — this is the bring-up
// scaffold.

`default_nettype none
`timescale 1ns / 1ps

module tb_smoke;

    // Clock: 21.5 MHz bus_clk (12× NTSC baseline).  clk_pix dropped —
    // task-0013 step 3 removed antic_top's 800×600 display chain.
    logic clk_bus = 1'b0;
    always #23.256 clk_bus = ~clk_bus;   // ~21.5 MHz: half-period 23.256 ns

    // Bus inputs.
    logic        rst_n      = 1'b0;
    logic [15:0] bus_addr   = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw     = 1'b1;
    logic        d0xx_n     = 1'b1;
    logic        d4xx_n     = 1'b1;

    // DUT outputs.
    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;

    antic_top u_dut (
        .clk_bus                  (clk_bus),
        .rst_n                    (rst_n),
        .bus_addr                 (bus_addr),
        .bus_data_in              (bus_data_in),
        .bus_rw                   (bus_rw),
        .d0xx_n                   (d0xx_n),
        .d4xx_n                   (d4xx_n),
        .bus_data_out             (bus_data_out),
        .bus_data_oe              (bus_data_oe),
        .nmi_n                    (nmi_n),
        .halt_n                   (halt_n),
        .rdy_n                    (rdy_n),
        // M25-3c: pot_oe/pot_in moved off antic_top — peri_pot_bridge
        // drives the peri-RP SPI link instead.
        // M25-2c: joystick / fire / SD / SIO bridged via SPI. No slave
        // attached for tb_smoke — peri_bridge will spin reads/writes
        // into the void; MISO floats high (idle pull-up).
        .spi_clk                  (),
        .spi_mosi                 (),
        .spi_miso                 (1'b1),
        .spi_cs_n                 (),
        .spi_irq                  (1'b1),        // active-low: deasserted
        // Joystick PCAL9722 SPI link (M25-2c-rev). No slave attached
        // for tb_smoke — joy_bridge's poll loop spins reads/writes
        // into the void; MISO floats high.
        .joy_spi_clk              (),
        .joy_spi_mosi             (),
        .joy_spi_miso             (1'b1),
        .joy_spi_cs_n             (),
        .joy_spi_int_n            (1'b1),
        .dma_addr_o               (),
        .dma_rw_o                 (),
        .dma_oe                   (),
        .diag_wsync_overdue_count (diag_wsync_overdue_count)
    );

    // Sanity: status pins idle high after release.
    initial begin
        $display("[smoke] start");
        repeat (10) @(posedge clk_bus);
        rst_n = 1'b1;
        $display("[smoke] reset released at t=%0t", $time);

        // Wait 1 ms, then check status.
        #1_000_000;
        if (nmi_n  !== 1'b1) begin $display("FAIL: /NMI not idle high");  $fatal(1); end
        if (halt_n !== 1'b1) begin $display("FAIL: /HALT not idle high"); $fatal(1); end
        if (rdy_n  !== 1'b1) begin $display("FAIL: /RDY not idle high");  $fatal(1); end
        if (diag_wsync_overdue_count !== 32'h0) begin
            $display("FAIL: wsync_overdue_count non-zero"); $fatal(1);
        end

        $display("*** SMOKE OK *** t=%0t", $time);
        $finish;
    end

    // Watchdog.
    initial begin
        #5_000_000;
        $display("FAIL: smoke watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
