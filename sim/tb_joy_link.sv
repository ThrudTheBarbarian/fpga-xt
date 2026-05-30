// tb_joy_link.sv — M25-2c-rev SPI master + PCAL9722-mock slave.
//
// Pairs joy_link (FPGA-side master) with a 24-bit /CS-framed slave
// mock that approximates the PCAL9722's register-access behaviour:
// 64-byte register file, MISO driven from the addressed register
// during the data-byte slot.
//
// Coverage:
//   A — write a register, peek the slave's mem
//   B — read it back via SPI
//   C — back-to-back writes + reads
//   D — INT_N falling edge produces a single peri_int_pulse

`default_nettype none
`timescale 1ns / 1ps

module tb_joy_link;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz sim clock
    logic rst = 1'b1;

    // joy_link signals
    logic        xfer_start = 1'b0;
    logic [7:0]  xfer_addr  = 8'h00;
    logic        xfer_we    = 1'b0;
    logic [7:0]  xfer_wdata = 8'h00;
    wire  [7:0]  xfer_rdata;
    wire         xfer_done;
    wire         xfer_busy;

    logic        spi_int_n  = 1'b1;
    wire         peri_int_pulse;
    wire         spi_clk;
    wire         spi_mosi;
    wire         spi_miso;
    wire         spi_cs_n;

    joy_link #(
        .CLK_DIV     (4),
        .IDLE_CYCLES (16),
        .SLAVE_ADDR  (7'h40)
    ) u_dut (
        .clk            (clk),
        .rst            (rst),
        .xfer_start     (xfer_start),
        .xfer_addr      (xfer_addr),
        .xfer_we        (xfer_we),
        .xfer_wdata     (xfer_wdata),
        .xfer_rdata     (xfer_rdata),
        .xfer_done      (xfer_done),
        .xfer_busy      (xfer_busy),
        .spi_int_n      (spi_int_n),
        .peri_int_pulse (peri_int_pulse),
        .spi_clk        (spi_clk),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n)
    );

    // ---- PCAL9722-mock slave ---------------------------------------
    // /CS-framed 24-bit shifter. Tracks bit position with a counter.
    // After the first 8 bits arrive (cmd byte = device-addr + R/W),
    // notes the R/W. After the next 8 bits (reg addr byte), latches
    // a register-file lookup so MISO can drive the response during
    // bits 16..23 (the data byte slot). On /CS rising edge, commits
    // the write (if R/W=0) or finalises the read.
    logic [7:0]  slave_mem [0:127];
    logic [4:0]  bit_cnt_q;        // 0..24
    logic [23:0] rx_shift_q;
    logic [7:0]  tx_shift_q;
    logic        spi_clk_q;
    logic        cs_n_q;

    assign spi_miso = tx_shift_q[7];

    initial begin
        for (int i = 0; i < 128; i++) slave_mem[i] = 8'h00;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bit_cnt_q  <= 5'd0;
            rx_shift_q <= 24'h0;
            tx_shift_q <= 8'h00;
            spi_clk_q  <= 1'b0;
            cs_n_q     <= 1'b1;
        end else begin
            spi_clk_q <= spi_clk;
            cs_n_q    <= spi_cs_n;

            // /CS-fall: reset bit counter and rx shift.
            if (!spi_cs_n && cs_n_q) begin
                bit_cnt_q  <= 5'd0;
                rx_shift_q <= 24'h0;
                tx_shift_q <= 8'h00;
            end

            // /CS-rise: frame complete. Commit if write.
            if (spi_cs_n && !cs_n_q) begin
                if (rx_shift_q[16] == 1'b0) begin
                    // R/W bit is bit 16 of the 24-bit frame (= first
                    // shifted in, ends up at MSB of bottom 17 bits...
                    // actually after 24 LEFT-shifts, the original
                    // first bit is at bit 23, so R/W (originally
                    // bit-16-of-MSB-first-stream) lands at bit 16
                    // here? Hmm — see below.)
                    //
                    // Original wire bits:
                    //   23..17 : device addr  → ends up at rx[23..17]
                    //   16     : R/W          → ends up at rx[16]
                    //   15..8  : reg addr     → rx[15..8]
                    //   7..0   : data         → rx[7..0]
                    // (24-bit MSB-first shift left: first bit goes
                    // to bit 0 of shift register, then pushed up by
                    // subsequent shifts; after 24 shifts, first bit
                    // sits at bit 23.)
                    slave_mem[rx_shift_q[14:8] & 7'h7F] <= rx_shift_q[7:0];
                end
            end

            // Bit-level shifting, gated on /CS asserted.
            if (!spi_cs_n) begin
                if (spi_clk && !spi_clk_q) begin
                    // Rising edge — sample MOSI into rx_shift_q.
                    rx_shift_q <= {rx_shift_q[22:0], spi_mosi};
                    bit_cnt_q  <= bit_cnt_q + 5'd1;
                end
                if (!spi_clk && spi_clk_q) begin
                    if (bit_cnt_q == 5'd16) begin
                        // Falling edge between bits 16 and 17 — the
                        // cmd + reg-addr bytes are fully shifted in.
                        // Load tx_shift with the addressed register
                        // so MISO drives the response from this
                        // edge onward. NBA-overrides the falling-
                        // edge shift below.
                        tx_shift_q <= slave_mem[rx_shift_q[7:0] & 7'h7F];
                    end else begin
                        // Otherwise advance the MISO shift register
                        // (matters once the data half has begun).
                        tx_shift_q <= {tx_shift_q[6:0], 1'b0};
                    end
                end
            end
        end
    end

    // ---- Test driver -----------------------------------------------
    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    task automatic do_xfer(input logic       we,
                           input logic [7:0] addr,
                           input logic [7:0] wdata,
                           output logic [7:0] rdata);
        @(negedge clk);
        while (xfer_busy) @(posedge clk);
        @(negedge clk);
        xfer_addr  = addr;
        xfer_we    = we;
        xfer_wdata = wdata;
        xfer_start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        xfer_start = 1'b0;
        while (!xfer_done) @(posedge clk);
        rdata = xfer_rdata;
        @(negedge clk);
        while (xfer_busy) @(posedge clk);
    endtask

    initial begin
        $display("=== M25-2c-rev joy_link ===");

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== A — write a register, peek the slave's mem ==========
        $display("[A] write");
        begin
            logic [7:0] v;
            do_xfer(1'b1, 8'h05, 8'hA5, v);     // W: addr=$05, data=$A5
            #1;
            expect_eq("A.slave_mem[5]", slave_mem[7'h05], 8'hA5);
        end

        // ===== B — read it back ====================================
        $display("[B] read");
        begin
            logic [7:0] v;
            do_xfer(1'b0, 8'h05, 8'h00, v);
            expect_eq("B.read.A5", v, 8'hA5);
        end

        // ===== C — back-to-back ====================================
        $display("[C] back-to-back");
        begin
            logic [7:0] v;
            do_xfer(1'b1, 8'h11, 8'h33, v);
            do_xfer(1'b1, 8'h22, 8'h44, v);
            do_xfer(1'b0, 8'h11, 8'h00, v);
            expect_eq("C.read.11", v, 8'h33);
            do_xfer(1'b0, 8'h22, 8'h00, v);
            expect_eq("C.read.22", v, 8'h44);
        end

        // ===== D — INT_N edge detect ===============================
        $display("[D] INT_N pulse");
        begin
            int pulse_count;
            pulse_count = 0;
            @(negedge clk);
            spi_int_n = 1'b0;
            @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                @(posedge clk);
                if (peri_int_pulse) pulse_count = pulse_count + 1;
            end
            @(negedge clk);
            spi_int_n = 1'b1;
            @(posedge clk);
            if (pulse_count != 1) begin
                $display("FAIL D.pulse_count: got %0d, expected 1", pulse_count);
                fail_count++;
            end
        end

        if (fail_count == 0) begin
            $display("*** JOY_LINK OK *** all checks passed");
            $finish;
        end else begin
            $display("*** JOY_LINK FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #10_000_000;
        $display("FAIL: tb_joy_link watchdog");
        $fatal(1);
    end

endmodule
