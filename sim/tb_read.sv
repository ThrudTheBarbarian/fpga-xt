// tb_read.sv — M2b: bus-side register-read testbench.
//
// Verifies the read mux at antic_top's D-pin boundary:
//
//   /D0xx + bus_rw=1   → bus_data_oe=1, bus_data_out from GTIA
//   /D4xx + bus_rw=1   → bus_data_oe=1, bus_data_out from ANTIC | DRAW
//   $D2xx + bus_rw=1   → bus_data_oe=1, bus_data_out from POKEY-L (bit4=0)
//                                        or POKEY-R (bit4=1)
//   anything + bus_rw=0 → bus_data_oe=0
//
// Reads register-state values that have clean defaults / known
// reset behaviour (GTIA PAL_SENSE / CONSOL_R, ANTIC NMIST, POKEY
// ALLPOT) so the mux verification doesn't depend on running-state
// timing (vcount etc.).

`default_nettype none
`timescale 1ns / 1ps

module tb_read;

    logic clk_bus = 1'b0;
    logic clk_pix = 1'b0;
    always #23.256 clk_bus = ~clk_bus;
    always #19.860 clk_pix = ~clk_pix;

    logic        rst_n       = 1'b0;
    logic [15:0] bus_addr    = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw      = 1'b1;        // idle = read
    logic        d0xx_n      = 1'b1;
    logic        d4xx_n      = 1'b1;

    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;

    antic_top u_dut (
        .clk_bus                  (clk_bus),
        .clk_pix                  (clk_pix),
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
        .spi_clk                  (),
        .spi_mosi                 (),
        .spi_miso                 (1'b1),
        .spi_cs_n                 (),
        .spi_irq                  (1'b1),
        .joy_spi_clk              (),
        .joy_spi_mosi             (),
        .joy_spi_miso             (1'b1),
        .joy_spi_cs_n             (),
        .joy_spi_int_n            (1'b1),
        .diag_wsync_overdue_count (diag_wsync_overdue_count)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input logic [7:0] got, input logic [7:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%02x expected=$%02x", label, got, want);
            fail_count++;
        end
    endtask

    task automatic expect_oe(input string label,
                             input logic got, input logic want);
        if (got !== want) begin
            $display("FAIL %s.oe: got=%0b expected=%0b", label, got, want);
            fail_count++;
        end
    endtask

    // ---- Bus-cycle tasks -----------------------------------------
    // do_read_d0xx / d4xx / d2xx / sysmem each issue a 1-cycle bus
    // read with the right page-select + bus_rw=1 and capture
    // bus_data_oe + bus_data_out at the active edge.

    task automatic do_read_d0xx(input logic [7:0] addr_lo,
                                 output logic [7:0] data,
                                 output logic       oe);
        @(negedge clk_bus);
        bus_addr = {8'hD0, addr_lo};
        bus_rw   = 1'b1;
        d0xx_n   = 1'b0;
        d4xx_n   = 1'b1;
        @(posedge clk_bus);
        #1;
        data = bus_data_out;
        oe   = bus_data_oe;
        @(negedge clk_bus);
        bus_addr = 16'h0000;
        d0xx_n   = 1'b1;
    endtask

    task automatic do_read_d2xx(input logic [7:0] addr_lo,
                                 output logic [7:0] data,
                                 output logic       oe);
        @(negedge clk_bus);
        bus_addr = {8'hD2, addr_lo};
        bus_rw   = 1'b1;
        d0xx_n   = 1'b1;
        d4xx_n   = 1'b1;
        @(posedge clk_bus);
        #1;
        data = bus_data_out;
        oe   = bus_data_oe;
        @(negedge clk_bus);
        bus_addr = 16'h0000;
    endtask

    task automatic do_read_d4xx(input logic [7:0] addr_lo,
                                 output logic [7:0] data,
                                 output logic       oe);
        @(negedge clk_bus);
        bus_addr = {8'hD4, addr_lo};
        bus_rw   = 1'b1;
        d0xx_n   = 1'b1;
        d4xx_n   = 1'b0;
        @(posedge clk_bus);
        #1;
        data = bus_data_out;
        oe   = bus_data_oe;
        @(negedge clk_bus);
        bus_addr = 16'h0000;
        d4xx_n   = 1'b1;
    endtask

    task automatic do_write_d4xx(input logic [7:0] addr_lo,
                                  input logic [7:0] data,
                                  output logic      oe);
        @(negedge clk_bus);
        bus_addr    = {8'hD4, addr_lo};
        bus_data_in = data;
        bus_rw      = 1'b0;
        d0xx_n      = 1'b1;
        d4xx_n      = 1'b0;
        @(posedge clk_bus);
        #1;
        oe = bus_data_oe;
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
        d4xx_n      = 1'b1;
    endtask

    // PIA at $D3xx has no page-select pin (like POKEY) — decode off addr.
    task automatic do_read_d3xx(input logic [7:0] addr_lo,
                                 output logic [7:0] data,
                                 output logic       oe);
        @(negedge clk_bus);
        bus_addr = {8'hD3, addr_lo};
        bus_rw   = 1'b1;
        d0xx_n   = 1'b1;
        d4xx_n   = 1'b1;
        @(posedge clk_bus);
        #1;
        data = bus_data_out;
        oe   = bus_data_oe;
        @(negedge clk_bus);
        bus_addr = 16'h0000;
    endtask

    task automatic do_write_d3xx(input logic [7:0] addr_lo,
                                  input logic [7:0] wdata);
        @(negedge clk_bus);
        bus_addr    = {8'hD3, addr_lo};
        bus_data_in = wdata;
        bus_rw      = 1'b0;
        d0xx_n      = 1'b1;
        d4xx_n      = 1'b1;
        @(posedge clk_bus);
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
    endtask

    logic [7:0] data;
    logic       oe;

    initial begin
        $display("[read] start");
        repeat (8) @(posedge clk_bus);
        rst_n = 1'b1;
        repeat (8) @(posedge clk_bus);

        // ===== A — /D0xx read: GTIA PAL_SENSE / CONSOL_R defaults =====
        $display("[A] /D0xx GTIA reads");
        do_read_d0xx(8'h14, data, oe);
        expect_oe("A.PAL_SENSE.oe",  oe,   1'b1);
        // antic_top hardcodes pal_sense_in = 8'h02 (NTSC).
        expect_eq("A.PAL_SENSE.val", data, 8'h02);

        do_read_d0xx(8'h1F, data, oe);
        expect_oe("A.CONSOL_R.oe",   oe,   1'b1);
        // antic_top hardcodes consol_r_in = 8'h07 (no console keys).
        expect_eq("A.CONSOL_R.val",  data, 8'h07);

        // ===== B — /D4xx read: ANTIC NMIST default =====
        $display("[B] /D4xx ANTIC reads");
        do_read_d4xx(8'h0F, data, oe);
        expect_oe("B.NMIST.oe",       oe,   1'b1);
        // NMIST resets to 0; bit 7 sets on DLI fire, bit 6 on VBI.
        // No NMI events have fired yet (still in vblank prologue),
        // so we just confirm the upper-bit decode bits are 0.
        if ((data & 8'hC0) !== 8'h00) begin
            $display("FAIL B.NMIST.upper_bits: got=$%02x expected upper-2-bits=0", data);
            fail_count++;
        end

        // ===== C — $D2xx read: POKEY-L ALLPOT default =====
        $display("[C] $D2xx POKEY reads");
        do_read_d2xx(8'h08, data, oe);
        expect_oe("C.ALLPOT.oe",      oe,   1'b1);
        // ALLPOT idle = 0 (no scan in flight after reset).
        expect_eq("C.ALLPOT.val",     data, 8'h00);

        // POKEY-R at addr[4]=1 (e.g. $D210+8 = $D218). Same idle ALLPOT.
        do_read_d2xx(8'h18, data, oe);
        expect_oe("C.ALLPOT_R.oe",    oe,   1'b1);
        expect_eq("C.ALLPOT_R.val",   data, 8'h00);

        // ===== D — read with no page-select → oe=0 =====
        $display("[D] non-paged-select read leaves bus_data_oe low");
        @(negedge clk_bus);
        bus_addr = 16'h1234;
        bus_rw   = 1'b1;
        d0xx_n   = 1'b1;
        d4xx_n   = 1'b1;
        @(posedge clk_bus);
        #1;
        expect_oe("D.sysmem_read.oe", bus_data_oe, 1'b0);

        // ===== E — write cycle leaves bus_data_oe low =====
        $display("[E] /D4xx write does not assert bus_data_oe");
        do_write_d4xx(8'h00, 8'h22, oe);    // DMACTL = $22
        expect_oe("E.D4xx_write.oe", oe, 1'b0);

        // ===== F — $D3xx read: PIA (boot blocker #3) =====
        // Before this fix PIA was absent from the bus read mux (oe stayed
        // low on $D3xx).  F.1 proves the mux now selects PIA; F.2/F.3
        // write a DDR latch (PACTL[2]/PBCTL[2]=0 at reset → DDR mode)
        // then read it back to prove the data path.
        $display("[F] $D3xx PIA reads");
        do_read_d3xx (8'h02, data, oe);          // PACTL = $00 at reset
        expect_oe("F.1 PACTL.oe",  oe,   1'b1);
        expect_eq("F.1 PACTL.val", data, 8'h00);

        do_write_d3xx(8'h00, 8'hA5);             // PORTA DDR <- $A5
        do_read_d3xx (8'h00, data, oe);
        expect_oe("F.2 PORTA.oe",  oe,   1'b1);
        expect_eq("F.2 PORTA.val", data, 8'hA5);

        do_write_d3xx(8'h01, 8'h5A);             // PORTB DDR <- $5A
        do_read_d3xx (8'h01, data, oe);
        expect_oe("F.3 PORTB.oe",  oe,   1'b1);
        expect_eq("F.3 PORTB.val", data, 8'h5A);

        if (fail_count == 0) begin
            $display("*** READ OK *** all checks passed");
            $finish;
        end else begin
            $display("*** READ FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_read watchdog");
        $fatal(1);
    end

endmodule
