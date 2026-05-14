// tb_bank_xlat.sv — M24-4 bank translator unit test.
//
// Demonstrates that bank_xlat produces distinct bank_ids for the
// CPU view and the ANTIC view when their bank-select state differs,
// and identical bank_ids when they match. The headline guarantee:
// at the same cpu_addr, switching view_is_antic gives a different
// bank_id whenever the corresponding selector differs.

`timescale 1ns / 1ps

module tb_bank_xlat;

    logic [7:0]  cpu_code_bank;
    logic [7:0]  cpu_data_bank;
    logic [7:0]  cpu_regc_bank_lo, cpu_regc_bank_hi;
    logic [7:0]  antic_code_bank;
    logic [7:0]  antic_data_bank;
    logic [7:0]  antic_regc_bank_lo, antic_regc_bank_hi;
    logic [15:0] cpu_addr;
    logic        view_is_antic;
    wire         is_in_window;
    wire [11:0]  offset_in_block;
    wire [15:0]  bank_id;

    bank_xlat u_dut (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank      (cpu_data_bank),
        .cpu_regc_bank_lo   (cpu_regc_bank_lo),
        .cpu_regc_bank_hi   (cpu_regc_bank_hi),
        .antic_code_bank    (antic_code_bank),
        .antic_data_bank    (antic_data_bank),
        .antic_regc_bank_lo (antic_regc_bank_lo),
        .antic_regc_bank_hi (antic_regc_bank_hi),
        .cpu_addr           (cpu_addr),
        .view_is_antic      (view_is_antic),
        .is_in_window       (is_in_window),
        .offset_in_block    (offset_in_block),
        .bank_id            (bank_id)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    initial begin
        $display("=== M24-4 bank_xlat ===");

        // Set up distinct CPU vs ANTIC banks for each region.
        cpu_code_bank      = 8'h05;     antic_code_bank      = 8'h0A;
        cpu_data_bank      = 8'h11;     antic_data_bank      = 8'h22;
        cpu_regc_bank_lo   = 8'h33;     antic_regc_bank_lo   = 8'h66;
        cpu_regc_bank_hi   = 8'h00;     antic_regc_bank_hi   = 8'h00;
        #1;

        // ---- A. is_in_window decoder ----------------------------------
        $display("[A] is_in_window decoder");
        cpu_addr = 16'h3FFF;
        view_is_antic = 1'b0;
        #1; expect_eq("A.1 not in window @ $3FFF", is_in_window, 1'b0);
        cpu_addr = 16'h4000;
        #1; expect_eq("A.2 in window @ $4000", is_in_window, 1'b1);
        cpu_addr = 16'h7FFF;
        #1; expect_eq("A.3 in window @ $7FFF", is_in_window, 1'b1);
        cpu_addr = 16'h8000;
        #1; expect_eq("A.4 not in window @ $8000", is_in_window, 1'b0);

        // ---- B. CPU view picks CPU bank-select state ------------------
        $display("[B] CPU view encodes CPU selectors");
        view_is_antic = 1'b0;
        cpu_addr = 16'h4500;     // code lo region
        #1; expect_eq("B.1 cpu code lo bank_id", bank_id, 16'h0005);  // {2'b00, 6'b0, $05}
        cpu_addr = 16'h5500;     // code hi region
        #1; expect_eq("B.2 cpu code hi bank_id", bank_id, 16'h4005);  // {2'b01, 6'b0, $05}
        cpu_addr = 16'h6800;     // data region
        #1; expect_eq("B.3 cpu data bank_id",    bank_id, 16'h8011);  // {2'b10, 6'b0, $11}
        cpu_addr = 16'h7100;     // regc region
        #1; expect_eq("B.4 cpu regc bank_id",    bank_id, 16'hC033);  // {2'b11, 6'b0, $33}

        // ---- C. ANTIC view picks ANTIC bank-select state --------------
        $display("[C] ANTIC view encodes ANTIC selectors");
        view_is_antic = 1'b1;
        cpu_addr = 16'h4500;
        #1; expect_eq("C.1 antic code lo bank_id", bank_id, 16'h000A);
        cpu_addr = 16'h5500;
        #1; expect_eq("C.2 antic code hi bank_id", bank_id, 16'h400A);
        cpu_addr = 16'h6800;
        #1; expect_eq("C.3 antic data bank_id",    bank_id, 16'h8022);
        cpu_addr = 16'h7100;
        #1; expect_eq("C.4 antic regc bank_id",    bank_id, 16'hC066);

        // ---- D. Dual-view divergence at same address ------------------
        // Headline test: at $4500 with CPU code = $05 vs ANTIC code = $0A,
        // the bank_id differs by exactly the (5 ^ A) low byte → caches
        // store independent banks for each view.
        $display("[D] dual-view divergence at $4500");
        begin
            logic [15:0] cpu_id, antic_id;
            cpu_addr = 16'h4500;
            view_is_antic = 1'b0;
            #1; cpu_id = bank_id;
            view_is_antic = 1'b1;
            #1; antic_id = bank_id;
            $display("[D] $4500: cpu_id=$%04h antic_id=$%04h", cpu_id, antic_id);
            if (cpu_id == antic_id) begin
                $display("FAIL D: views collapsed to same bank_id");
                fail_count++;
            end
        end

        // ---- E. Identical selectors → identical bank_ids --------------
        // Software that doesn't enable dual-view sets all ANTIC bank
        // registers to 0 (boot default). With CPU bank state also 0,
        // both views give identical bank_ids and the cache treats them
        // as one bank.
        $display("[E] matching selectors → same bank_id");
        cpu_code_bank      = 8'h00; antic_code_bank      = 8'h00;
        cpu_data_bank      = 8'h00; antic_data_bank      = 8'h00;
        cpu_regc_bank_lo   = 8'h00; antic_regc_bank_lo   = 8'h00;
        cpu_regc_bank_hi   = 8'h00; antic_regc_bank_hi   = 8'h00;
        cpu_addr = 16'h4500;
        view_is_antic = 1'b0;
        #1; begin
            logic [15:0] cpu_id;
            cpu_id = bank_id;
            view_is_antic = 1'b1;
            #1;
            expect_eq("E.matching banks", bank_id, cpu_id);
        end

        // ---- F. offset_in_block extraction ----------------------------
        $display("[F] offset_in_block extraction");
        cpu_addr = 16'h47A5;
        #1; expect_eq("F offset", offset_in_block, 12'h7A5);

        if (fail_count == 0) begin
            $display("*** BANK_XLAT OK *** in_window + cpu_view + antic_view + dual-view divergence");
            $finish;
        end else begin
            $display("*** BANK_XLAT FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #100_000;
        $display("FAIL: tb_bank_xlat watchdog");
        $fatal(1);
    end

endmodule
