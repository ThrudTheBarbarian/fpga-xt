// tb_os_rom_load.sv — M24-6 OS ROM load path.
//
// Wires antic_regs + sally_mem and exercises the chiplet-ext register
// set $D49C-$D49F. Verifies:
//
//   A. Set address ($D49C/$D49D), stream a byte through $D49E,
//      verify the BRAM at the target address holds the byte AND
//      $D49C/$D49D auto-incremented.
//   B. Stream multiple bytes — auto-increment cycles correctly.
//   C. WRITE_LOCK ($D49F bit 0) blocks further loads — write attempt
//      after locking does NOT update BRAM.
//   D. ROM-load lands in a region the CPU normally treats as ROM
//      ($C000-$CFFF, $D800-$FFFF). Verify a CPU-side read after the
//      load returns the loaded byte.
//
// Production note: real ROM contents come from a `$readmemh`'d
// `os_rom.hex` baked into the bitstream at synth time. This test
// uses the load-port to overwrite addresses regardless of initial
// contents.

`timescale 1ns / 1ps

module tb_os_rom_load;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- antic_regs <-> sally_mem wires ---------------------------
    logic [15:0] cpu_addr  = 16'h0000;
    logic [7:0]  cpu_wdata = 8'h00;
    logic        cpu_rw    = 1'b1;
    wire  [7:0]  cpu_rdata;

    wire        rom_we;
    wire [15:0] rom_addr;
    wire [7:0]  rom_data;

    // hwreg interface — sally_mem ↔ antic_regs.
    wire [15:0] hwreg_addr;
    wire        hwreg_we_w;
    wire [7:0]  hwreg_din_w;
    wire [7:0]  antic_rdata_w;

    // antic_regs read mux for the hwreg port (bus_addr → rdata).
    // sally_mem provides hwreg_addr (the live CPU address) for the
    // read path.
    antic_regs u_antic_regs (
        .clk                  (clk),
        .rst                  (rst),
        .we                   (hwreg_we_w),
        .waddr                (hwreg_addr[7:0]),
        .wdata                (hwreg_din_w),
        .raddr                (hwreg_addr[7:0]),
        .rdata                (antic_rdata_w),
        .wsync_pending        (),
        .nmires_strobe        (),
        .pal_write_strobe     (),
        .pal_r_q              (),
        .pal_g_q              (),
        .pal_b_q              (),
        .pal_idx_q            (),
        .dmactl_q             (),
        .chactl_q             (),
        .dlistl_q             (),
        .dlisth_q             (),
        .hscrol_q             (),
        .vscrol_q             (),
        .pmbase_q             (),
        .chbase_q             (),
        .nmien_q              (),
        .mode_snoop_q         (),
        .clock_mult_q         (),
        .output_mode_q        (),
        .os_rom_addr_q        (rom_addr),
        .os_rom_data_q        (rom_data),
        .os_rom_we            (rom_we),
        .os_rom_locked_q      (),
        .vcount_in            (8'h00),
        .nmist_in             (8'h00),
        .serial_clock_mult_in (8'd12)
    );

    // ---- AXI bus to memory-backed slave (replaces v1 hyperram mock) ----
    // This test doesn't exercise the bank window, but sally_mem still
    // needs the AXI plumbed for clean elaboration.
    wire [31:0] axi_araddr, axi_awaddr;
    wire [7:0]  axi_arlen,  axi_awlen;
    wire [2:0]  axi_arsize, axi_awsize;
    wire [1:0]  axi_arburst, axi_awburst;
    wire        axi_arvalid, axi_awvalid;
    wire        axi_arready, axi_awready;
    wire [63:0] axi_rdata,   axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast,   axi_wvalid, axi_wready;
    wire        axi_rvalid,  axi_rlast,  axi_rready;
    wire        axi_bvalid,  axi_bready;

    wire mem_busy;

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000)
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (cpu_addr),
        .data_in    (cpu_wdata),
        .rw         (cpu_rw),
        .data_out   (cpu_rdata),
        .rdy        (1'b1),
        .busy       (mem_busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we_w),
        .hwreg_din  (hwreg_din_w),
        .hwreg_dout (antic_rdata_w),
        .cpu_code_bank_q    (),
        .cpu_data_bank_lo_q (),
        .cpu_data_bank_hi_q (),
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'hFF),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rready  (axi_rready),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready),
        .rom_addr    (rom_addr),
        .rom_data    (rom_data),
        .rom_we      (rom_we),
        .stack_op    (1'b0),
        .s_high      (4'd0),
        .dma_clk     (clk),
        .dma_addr    (16'd0),
        .dma_rdata   ()
    );

    axi_slave_mem u_axi_mem (
        .clk           (clk),
        .rst           (rst),
        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awlen   (axi_awlen),
        .s_axi_awsize  (axi_awsize),
        .s_axi_awburst (axi_awburst),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wlast   (axi_wlast),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),
        .s_axi_araddr  (axi_araddr),
        .s_axi_arlen   (axi_arlen),
        .s_axi_arsize  (axi_arsize),
        .s_axi_arburst (axi_arburst),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rlast   (axi_rlast),
        .s_axi_rready  (axi_rready)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // CPU-side write to a hardware-register-page address. After the
    // task returns we've advanced past the strobe → mem write → idle
    // sequence, so subsequent reads of u_mem.mem see the new byte.
    task automatic do_hwreg_write(input [15:0] a, input [7:0] v);
        @(negedge clk);
        cpu_addr  = a;
        cpu_wdata = v;
        cpu_rw    = 1'b0;
        @(posedge clk);            // antic_regs latches; os_rom_we <= 1
        @(negedge clk);
        cpu_addr  = 16'h0000;
        cpu_wdata = 8'h00;
        cpu_rw    = 1'b1;
        @(posedge clk);            // sally_mem sees rom_we=1 → mem[rom_addr] <= rom_data
        @(negedge clk);            // NBA from prior posedge has committed; mem updated
    endtask

    // CPU-side read of an arbitrary address; samples cpu_rdata two
    // cycles after presenting the addr (synchronous-mem contract).
    task automatic do_read(input [15:0] a, output [7:0] v);
        @(negedge clk);
        cpu_addr = a;
        cpu_rw   = 1'b1;
        @(posedge clk);
        @(negedge clk);
        v = cpu_rdata;
    endtask

    initial begin
        $display("=== M24-6 os_rom_load ===");

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== Phase A — single-byte load + auto-increment =============
        $display("[A] single-byte load + auto-increment");
        // Set target address $E100 → write $D49C=$00, $D49D=$C1
        do_hwreg_write(16'hD49C, 8'h00);
        do_hwreg_write(16'hD49D, 8'hE1);
        // Stream a byte
        do_hwreg_write(16'hD49E, 8'hAB);
        // Verify BRAM at $E100
        expect_eq("A.bram[$E100]", u_mem.mem[16'hE100], 8'hAB);
        // Verify auto-increment: address now $E101
        expect_eq("A.os_rom_addr", rom_addr, 16'hE101);

        // ===== Phase B — multi-byte stream =============================
        // Stream 4 more bytes. Target advances each time.
        $display("[B] multi-byte stream");
        do_hwreg_write(16'hD49E, 8'h11);   // → $E101
        do_hwreg_write(16'hD49E, 8'h22);   // → $E102
        do_hwreg_write(16'hD49E, 8'h33);   // → $E103
        do_hwreg_write(16'hD49E, 8'h44);   // → $E104
        expect_eq("B.bram[$E101]", u_mem.mem[16'hE101], 8'h11);
        expect_eq("B.bram[$E102]", u_mem.mem[16'hE102], 8'h22);
        expect_eq("B.bram[$E103]", u_mem.mem[16'hE103], 8'h33);
        expect_eq("B.bram[$E104]", u_mem.mem[16'hE104], 8'h44);
        expect_eq("B.os_rom_addr final", rom_addr, 16'hE105);

        // ===== Phase C — WRITE_LOCK blocks further loads ===============
        $display("[C] WRITE_LOCK blocks further loads");
        // Lock by writing 1 to $D49F bit 0.
        do_hwreg_write(16'hD49F, 8'h01);
        // Try a load — should be ignored. Address shouldn't auto-incr.
        do_hwreg_write(16'hD49E, 8'h99);
        // mem[$E105] is uninitialised (= X) but it must NOT equal $99
        // — that's the headline "lock blocked the write" check.
        if (u_mem.mem[16'hE105] === 8'h99) begin
            $display("FAIL C.bram[$E105]: locked write committed ($99 leaked through)");
            fail_count++;
        end
        expect_eq("C.os_rom_addr unchanged after locked write", rom_addr, 16'hE105);

        // Unlock and confirm the path resumes.
        do_hwreg_write(16'hD49F, 8'h00);
        do_hwreg_write(16'hD49E, 8'h99);
        expect_eq("C.bram[$E105] after unlock", u_mem.mem[16'hE105], 8'h99);

        // ===== Phase D — CPU-side readback through normal path =========
        // After the load, the CPU should read the loaded byte through
        // the normal sally_mem read path (= the BRAM region for
        // $C000-$CFFF is now populated).
        $display("[D] CPU-side readback through normal path");
        begin
            logic [7:0] v;
            do_read(16'hE100, v);
            expect_eq("D.cpu_read $E100", v, 8'hAB);
            do_read(16'hE102, v);
            expect_eq("D.cpu_read $E102", v, 8'h22);
        end

        // ===== Phase E — load into the high ROM region $D800-$FFFF =====
        $display("[E] load into $D800-$FFFF region");
        do_hwreg_write(16'hD49C, 8'hFC);   // addr lo = $FC
        do_hwreg_write(16'hD49D, 8'hFF);   // addr hi = $FF → $FFFC
        do_hwreg_write(16'hD49E, 8'h00);   // reset vec lo
        do_hwreg_write(16'hD49E, 8'h02);   // reset vec hi
        expect_eq("E.bram[$FFFC]", u_mem.mem[16'hFFFC], 8'h00);
        expect_eq("E.bram[$FFFD]", u_mem.mem[16'hFFFD], 8'h02);

        if (fail_count == 0) begin
            $display("*** OS_ROM_LOAD OK *** stream + auto-incr + lock + cpu-readback");
            $finish;
        end else begin
            $display("*** OS_ROM_LOAD FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_os_rom_load watchdog");
        $fatal(1);
    end

endmodule
