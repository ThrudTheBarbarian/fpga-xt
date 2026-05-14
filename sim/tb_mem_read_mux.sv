// tb_mem_read_mux.sv — verify the snoop / DMA routing adapter.
//
// Phase A (snoop mode):
//   - dma_mode = 0. Drive caller_raddr through a sequence of
//     addresses; verify caller_rdata = mem_oracle[addr] one cycle
//     later (BRAM-style latency); caller_ready stays high.
//
// Phase B (DMA mode):
//   - dma_mode = 1. Drive caller_req with caller_raddr through the
//     same sequence; for each, verify caller_ready drops to 0 while
//     dma_master is fetching, and that caller_rdata == oracle[addr]
//     once caller_ready returns to 1.

`default_nettype none
`timescale 1ns / 1ps

module tb_mem_read_mux;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz fabric

    logic rst = 1'b1;

    // phi2 generator for dma_master.
    localparam int CLOCK_DIV = 6;
    logic [3:0] phi2_div = 4'd0;
    logic       phi2     = 1'b0;
    always @(posedge clk) begin
        if (phi2_div == (CLOCK_DIV - 1)) begin
            phi2_div <= 4'd0;
            phi2     <= ~phi2;
        end else begin
            phi2_div <= phi2_div + 4'd1;
        end
    end

    // ---- Synthetic 64 KB memory ----------------------------------------
    logic [7:0] mem [0:65535];
    initial begin
        integer k;
        for (k = 0; k < 65536; k = k + 1)
            mem[k] = (k & 8'hFF) ^ (k >> 8);
    end

    // cpu_shadow: instantiate byte_ram and pre-load it at startup.
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;

    wire  [15:0] sh_raddr;
    wire  [7:0]  sh_rdata;

    byte_ram #(.ADDR_W(16), .DEPTH(65536)) u_shadow (
        .clk(clk), .we(bram_we),
        .waddr(bram_waddr), .wdata(bram_wdata),
        .raddr(sh_raddr), .rdata(sh_rdata));

    // dma_master + Atari-bus mock memory.
    logic        dma_req_w;
    logic [15:0] dma_addr_w;
    wire         dma_ack;
    wire         dma_data_valid;
    wire  [7:0]  dma_rdata;
    wire         dma_busy;
    wire         halt_n;
    wire  [15:0] addr_o;
    wire         rw_o;
    wire         bus_oe;
    // The bus memory uses the same oracle.
    wire  [7:0] data_i = bus_oe ? mem[addr_o] : 8'hZZ;

    dma_master u_dma (
        .clk(clk), .rst(rst), .phi2(phi2),
        .req(dma_req_w), .req_addr(dma_addr_w),
        .ack(dma_ack), .data_valid(dma_data_valid),
        .req_data(dma_rdata), .busy(dma_busy),
        .halt_n(halt_n), .addr_o(addr_o), .rw_o(rw_o),
        .bus_oe(bus_oe), .data_i(data_i));

    // DUT.
    logic        dma_mode    = 1'b0;
    logic [15:0] caller_raddr = 16'h0;
    logic        caller_req   = 1'b0;
    wire  [7:0]  caller_rdata;
    wire         caller_ready;

    // BRAM has no handshake — pin sh_ready=1 (always ready); sh_req
    // is discarded (BRAM reads on every clock from sh_raddr).
    wire sh_req_w;

    mem_read_mux #(.ADDR_W(16)) u_dut (
        .clk(clk), .rst(rst), .dma_mode(dma_mode),
        .caller_raddr(caller_raddr), .caller_req(caller_req),
        .caller_rdata(caller_rdata), .caller_ready(caller_ready),
        .sh_raddr(sh_raddr), .sh_req(sh_req_w),
        .sh_rdata(sh_rdata), .sh_ready(1'b1),
        .dma_req(dma_req_w), .dma_addr(dma_addr_w),
        .dma_ack(dma_ack), .dma_data_valid(dma_data_valid),
        .dma_rdata(dma_rdata), .dma_busy(dma_busy));

    int fail_count = 0;

    // Pre-load cpu_shadow with the same oracle as the bus memory.
    task automatic preload_shadow;
        integer k;
        for (k = 0; k < 256; k = k + 1) begin
            @(negedge clk);
            bram_waddr <= k[15:0];
            bram_wdata <= mem[k];
            bram_we    <= 1'b1;
            @(posedge clk);
        end
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    initial begin
        $display("[mem_mux] start");
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        preload_shadow;

        // ===== Phase A — snoop mode =====================================
        dma_mode = 1'b0;
        begin : phase_a
            integer i;
            logic [7:0] got, exp;
            integer mismatches;
            mismatches = 0;
            for (i = 0; i < 64; i = i + 1) begin
                @(negedge clk);
                caller_raddr <= i[15:0];
                @(posedge clk);          // BRAM addr settles
                @(posedge clk);          // BRAM rdata available 1 cycle later
                got = caller_rdata;
                exp = mem[i];
                if (got !== exp) begin
                    if (mismatches < 4)
                        $display("[A] FAIL i=%0d got=$%02h exp=$%02h",
                                 i, got, exp);
                    mismatches++;
                    fail_count++;
                end
                if (caller_ready !== 1'b1) begin
                    if (mismatches < 4)
                        $display("[A/ready] FAIL i=%0d caller_ready=%0b expected 1",
                                 i, caller_ready);
                    mismatches++;
                    fail_count++;
                end
            end
            $display("[mem_mux/A] snoop mode 64 reads OK (%0d mismatches)", mismatches);
        end

        // ===== Phase B — DMA mode ======================================
        dma_mode = 1'b1;
        @(posedge clk);
        // mem_read_mux's D_READY → caller_ready=1 even on first cycle in
        // DMA mode. Drive caller_req per fetch.
        begin : phase_b
            integer i;
            logic [7:0] got, exp;
            integer mismatches;
            integer ready_drops;       // count ready=0 between caller_req and data
            mismatches  = 0;
            ready_drops = 0;
            for (i = 0; i < 16; i = i + 1) begin
                logic [15:0] a;
                a = i[15:0] | 16'h0100;     // distinct from snoop addresses
                // Wait for adapter to be ready (idle).
                while (caller_ready !== 1'b1) @(posedge clk);
                @(negedge clk);
                caller_raddr <= a;
                caller_req   <= 1'b1;
                @(posedge clk);
                @(negedge clk);
                caller_req   <= 1'b0;
                // Adapter should drop ready=0 within 1 cycle.
                @(posedge clk);
                if (caller_ready === 1'b0) ready_drops = ready_drops + 1;
                // Wait for ready to come back high.
                while (caller_ready !== 1'b1) @(posedge clk);
                got = caller_rdata;
                exp = mem[a];
                if (got !== exp) begin
                    if (mismatches < 4)
                        $display("[B] FAIL i=%0d a=$%04h got=$%02h exp=$%02h",
                                 i, a, got, exp);
                    mismatches++;
                    fail_count++;
                end
            end
            if (ready_drops != 16) begin
                $display("[B/stall] FAIL ready_drops=%0d expected 16",
                         ready_drops);
                fail_count++;
            end
            $display("[mem_mux/B] DMA mode 16 reads, %0d stalls observed (expected 16), %0d mismatches",
                     ready_drops, mismatches);
        end

        // ===== Phase C — mode-flip mid-flight ===========================
        // Switch back to snoop mode and verify subsequent reads work.
        dma_mode = 1'b0;
        @(posedge clk);
        begin : phase_c
            integer i;
            logic [7:0] got, exp;
            integer mismatches;
            mismatches = 0;
            for (i = 0; i < 32; i = i + 1) begin
                @(negedge clk);
                caller_raddr <= i[15:0];
                @(posedge clk); @(posedge clk);
                got = caller_rdata;
                exp = mem[i];
                if (got !== exp) begin
                    if (mismatches < 4)
                        $display("[C] FAIL i=%0d got=$%02h exp=$%02h",
                                 i, got, exp);
                    mismatches++;
                    fail_count++;
                end
            end
            $display("[mem_mux/C] mode-flip back to snoop, 32 reads OK (%0d mismatches)",
                     mismatches);
        end

        if (fail_count == 0) begin
            $display("*** MEM_MUX OK *** snoop + DMA + mode-flip routing verified");
            $finish;
        end else begin
            $display("*** MEM_MUX FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_mem_read_mux watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
