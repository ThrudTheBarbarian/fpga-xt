// tb_pssi_int.sv — Phase 1 integration test for pssi_bytes + pssi_tx.
//
// Drives the snoop-port interface (we/waddr/wdata) that antic_top wires
// from bus_snoop, simulating a 6502 STA-to-$D49C sequence. Samples the
// PSSI output (pssi_data on rising pssi_pixclk where pssi_de=1) and
// verifies the bytes flow through pssi_bytes → pssi_tx → wire correctly.
//
// Also exercises the $D49D PSSI_STATUS register: bit 0 = overflow_q
// (sticky), W bit 0 = clear.

`timescale 1ns / 1ps
`default_nettype none

module tb_pssi_int;

    // ---- Clocks --------------------------------------------------------
    logic clk_bus  = 1'b0;
    logic clk_pssi = 1'b0;
    always #(3.03)  clk_bus  = ~clk_bus;
    always #(6.25)  clk_pssi = ~clk_pssi;

    logic rst_bus  = 1'b1;
    logic rst_pssi = 1'b1;

    // ---- Snoop-port driver --------------------------------------------
    logic        we;
    logic [7:0]  waddr;
    logic [7:0]  wdata;
    logic [7:0]  raddr;
    wire  [7:0]  rdata;

    // pssi_bytes ↔ pssi_tx wiring
    wire [7:0]  byte_to_fifo;
    wire        byte_we;
    wire        overflow_q;
    wire        overflow_clear;

    pssi_bytes u_pssi_bytes (
        .clk                 (clk_bus),
        .rst                 (rst_bus),
        .we                  (we),
        .waddr               (waddr),
        .wdata               (wdata),
        .raddr               (raddr),
        .rdata               (rdata),
        .pssi_wr_byte        (byte_to_fifo),
        .pssi_wr_we          (byte_we),
        .pssi_overflow_q     (overflow_q),
        .pssi_overflow_clear (overflow_clear)
    );

    wire        pssi_pixclk;
    wire        pssi_de;
    wire [15:0] pssi_data;

    pssi_tx #(.RING_BYTES(2048)) u_pssi_tx (
        .clk_wr            (clk_bus),
        .rst_wr            (rst_bus),
        .wr_byte           (byte_to_fifo),
        .wr_we             (byte_we),
        .wr_ready          (),
        .wr_fill_level     (),
        .wr_overflow_q     (overflow_q),
        .wr_overflow_clear (overflow_clear),
        .clk_pssi          (clk_pssi),
        .rst_pssi          (rst_pssi),
        .pssi_pixclk       (pssi_pixclk),
        .pssi_de           (pssi_de),
        .pssi_data         (pssi_data)
    );

    // ---- Mock N6 receiver ---------------------------------------------
    integer rx_count = 0;
    logic [7:0] rx_buf [0:4095];

    always_ff @(posedge pssi_pixclk) begin
        if (pssi_de) begin
            rx_buf[rx_count]     = pssi_data[7:0];
            rx_buf[rx_count + 1] = pssi_data[15:8];
            rx_count             = rx_count + 2;
        end
    end

    // ---- Snoop-write task: simulate "STA #b, $D49<off>" --------------
    // Chiplet-ext lives at waddr[7]=1; the offset goes in waddr[6:0].
    // $D49C → off 0x1C; $D49D → off 0x1D.
    task snoop_write(input [6:0] off, input [7:0] b);
        @(posedge clk_bus);
        we    <= 1'b1;
        waddr <= {1'b1, off};
        wdata <= b;
        @(posedge clk_bus);
        we    <= 1'b0;
    endtask

    task snoop_read(input [6:0] off, output [7:0] r);
        @(posedge clk_bus);
        raddr <= {1'b1, off};
        @(posedge clk_bus);
        r = rdata;
    endtask

    localparam [6:0] OFF_BYTE   = 7'h1C;
    localparam [6:0] OFF_STATUS = 7'h1D;

    integer i;
    integer fail_count = 0;
    logic [7:0] read_byte;

    initial begin
        we    = 1'b0;
        waddr = 8'h00;
        wdata = 8'h00;
        raddr = 8'h00;

        #50 rst_bus  = 1'b0;
        #30 rst_pssi = 1'b0;

        $display("[pssi_int] start");

        // ---- [A] 64 sequential bytes via $D49C → expect them on PSSI ----
        for (i = 0; i < 64; i++)
            snoop_write(OFF_BYTE, i[7:0]);

        // Drain.
        #5000;

        if (rx_count < 64) begin
            $display("FAIL [A]: only %0d / 64 bytes drained to PSSI", rx_count);
            fail_count = fail_count + 1;
        end else begin
            for (i = 0; i < 64; i++) begin
                if (rx_buf[i] !== i[7:0]) begin
                    $display("FAIL [A]: rx_buf[%0d] = 0x%02h, expected 0x%02h", i, rx_buf[i], i[7:0]);
                    fail_count = fail_count + 1;
                end
            end
            if (fail_count == 0) $display("[A] 64 bytes via $D49C → PSSI match");
        end

        // ---- [B] Last-byte readback via $D49C ---------------------------
        // pssi_bytes latches the last written byte for diagnostic readback.
        snoop_write(OFF_BYTE, 8'hA5);
        snoop_read (OFF_BYTE, read_byte);
        if (read_byte !== 8'hA5) begin
            $display("FAIL [B]: $D49C readback = 0x%02h, expected 0xA5", read_byte);
            fail_count = fail_count + 1;
        end else begin
            $display("[B] $D49C last-byte readback works");
        end

        // ---- [C] Overflow flag set + clear via $D49D --------------------
        // Stall the reader, push past capacity, expect status bit 0 = 1.
        // Then write 1 to $D49D bit 0 to clear, expect 0.
        rst_pssi = 1'b1;
        #50;
        for (i = 0; i < 2400; i++)
            snoop_write(OFF_BYTE, i[7:0]);

        snoop_read(OFF_STATUS, read_byte);
        if ((read_byte & 8'h01) == 1'b0) begin
            $display("FAIL [C]: $D49D bit 0 = 0 after 2400 forced writes (expected 1, overflow)");
            fail_count = fail_count + 1;
        end else begin
            $display("[C] overflow flag observable via $D49D");
        end

        // Now clear it.
        snoop_write(OFF_STATUS, 8'h01);
        // Wait a few clk_bus cycles for the clear pulse to propagate.
        #50;
        snoop_read(OFF_STATUS, read_byte);
        if ((read_byte & 8'h01) != 1'b0) begin
            $display("FAIL [C-clear]: $D49D bit 0 still 1 after software clear");
            fail_count = fail_count + 1;
        end else begin
            $display("[C-clear] software clear works");
        end

        rst_pssi = 1'b0;
        #500;

        if (fail_count == 0) $display("*** PSSI_INT OK ***");
        else                 $display("*** PSSI_INT FAILED (%0d issues) ***", fail_count);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
