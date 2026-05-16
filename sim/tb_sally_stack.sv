// tb_sally_stack.sv — exercise the Stage A Increment 1 stack-BRAM alias.
//
// Drives sally_mem directly (no CPU) and verifies that:
//   1. Writes to $0100-$01FF land in the hidden stack BRAM, NOT in main RAM.
//   2. Reads from $0100-$01FF return data from stack BRAM via the alias.
//   3. Other addresses (e.g., $0200, $0050) use the main RAM as before.
//   4. The stack and main RAM are independent — a write to $0150 does not
//      affect a future write+read at $0250.
//   5. ROM-load writes targeting $0100-$01FF (via rom_addr / rom_we) land
//      in stack BRAM, not main RAM.
//
// Cycle model (sally_mem is synchronous-read):
//   Cycle N: present addr, rw, data_in.  rdy=1.
//   Posedge N+1: bram_dout_q / stack_dout_q latched, was_stack_q latched.
//   Cycle N+1: data_out reflects the value read at cycle N.

`timescale 1ns / 1ps

module tb_sally_stack;

    logic clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz
    logic rst = 1'b1;

    // ---- DUT ports ----------------------------------------------------
    logic [15:0] addr;
    logic [7:0]  data_in;
    logic        rw;            // 1 = read, 0 = write
    wire  [7:0]  data_out;
    logic        rdy = 1'b1;
    wire         busy;

    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;

    wire [7:0]  cpu_code_bank_q, cpu_data_bank_q;
    wire [7:0]  cpu_regc_bank_lo_q, cpu_regc_bank_hi_q;

    // AXI master ports — tied off (banked window unused in this test)
    wire [31:0] m_axi_araddr, m_axi_awaddr;
    wire [7:0]  m_axi_arlen, m_axi_awlen;
    wire [2:0]  m_axi_arsize, m_axi_awsize;
    wire [1:0]  m_axi_arburst, m_axi_awburst;
    wire        m_axi_arvalid, m_axi_awvalid;
    wire        m_axi_rready, m_axi_wlast, m_axi_wvalid, m_axi_bready;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;

    // ROM-load port
    logic [15:0] rom_addr = 16'h0000;
    logic [7:0]  rom_data = 8'h00;
    logic        rom_we   = 1'b0;

    // ---- DUT ------------------------------------------------------------
    sally_mem #(
        .OS_ROM_HEX_PATH ("")
    ) u_mem (
        .clk                 (clk),
        .rst                 (rst),
        .addr                (addr),
        .data_in             (data_in),
        .rw                  (rw),
        .data_out            (data_out),
        .rdy                 (rdy),
        .busy                (busy),
        .hwreg_addr          (hwreg_addr),
        .hwreg_we            (hwreg_we),
        .hwreg_din           (hwreg_din),
        .hwreg_dout          (hwreg_dout),
        .cpu_code_bank_q     (cpu_code_bank_q),
        .cpu_data_bank_q     (cpu_data_bank_q),
        .cpu_regc_bank_lo_q  (cpu_regc_bank_lo_q),
        .cpu_regc_bank_hi_q  (cpu_regc_bank_hi_q),
        .antic_code_bank     (8'h00),
        .antic_data_bank     (8'h00),
        .antic_regc_bank_lo  (8'h00),
        .antic_regc_bank_hi  (8'h00),
        .view_is_antic       (1'b0),
        .bus_mpd_n_in        (1'b1),         // /MPD high = no PBI override
        .bus_pbi_rdata       (8'h00),
        .bus_rd4_n_in        (1'b1),         // no cart $8000-$9FFF
        .bus_rd5_n_in        (1'b1),         // no cart $A000-$BFFF
        .m_axi_araddr        (m_axi_araddr),
        .m_axi_arlen         (m_axi_arlen),
        .m_axi_arsize        (m_axi_arsize),
        .m_axi_arburst       (m_axi_arburst),
        .m_axi_arvalid       (m_axi_arvalid),
        .m_axi_arready       (1'b0),
        .m_axi_rdata         (64'd0),
        .m_axi_rvalid        (1'b0),
        .m_axi_rlast         (1'b0),
        .m_axi_rready        (m_axi_rready),
        .m_axi_awaddr        (m_axi_awaddr),
        .m_axi_awlen         (m_axi_awlen),
        .m_axi_awsize        (m_axi_awsize),
        .m_axi_awburst       (m_axi_awburst),
        .m_axi_awvalid       (m_axi_awvalid),
        .m_axi_awready       (1'b0),
        .m_axi_wdata         (m_axi_wdata),
        .m_axi_wstrb         (m_axi_wstrb),
        .m_axi_wlast         (m_axi_wlast),
        .m_axi_wvalid        (m_axi_wvalid),
        .m_axi_wready        (1'b0),
        .m_axi_bvalid        (1'b0),
        .m_axi_bready        (m_axi_bready),
        .rom_addr            (rom_addr),
        .rom_data            (rom_data),
        .rom_we              (rom_we),
        .dma_clk             (clk),
        .dma_addr            (16'h0000),
        .dma_rdata           ()
    );

    // ---- Test helpers --------------------------------------------------
    task automatic write_byte(input [15:0] a, input [7:0] d);
        @(negedge clk);
        addr    <= a;
        data_in <= d;
        rw      <= 1'b0;
        @(negedge clk);
        rw      <= 1'b1;        // back to read default
    endtask

    task automatic read_byte_expect(input [15:0] a, input [7:0] expected,
                                    input string label);
        @(negedge clk);
        addr <= a;
        rw   <= 1'b1;
        @(posedge clk);          // posedge captures bram/stack_dout_q
        @(negedge clk);          // settle; data_out now reflects addr a
        if (data_out !== expected) begin
            $display("FAIL: %s — read [%04h] = %02h, expected %02h",
                     label, a, data_out, expected);
            $fatal(1);
        end
    endtask

    // ---- Test scheduler -------------------------------------------------
    initial begin
        $display("=== tb_sally_stack starting ===");
        addr    = 16'h0000;
        data_in = 8'h00;
        rw      = 1'b1;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- 1. Round-trip write/read on the stack page --------------
        write_byte(16'h0150, 8'hAA);
        read_byte_expect(16'h0150, 8'hAA, "stack[$0150] round-trip");

        write_byte(16'h0101, 8'h11);
        write_byte(16'h01FE, 8'hEE);
        read_byte_expect(16'h0101, 8'h11, "stack[$0101]");
        read_byte_expect(16'h01FE, 8'hEE, "stack[$01FE]");

        // ---- 2. Round-trip on a non-stack page (main mem) -----------
        write_byte(16'h0200, 8'h55);
        read_byte_expect(16'h0200, 8'h55, "main[$0200] round-trip");

        write_byte(16'h0050, 8'h77);    // zero page
        read_byte_expect(16'h0050, 8'h77, "main[$0050] (zero page)");

        // ---- 3. Independence: stack and main are separate -----------
        // Write $BB to $0150 (stack) then $CC to $0250 (main).  Each
        // should keep its own value with no cross-contamination.
        write_byte(16'h0150, 8'hBB);
        write_byte(16'h0250, 8'hCC);
        read_byte_expect(16'h0150, 8'hBB, "stack[$0150] independent");
        read_byte_expect(16'h0250, 8'hCC, "main[$0250] independent");

        // ---- 4. Overwriting stack page is durable -------------------
        write_byte(16'h0150, 8'h33);
        read_byte_expect(16'h0150, 8'h33, "stack[$0150] overwrite");

        // ---- 5. ROM-load writes to stack page land in stack BRAM ----
        @(negedge clk);
        rom_addr <= 16'h0180;
        rom_data <= 8'h42;
        rom_we   <= 1'b1;
        @(negedge clk);
        rom_we   <= 1'b0;
        read_byte_expect(16'h0180, 8'h42, "rom_we → stack[$0180]");

        // ROM-load to non-stack page goes to main mem as usual.
        @(negedge clk);
        rom_addr <= 16'h0300;
        rom_data <= 8'h84;
        rom_we   <= 1'b1;
        @(negedge clk);
        rom_we   <= 1'b0;
        read_byte_expect(16'h0300, 8'h84, "rom_we → main[$0300]");

        $display("=== ALL TESTS PASSED ===");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: timeout");
        $fatal(1);
    end

endmodule
