// tb_bank.sv — verify bank_translator + hyperram_shim integration
// against a synthetic 130XE PORTB schedule.
//
// The testbench wires three logical-address consumers into a single
// hyperram_shim (24-bit physical address space), each through its
// own bank_translator:
//   - bus_snoop side (write port) uses CPU bank context (PORTB[4]).
//   - dl_parser side (read port A) uses ANTIC bank context (PORTB[5]).
//   - compositor side (read port B) also uses ANTIC bank context.
// Bank index for both contexts comes from PORTB[3:2].
//
// Phases:
//   A — banking off (PORTB[4]=PORTB[5]=1): writes and reads pass
//       straight through; verifies the translator's pass-through
//       branch is wired correctly.
//   B — CPU banked, ANTIC not: write to logical $4000+i lands in
//       extended bank N (selected by PORTB[3:2]). ANTIC reading the
//       same logical address sees MAIN $4000+i, not the bank.
//   C — ANTIC banked, CPU not: mirror of Phase B for the other port.
//   D — both banked, same bank: write via CPU, read via ANTIC, both
//       resolve to the same physical extended bank → coherent.
//   E — bank index switching: write bank 0 then bank 1 at the same
//       logical $4000; verifies banks live at distinct physical
//       addresses and don't alias.

`default_nettype none
`timescale 1ns / 1ps

module tb_bank;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    localparam int LATENCY     = 4;
    localparam int PHYS_ADDR_W = 24;

    // ---- 130XE PORTB ($D301) -----------------------------------------
    // bit 4 = !cpu_bank_en, bit 5 = !antic_bank_en, bits 3:2 = bank_idx
    logic [7:0] portb = 8'hFF;
    wire        cpu_bank_en   = ~portb[4];
    wire        antic_bank_en = ~portb[5];
    wire  [1:0] bank_idx      = portb[3:2];

    // ---- Logical address signals -------------------------------------
    // Write port (bus_snoop side).
    logic              we    = 1'b0;
    logic [15:0]       waddr = 16'h0;
    logic [7:0]        wdata = 8'h0;
    wire               wready;

    // Read port A (dl_parser side).
    logic              req_a   = 1'b0;
    logic [15:0]       raddr_a_log = 16'h0;
    wire  [7:0]        rdata_a;
    wire               rd_valid_a;
    wire               ready_a;

    // Read port B (compositor side).
    logic              req_b   = 1'b0;
    logic [15:0]       raddr_b_log = 16'h0;
    wire  [7:0]        rdata_b;
    wire               rd_valid_b;
    wire               ready_b;

    // ---- Translators ------------------------------------------------
    wire [PHYS_ADDR_W-1:0] waddr_phys, raddr_a_phys, raddr_b_phys;

    // Cart banking signals (driven directly by the test).
    logic       cart_en       = 1'b0;
    logic [3:0] cart_bank_idx = 4'h0;
    logic       cart_size_16k = 1'b0;

    bank_translator #(.LOG_ADDR_W(16), .PHYS_ADDR_W(PHYS_ADDR_W)) u_xlate_w (
        .logical_addr(waddr),
        .portb_bank_en(cpu_bank_en), .portb_bank_idx(bank_idx),
        .cart_en(cart_en), .cart_bank_idx(cart_bank_idx),
        .cart_size_16k(cart_size_16k),
        .physical_addr(waddr_phys));
    bank_translator #(.LOG_ADDR_W(16), .PHYS_ADDR_W(PHYS_ADDR_W)) u_xlate_a (
        .logical_addr(raddr_a_log),
        .portb_bank_en(antic_bank_en), .portb_bank_idx(bank_idx),
        .cart_en(cart_en), .cart_bank_idx(cart_bank_idx),
        .cart_size_16k(cart_size_16k),
        .physical_addr(raddr_a_phys));
    bank_translator #(.LOG_ADDR_W(16), .PHYS_ADDR_W(PHYS_ADDR_W)) u_xlate_b (
        .logical_addr(raddr_b_log),
        .portb_bank_en(antic_bank_en), .portb_bank_idx(bank_idx),
        .cart_en(cart_en), .cart_bank_idx(cart_bank_idx),
        .cart_size_16k(cart_size_16k),
        .physical_addr(raddr_b_phys));

    // ---- hyperram_shim ----------------------------------------------
    hyperram_shim #(.ADDR_W(PHYS_ADDR_W), .LATENCY(LATENCY)) u_dut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr_phys), .wdata(wdata), .wready(wready),
        .req_a(req_a), .raddr_a(raddr_a_phys),
        .rdata_a(rdata_a), .rd_valid_a(rd_valid_a), .ready_a(ready_a),
        .req_b(req_b), .raddr_b(raddr_b_phys),
        .rdata_b(rdata_b), .rd_valid_b(rd_valid_b), .ready_b(ready_b));

    // ---- Helpers -----------------------------------------------------
    task automatic do_write(input logic [15:0] a, input logic [7:0] d);
        wait (wready);
        @(negedge clk);
        we    = 1'b1;
        waddr = a;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
    endtask

    task automatic do_read_a(input logic [15:0] a, output logic [7:0] got);
        wait (ready_a);
        @(negedge clk);
        raddr_a_log = a;
        req_a       = 1'b1;
        wait (!ready_a);
        @(negedge clk);
        req_a       = 1'b0;
        wait (rd_valid_a);
        @(posedge clk);
        got = rdata_a;
        @(negedge clk);
    endtask

    task automatic do_read_b(input logic [15:0] a, output logic [7:0] got);
        wait (ready_b);
        @(negedge clk);
        raddr_b_log = a;
        req_b       = 1'b1;
        wait (!ready_b);
        @(negedge clk);
        req_b       = 1'b0;
        wait (rd_valid_b);
        @(posedge clk);
        got = rdata_b;
        @(negedge clk);
    endtask

    int fail_count = 0;

    initial begin
        $display("[bank] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — banking off =====================================
        portb = 8'hFF;       // both bank-en bits high → main RAM
        do_write(16'h4100, 8'hAA);
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_a
            logic [7:0] got;
            do_read_a(16'h4100, got);
            if (got !== 8'hAA) begin
                $display("[A/A] FAIL got=$%02h expected=$AA", got);
                fail_count++;
            end
            do_read_b(16'h4100, got);
            if (got !== 8'hAA) begin
                $display("[A/B] FAIL got=$%02h expected=$AA", got);
                fail_count++;
            end
            // Sanity: physical addr in main 64K.
            if (waddr_phys !== {{(PHYS_ADDR_W-16){1'b0}}, 16'h4100}) begin
                $display("[A/phys] FAIL waddr_phys=$%06h expected $004100",
                         waddr_phys);
                fail_count++;
            end
            $display("[bank/A] banking off — pass-through OK");
        end

        // ===== Phase B — CPU banked, ANTIC not ===========================
        // Pre-load main $4100 with $11 (via PORTB=$FF), then write to
        // bank 0 at logical $4100 with PORTB[4]=0 (CPU banked).
        portb = 8'hFF;
        do_write(16'h4100, 8'h11);
        repeat (LATENCY+4) @(posedge clk);
        portb = 8'b1110_0000;        // CPU banked (bit4=0), ANTIC main, idx=0
        do_write(16'h4100, 8'h22);   // → extended bank 0
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_b
            logic [7:0] got;
            // ANTIC reads $4100 with bank_en=0 → main RAM = $11.
            do_read_a(16'h4100, got);
            if (got !== 8'h11) begin
                $display("[B/A] FAIL got=$%02h expected=$11 (main)", got);
                fail_count++;
            end
            // Flip ANTIC into the same bank (0): should now see $22.
            portb = 8'b1100_0000;     // CPU bank, ANTIC bank, idx=0
            do_read_a(16'h4100, got);
            if (got !== 8'h22) begin
                $display("[B/A2] FAIL got=$%02h expected=$22 (bank0)", got);
                fail_count++;
            end
            $display("[bank/B] CPU-bank/ANTIC-main partition OK");
        end

        // ===== Phase C — ANTIC banked, CPU not ===========================
        portb = 8'hFF;
        do_write(16'h4200, 8'h33);   // main, $33
        repeat (LATENCY+4) @(posedge clk);
        // Pre-load bank 0 at logical $4200 with a distinct sentinel so
        // the ANTIC-banked read produces a definite mismatch vs. main.
        portb = 8'b1100_0000;        // CPU + ANTIC banked, idx=0 (so write goes to bank 0)
        do_write(16'h4200, 8'h99);
        repeat (LATENCY+4) @(posedge clk);
        portb = 8'b1101_0000;        // CPU main (bit4=1), ANTIC banked (bit5=0), idx=0
        do_write(16'h4200, 8'h44);   // CPU now main → main $4200 = $44 (over $33)
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_c
            logic [7:0] got;
            // ANTIC view (banked): bank 0 at offset $0200 = $99
            do_read_b(16'h4200, got);
            if (got !== 8'h99) begin
                $display("[C/B] FAIL got=$%02h expected=$99 (bank0)", got);
                fail_count++;
            end
            // Banking back off: ANTIC sees main $44.
            portb = 8'hFF;
            do_read_b(16'h4200, got);
            if (got !== 8'h44) begin
                $display("[C/B2] FAIL got=$%02h expected=$44 (main)", got);
                fail_count++;
            end
            $display("[bank/C] ANTIC-bank/CPU-main partition OK");
        end

        // ===== Phase D — both banked, same bank, coherent =================
        portb = 8'b1100_0100;        // CPU bank, ANTIC bank, idx=1
        do_write(16'h4500, 8'h55);   // → bank 1
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_d
            logic [7:0] got;
            do_read_a(16'h4500, got);
            if (got !== 8'h55) begin
                $display("[D/A] FAIL got=$%02h expected=$55 (bank1)", got);
                fail_count++;
            end
            do_read_b(16'h4500, got);
            if (got !== 8'h55) begin
                $display("[D/B] FAIL got=$%02h expected=$55", got);
                fail_count++;
            end
            $display("[bank/D] CPU+ANTIC same-bank coherence OK");
        end

        // ===== Phase E — bank index switching =============================
        // Write distinct values at the same logical addr through different
        // bank indices; verify they don't alias.
        portb = 8'b1100_0000;        // bank 0
        do_write(16'h6000, 8'h66);
        repeat (LATENCY+4) @(posedge clk);
        portb = 8'b1100_0100;        // bank 1
        do_write(16'h6000, 8'h77);
        repeat (LATENCY+4) @(posedge clk);
        portb = 8'b1100_1000;        // bank 2
        do_write(16'h6000, 8'h88);
        repeat (LATENCY+4) @(posedge clk);
        portb = 8'b1100_1100;        // bank 3
        do_write(16'h6000, 8'h99);
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_e
            logic [7:0] got;
            portb = 8'b1100_0000;
            do_read_a(16'h6000, got);
            if (got !== 8'h66) begin $display("[E/0] FAIL got=$%02h expected=$66", got); fail_count++; end
            portb = 8'b1100_0100;
            do_read_a(16'h6000, got);
            if (got !== 8'h77) begin $display("[E/1] FAIL got=$%02h expected=$77", got); fail_count++; end
            portb = 8'b1100_1000;
            do_read_a(16'h6000, got);
            if (got !== 8'h88) begin $display("[E/2] FAIL got=$%02h expected=$88", got); fail_count++; end
            portb = 8'b1100_1100;
            do_read_a(16'h6000, got);
            if (got !== 8'h99) begin $display("[E/3] FAIL got=$%02h expected=$99", got); fail_count++; end
            $display("[bank/E] 4 banks at logical $6000 distinct ($66/$77/$88/$99)");
        end

        // ===== Phase F — 8 KB cart at $A000-$BFFF =========================
        // 16 banks × 8 KB. Write distinct sentinels into 4 banks at the
        // same logical $A100, then read back through each bank index
        // and assert no aliasing with main RAM or with each other.
        portb = 8'hFF;                  // banking off
        cart_size_16k = 1'b0;           // 8 KB cart mode
        cart_en       = 1'b1;
        // Pre-load main $A100 with a sentinel that mustn't appear in
        // any cart bank read.
        cart_en       = 1'b0;
        do_write(16'hA100, 8'h11);       // main RAM
        repeat (LATENCY+4) @(posedge clk);
        cart_en       = 1'b1;
        // Bank 0 = $A0, bank 5 = $A5, bank 10 = $AA, bank 15 = $AF.
        cart_bank_idx = 4'h0;  do_write(16'hA100, 8'hA0); repeat (LATENCY+4) @(posedge clk);
        cart_bank_idx = 4'h5;  do_write(16'hA100, 8'hA5); repeat (LATENCY+4) @(posedge clk);
        cart_bank_idx = 4'hA;  do_write(16'hA100, 8'hAA); repeat (LATENCY+4) @(posedge clk);
        cart_bank_idx = 4'hF;  do_write(16'hA100, 8'hAF); repeat (LATENCY+4) @(posedge clk);
        begin : phase_f
            logic [7:0] got;
            cart_bank_idx = 4'h0;  do_read_a(16'hA100, got);
            if (got !== 8'hA0) begin $display("[F/0] FAIL got=$%02h expected=$A0", got); fail_count++; end
            cart_bank_idx = 4'h5;  do_read_a(16'hA100, got);
            if (got !== 8'hA5) begin $display("[F/5] FAIL got=$%02h expected=$A5", got); fail_count++; end
            cart_bank_idx = 4'hA;  do_read_a(16'hA100, got);
            if (got !== 8'hAA) begin $display("[F/A] FAIL got=$%02h expected=$AA", got); fail_count++; end
            cart_bank_idx = 4'hF;  do_read_a(16'hA100, got);
            if (got !== 8'hAF) begin $display("[F/F] FAIL got=$%02h expected=$AF", got); fail_count++; end
            // Cart disabled → main RAM at $A100 still has $11.
            cart_en = 1'b0;
            do_read_a(16'hA100, got);
            if (got !== 8'h11) begin $display("[F/main] FAIL got=$%02h expected=$11", got); fail_count++; end
            $display("[bank/F] 8 KB cart, 4 distinct banks + main partition OK");
        end

        // ===== Phase G — 16 KB cart at $8000-$BFFF =======================
        // The 16 KB window covers BOTH halves ($8000-$9FFF and
        // $A000-$BFFF) of one bank. Write to two offsets in the same
        // bank, then verify both reads return the right values.
        portb = 8'hFF;
        cart_size_16k = 1'b1;
        cart_en       = 1'b1;
        cart_bank_idx = 4'h3;
        do_write(16'h8200, 8'h82);
        repeat (LATENCY+4) @(posedge clk);
        do_write(16'hA200, 8'hA2);
        repeat (LATENCY+4) @(posedge clk);
        // Switch to bank 7 and write distinct values.
        cart_bank_idx = 4'h7;
        do_write(16'h8200, 8'h87);
        repeat (LATENCY+4) @(posedge clk);
        do_write(16'hA200, 8'hA7);
        repeat (LATENCY+4) @(posedge clk);
        begin : phase_g
            logic [7:0] got;
            cart_bank_idx = 4'h3;
            do_read_a(16'h8200, got);
            if (got !== 8'h82) begin $display("[G/3a] FAIL got=$%02h expected=$82", got); fail_count++; end
            do_read_a(16'hA200, got);
            if (got !== 8'hA2) begin $display("[G/3b] FAIL got=$%02h expected=$A2", got); fail_count++; end
            cart_bank_idx = 4'h7;
            do_read_a(16'h8200, got);
            if (got !== 8'h87) begin $display("[G/7a] FAIL got=$%02h expected=$87", got); fail_count++; end
            do_read_a(16'hA200, got);
            if (got !== 8'hA7) begin $display("[G/7b] FAIL got=$%02h expected=$A7", got); fail_count++; end
            $display("[bank/G] 16 KB cart, 2 banks × 2 halves no aliasing OK");
        end

        // Tear down cart for any future phases.
        cart_en = 1'b0;

        if (fail_count == 0) begin
            $display("*** BANK OK *** PORTB[4]/[5] partition + bank idx + 8K/16K cart partitioning");
            $finish;
        end else begin
            $display("*** BANK FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_bank watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
