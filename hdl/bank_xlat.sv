// bank_xlat.sv — bank-id translator for the xtc banked windows.
//
// Combinational: given a CPU address + the active bank-select registers
// (zero-page $0082-$0083, snooped by sally_mem), produce the bank_id +
// in-window offset that identify the DDR3-backed page being addressed.
//
// xtc memory model (CPU view only — ANTIC has no banking and reads the
// flat 64 KB BRAM directly):
//
//   Address      Region        Backing            Selector
//   -----------  ------------  -----------------  --------------------------
//   $4000-$5FFF  Screen RAM    flat 64 KB BRAM    — (fixed, not banked)
//   $6000-$9FFF  Code window   DDR3 banked page   $0082            (16 KB pages)
//   $A000-$CFFF  Data window   DDR3 banked page   $0083            (12 KB pages)
//   else         Unbanked      flat 64 KB BRAM    —
//
//   • Code window: $0082 is an 8-bit page index → 256 pages of 16 KB.
//   • Data window: $0083 is an 8-bit page index → 256 pages of 12 KB.
//   • $0084 (atomic task switch) writes the lower 4 bits to BOTH
//     $0082 and $0083 (bits [7:4] forced to 0), redirecting both
//     windows in a single cycle — limits to 16 tasks.
//
// bank_id carries only the page index; the caller uses `is_code` to pick
// the DDR3 base + page stride (16 KB vs 12 KB) when composing the address.

`default_nettype none

module bank_xlat (
    // CPU bank-select registers (latched from zero-page by sally_mem).
    input  wire [7:0]  cpu_code_bank,    // $0082
    input  wire [7:0]  cpu_data_bank,    // $0083

    input  wire [15:0] cpu_addr,

    output wire        is_in_window,     // 1 if cpu_addr ∈ $6000-$CFFF
    output wire        is_code,          // 1 = code window, 0 = data window
    output wire [13:0] offset_in_block,  // byte offset within the active page
    output wire [15:0] bank_id           // page index (zero-extended 8-bit)
);

    wire in_code = (cpu_addr >= 16'h6000) && (cpu_addr <= 16'h9FFF);
    wire in_data = (cpu_addr >= 16'hA000) && (cpu_addr <= 16'hCFFF);

    assign is_in_window    = in_code | in_data;
    assign is_code         = in_code;
    assign offset_in_block = in_code ? (cpu_addr - 16'h6000)
                                     : (cpu_addr - 16'hA000);
    assign bank_id         = in_code ? {8'h00, cpu_code_bank}
                                     : {8'h00, cpu_data_bank};

endmodule

`default_nettype wire
