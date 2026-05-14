// tb_peri_link.sv — M25-2 SPI-master + peri-RP slave-mock with /CS.
//
// Pairs peri_link (FPGA-side master) with a minimal SPI-slave mock
// that approximates the peri-RP's PL022 in slave mode: 8-bit
// Motorola SPI MODE 0, /CS-delimited frames, 128-byte register file.
//
// Coverage:
//   A — round-trip write: master writes a register, the slave's
//       register file holds the value.
//   B — round-trip read: master reads the register, gets the value
//       back on xfer_rdata.
//   C — back-to-back transfers: two writes + two reads in sequence.
//   D — IRQ pulse: spi_irq falling edge → one peri_irq_pulse.
//
// The slave mock is /CS-driven: on /CS-fall it resets its shift
// counter; on /CS-rise it commits the captured byte (cmd-half →
// decode + arm read response; data-half → write to mem if R/W=0).
// During the data half the slave drives MISO MSB-first from the
// armed response register, shifting on each SCK falling edge.

`default_nettype none
`timescale 1ns / 1ps

module tb_peri_link;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz sim clock
    logic rst = 1'b1;

    // peri_link signals
    logic        xfer_start  = 1'b0;
    logic [6:0]  xfer_addr   = 7'h00;
    logic        xfer_we     = 1'b0;
    logic [7:0]  xfer_wdata  = 8'h00;
    wire  [7:0]  xfer_rdata;
    wire         xfer_done;
    wire         xfer_busy;

    logic        spi_irq     = 1'b1;
    wire         peri_irq_pulse;
    wire         spi_clk;
    wire         spi_mosi;
    wire         spi_miso;
    wire         spi_cs_n;

    peri_link #(
        .CLK_DIV   (4),       // small divider for fast sim
        .HALF_GAP  (8),       // short gap, plenty for the slave model
        .TAIL_GAP  (8)
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
        .spi_irq        (spi_irq),
        .peri_irq_pulse (peri_irq_pulse),
        .spi_clk        (spi_clk),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n)
    );

    // ---- SPI-slave mock --------------------------------------------
    // /CS-framed 8-bit shifter. PL022-equivalent for our needs: each
    // /CS pulse is one frame; cmd byte populates `cmd_q`, data byte
    // either commits the write or rides MISO with the prepared read
    // response.
    localparam logic FRAME_CMD  = 1'b0;
    localparam logic FRAME_DATA = 1'b1;

    logic [7:0]  slave_mem [0:127];
    logic        frame_kind_q;     // FRAME_CMD or FRAME_DATA
    logic [3:0]  bit_cnt_q;        // counts shifted bits 0..8
    logic [7:0]  rx_shift_q;       // accumulated MOSI byte
    logic [7:0]  tx_shift_q;       // outgoing MISO byte (MSB at bit 7)
    logic [7:0]  cmd_q;            // captured cmd byte (R/W + addr)
    logic        spi_clk_q;
    logic        cs_n_q;

    assign spi_miso = tx_shift_q[7];

    initial begin
        for (int i = 0; i < 128; i++) slave_mem[i] = 8'h00;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_kind_q <= FRAME_CMD;
            bit_cnt_q    <= 4'd0;
            rx_shift_q   <= 8'h00;
            tx_shift_q   <= 8'h00;
            cmd_q        <= 8'h00;
            spi_clk_q    <= 1'b0;
            cs_n_q       <= 1'b1;
        end else begin
            spi_clk_q <= spi_clk;
            cs_n_q    <= spi_cs_n;

            if (!spi_cs_n && cs_n_q) begin
                // /CS just fell — start of a new frame.
                bit_cnt_q  <= 4'd0;
                rx_shift_q <= 8'h00;
                if (frame_kind_q == FRAME_DATA) begin
                    // tx_shift_q was loaded to the response byte at
                    // the end of the cmd half — keep it for MISO.
                end else begin
                    tx_shift_q <= 8'h00;       // junk MISO during cmd half
                end
            end

            if (spi_cs_n && !cs_n_q) begin
                // /CS just rose — frame complete.
                if (frame_kind_q == FRAME_CMD) begin
                    cmd_q <= rx_shift_q;
                    if (rx_shift_q[7]) begin
                        // Read — arm response from register file.
                        tx_shift_q <= slave_mem[rx_shift_q[6:0]];
                    end else begin
                        // Write — MISO during data half is don't care.
                        tx_shift_q <= 8'h00;
                    end
                    frame_kind_q <= FRAME_DATA;
                end else begin
                    // Data half complete.
                    if (!cmd_q[7]) begin
                        // Write — commit data byte.
                        slave_mem[cmd_q[6:0]] <= rx_shift_q;
                    end
                    frame_kind_q <= FRAME_CMD;
                end
            end

            // Bit-level shifting, gated on /CS asserted.
            if (!spi_cs_n) begin
                if (spi_clk && !spi_clk_q) begin
                    // Rising edge — sample MOSI into rx_shift_q.
                    rx_shift_q <= {rx_shift_q[6:0], spi_mosi};
                    bit_cnt_q  <= bit_cnt_q + 4'd1;
                end
                if (!spi_clk && spi_clk_q) begin
                    // Falling edge — advance MISO shift.
                    tx_shift_q <= {tx_shift_q[6:0], 1'b0};
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
                           input logic [6:0] addr,
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
        $display("=== M25-2 peri_link ===");

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== A — write a register, peek the slave's mem ==========
        $display("[A] write");
        begin
            logic [7:0] v;
            do_xfer(1'b1, 7'h05, 8'hA5, v);
            #1;
            expect_eq("A.slave_mem[5]", slave_mem[5], 8'hA5);
        end

        // ===== B — read it back via SPI ============================
        $display("[B] read");
        begin
            logic [7:0] v;
            do_xfer(1'b0, 7'h05, 8'h00, v);
            expect_eq("B.read.A5", v, 8'hA5);
        end

        // ===== C — back-to-back: 2 writes + 2 reads ================
        $display("[C] back-to-back");
        begin
            logic [7:0] v;
            do_xfer(1'b1, 7'h11, 8'h33, v);
            do_xfer(1'b1, 7'h22, 8'h44, v);
            do_xfer(1'b0, 7'h11, 8'h00, v);
            expect_eq("C.read.11", v, 8'h33);
            do_xfer(1'b0, 7'h22, 8'h00, v);
            expect_eq("C.read.22", v, 8'h44);
        end

        // ===== D — IRQ edge detect =================================
        $display("[D] IRQ pulse");
        begin
            int pulse_count;
            pulse_count = 0;
            @(negedge clk);
            spi_irq = 1'b0;
            @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                @(posedge clk);
                if (peri_irq_pulse) pulse_count = pulse_count + 1;
            end
            @(negedge clk);
            spi_irq = 1'b1;
            @(posedge clk);
            if (pulse_count != 1) begin
                $display("FAIL D.pulse_count: got %0d, expected 1", pulse_count);
                fail_count++;
            end
        end

        if (fail_count == 0) begin
            $display("*** PERI_LINK OK *** all checks passed");
            $finish;
        end else begin
            $display("*** PERI_LINK FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #10_000_000;
        $display("FAIL: tb_peri_link watchdog");
        $fatal(1);
    end

endmodule
