// tb_bank_xlat.sv — bank translator unit test (code + data window).
//
// Checks both window decodes ($6000-$9FFF code window, $A000-$CFFF data
// window), the page-id composition ($0082 / $0083), and the in-window
// offset.

`timescale 1ns / 1ps

module tb_bank_xlat;

    logic [7:0]  cpu_code_bank;
    logic [7:0]  cpu_data_bank;
    logic [15:0] cpu_addr;
    wire         is_in_window;
    wire         is_code;
    wire [13:0]  offset_in_block;
    wire [15:0]  bank_id;

    bank_xlat u_dut (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank      (cpu_data_bank),
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
        $display("=== bank_xlat (code window only) ===");

        cpu_code_bank = 8'h05;
        cpu_data_bank = 8'h11;
        #1;

        // ---- A. window decode -----------------------------------------
        // $6000-$9FFF = code window, $A000-$CFFF = data window.
        // Everything else is unbanked.
        $display("[A] window decode");
        cpu_addr = 16'h4000; #1; expect_eq("A.1 screen $4000 not banked",  is_in_window, 1'b0);
        cpu_addr = 16'h5FFF; #1; expect_eq("A.2 screen $5FFF not banked",  is_in_window, 1'b0);
        cpu_addr = 16'h6000; #1; expect_eq("A.3 code $6000 in window",     is_in_window, 1'b1);
        cpu_addr = 16'h6000; #1; expect_eq("A.3b code $6000 is_code",      is_code,      1'b1);
        cpu_addr = 16'h9FFF; #1; expect_eq("A.4 code $9FFF in window",     is_in_window, 1'b1);
        cpu_addr = 16'h9FFF; #1; expect_eq("A.4b code $9FFF is_code",      is_code,      1'b1);
        cpu_addr = 16'hA000; #1; expect_eq("A.5 data $A000 in window",     is_in_window, 1'b1);
        cpu_addr = 16'hA000; #1; expect_eq("A.5b $A000 is_code=0",         is_code,      1'b0);
        cpu_addr = 16'hCFFF; #1; expect_eq("A.6 data $CFFF in window",     is_in_window, 1'b1);
        cpu_addr = 16'hCFFF; #1; expect_eq("A.6b $CFFF is_code=0",         is_code,      1'b0);
        cpu_addr = 16'hD000; #1; expect_eq("A.7 $D000 not banked",         is_in_window, 1'b0);
        cpu_addr = 16'h3FFF; #1; expect_eq("A.8 $3FFF not banked",         is_in_window, 1'b0);

        // ---- B. page-id: code=$0082, data=$0083 -----------------------
        $display("[B] page-id");
        cpu_addr = 16'h6800; #1; expect_eq("B.1 code bank_id", bank_id, 16'h0005);
        cpu_addr = 16'h9000; #1; expect_eq("B.2 code bank_id", bank_id, 16'h0005);
        cpu_addr = 16'hA800; #1; expect_eq("B.3 data bank_id", bank_id, 16'h0011);  // data_bank
        cpu_addr = 16'hC400; #1; expect_eq("B.4 data bank_id", bank_id, 16'h0011);  // data_bank

        // ---- C. offset_in_block (meaningful only in window) ----------
        $display("[C] offset_in_block");
        cpu_addr = 16'h6000; #1; expect_eq("C.1 code off 0",     offset_in_block, 14'h0000);
        cpu_addr = 16'h6123; #1; expect_eq("C.2 code off $123",  offset_in_block, 14'h0123);
        cpu_addr = 16'h9FFF; #1; expect_eq("C.3 code off $3FFF", offset_in_block, 14'h3FFF);
        cpu_addr = 16'hA000; #1; expect_eq("C.4 data off 0",     offset_in_block, 14'h0000);
        cpu_addr = 16'hA456; #1; expect_eq("C.5 data off $456",  offset_in_block, 14'h0456);
        cpu_addr = 16'hCFFF; #1; expect_eq("C.6 data off $2FFF", offset_in_block, 14'h2FFF);
        // Unbanked addresses: offset_in_block is a don't-care (never used
        // when is_in_window=0). The output is cpu_addr-$6000 truncated to
        // 14 bits, tested here as documentation only.

        // ---- D. bank 0 = BRAM (is_in_window deasserts) ----------------
        // Bank index 0 of each window lives in the flat BRAM, not DDR3,
        // so is_in_window must be 0 even for in-range addresses. Only a
        // non-zero bank selects a DDR3-backed page.
        $display("[D] bank-0 gating");
        cpu_code_bank = 8'h00; cpu_data_bank = 8'h00; #1;
        cpu_addr = 16'h6000; #1; expect_eq("D.1 code $6000 bank0 -> BRAM", is_in_window, 1'b0);
        cpu_addr = 16'h9FFF; #1; expect_eq("D.2 code $9FFF bank0 -> BRAM", is_in_window, 1'b0);
        cpu_addr = 16'hA000; #1; expect_eq("D.3 data $A000 bank0 -> BRAM", is_in_window, 1'b0);
        cpu_addr = 16'hCFFF; #1; expect_eq("D.4 data $CFFF bank0 -> BRAM", is_in_window, 1'b0);

        // Mixed: code banked (non-zero), data on bank 0.
        cpu_code_bank = 8'h07; cpu_data_bank = 8'h00; #1;
        cpu_addr = 16'h6000; #1; expect_eq("D.5 code bank7 in window",  is_in_window, 1'b1);
        cpu_addr = 16'h6000; #1; expect_eq("D.5b code bank7 bank_id",   bank_id,      16'h0007);
        cpu_addr = 16'hA000; #1; expect_eq("D.6 data bank0 -> BRAM",    is_in_window, 1'b0);

        // Mixed: data banked (non-zero), code on bank 0.
        cpu_code_bank = 8'h00; cpu_data_bank = 8'h09; #1;
        cpu_addr = 16'h6000; #1; expect_eq("D.7 code bank0 -> BRAM",    is_in_window, 1'b0);
        cpu_addr = 16'hA000; #1; expect_eq("D.8 data bank9 in window",  is_in_window, 1'b1);
        cpu_addr = 16'hA000; #1; expect_eq("D.8b data bank9 bank_id",   bank_id,      16'h0009);

        if (fail_count == 0) begin
            $display("*** BANK_XLAT OK *** window decode + page-id + offset");
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
