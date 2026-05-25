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
// ROM regions $A000-$BFFF (BASIC), $C000-$CFFF (OS low), and
// $D800-$FFFF (OS high) overlap the data window and unbanked BRAM.
// PORTB ($D301) selects whether ROM or the banked/BRAM backing is
// visible — see sally_mem for the override logic.
//
// bank_id carries only the page index; the caller uses `is_code` to pick
// the DDR3 base + page stride (16 KB vs 12 KB) when composing the address.
//
// Bank 0 = BRAM (boot-to-BASIC blocker #1, prompts/task-0001):
//   Bank index 0 of each window lives in the flat 64 KB BRAM, NOT DDR3.
//   Only a non-zero bank ($0082 code / $0083 data) selects a DDR3-backed
//   page.  This keeps the legacy machine's $6000-$9FFF as ordinary
//   writable RAM (OS RAM-sizing, GR.0 screen/display list ~$9C00) and
//   coherent with ANTIC, which reads that same BRAM via its DMA port.
//   is_in_window therefore deasserts on bank 0, so sally_mem routes the
//   access through its BRAM read/write path instead of the page cache.

`default_nettype none

module bank_xlat (
    // CPU bank-select registers (latched from zero-page by sally_mem).
    input  wire [7:0]  cpu_code_bank,    // $0082
    input  wire [7:0]  cpu_data_bank,    // $0083

    input  wire [15:0] cpu_addr,

    output wire        is_in_window,     // 1 if cpu_addr ∈ $6000-$CFFF AND bank != 0
    output wire        is_code,          // 1 = code window, 0 = data window
    output wire [13:0] offset_in_block,  // byte offset within the active page
    output wire [15:0] bank_id           // page index (zero-extended 8-bit)
);

    wire in_code = (cpu_addr >= 16'h6000) && (cpu_addr <= 16'h9FFF);
    wire in_data = (cpu_addr >= 16'hA000) && (cpu_addr <= 16'hCFFF);

    // A window is DDR3-backed only when its selected bank index is non-zero.
    wire code_banked = in_code & (cpu_code_bank != 8'h00);
    wire data_banked = in_data & (cpu_data_bank != 8'h00);

    assign is_in_window    = code_banked | data_banked;
    assign is_code         = in_code;   // window identity (independent of bank)
    assign offset_in_block = in_code ? (cpu_addr - 16'h6000)
                                     : (cpu_addr - 16'hA000);
    assign bank_id         = in_code ? {8'h00, cpu_code_bank}
                                     : {8'h00, cpu_data_bank};

endmodule

`default_nettype wire
