// tb_bank_xlat.sv — bank translator unit test (xtc window scheme).
//
// Checks the window decode ($6000-$9FFF code, $A000-$CFFF data, with
// $4000-$5FFF screen and everything else unbanked), the code/data page-id
// composition ($82 vs {$84,$83}), and the in-window offset.

`timescale 1ns / 1ps

module tb_bank_xlat;

    logic [7:0]  cpu_code_bank;
    logic [7:0]  cpu_data_bank_lo, cpu_data_bank_hi;
    logic [15:0] cpu_addr;
    wire         is_in_window;
    wire         is_code;
    wire [13:0]  offset_in_block;
    wire [15:0]  bank_id;

    bank_xlat u_dut (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank_lo   (cpu_data_bank_lo),
        .cpu_data_bank_hi   (cpu_data_bank_hi),
        .cpu_addr           (cpu_addr),
        .is_in_window       (is_in_window),
        .is_code            (is_code),
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
        $display("=== bank_xlat (xtc window scheme) ===");

        cpu_code_bank    = 8'h05;
        cpu_data_bank_lo = 8'h11;
        cpu_data_bank_hi = 8'h22;
        #1;

        // ---- A. window decode -----------------------------------------
        $display("[A] window decode");
        cpu_addr = 16'h4000; #1; expect_eq("A.1 screen $4000 not banked",  is_in_window, 1'b0);
        cpu_addr = 16'h5FFF; #1; expect_eq("A.2 screen $5FFF not banked",  is_in_window, 1'b0);
        cpu_addr = 16'h6000; #1; expect_eq("A.3 code $6000 in window",     is_in_window, 1'b1);
        cpu_addr = 16'h6000; #1; expect_eq("A.3b code $6000 is_code",      is_code,      1'b1);
        cpu_addr = 16'h9FFF; #1; expect_eq("A.4 code $9FFF in window",     is_in_window, 1'b1);
        cpu_addr = 16'h9FFF; #1; expect_eq("A.4b code $9FFF is_code",      is_code,      1'b1);
        cpu_addr = 16'hA000; #1; expect_eq("A.5 data $A000 in window",     is_in_window, 1'b1);
        cpu_addr = 16'hA000; #1; expect_eq("A.5b data $A000 !is_code",     is_code,      1'b0);
        cpu_addr = 16'hCFFF; #1; expect_eq("A.6 data $CFFF in window",     is_in_window, 1'b1);
        cpu_addr = 16'hD000; #1; expect_eq("A.7 $D000 not banked",         is_in_window, 1'b0);
        cpu_addr = 16'h3FFF; #1; expect_eq("A.8 $3FFF not banked",         is_in_window, 1'b0);

        // ---- B. code page-id = $82 ($6000-$9FFF) ----------------------
        $display("[B] code page-id");
        cpu_addr = 16'h6800; #1; expect_eq("B.1 code bank_id", bank_id, 16'h0005);
        cpu_addr = 16'h9000; #1; expect_eq("B.2 code bank_id", bank_id, 16'h0005);

        // ---- C. data page-id = {$84,$83} ($A000-$CFFF) ----------------
        $display("[C] data page-id");
        cpu_addr = 16'hA800; #1; expect_eq("C.1 data bank_id", bank_id, 16'h2211);
        cpu_addr = 16'hC400; #1; expect_eq("C.2 data bank_id", bank_id, 16'h2211);

        // ---- D. offset within the active page -------------------------
        $display("[D] offset_in_block");
        cpu_addr = 16'h6000; #1; expect_eq("D.1 code off 0",     offset_in_block, 14'h0000);
        cpu_addr = 16'h6123; #1; expect_eq("D.2 code off $123",  offset_in_block, 14'h0123);
        cpu_addr = 16'h9FFF; #1; expect_eq("D.3 code off $3FFF", offset_in_block, 14'h3FFF);
        cpu_addr = 16'hA000; #1; expect_eq("D.4 data off 0",     offset_in_block, 14'h0000);
        cpu_addr = 16'hCFFF; #1; expect_eq("D.5 data off $2FFF", offset_in_block, 14'h2FFF);

        if (fail_count == 0) begin
            $display("*** BANK_XLAT OK *** window decode + code/data page-id + offset");
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
