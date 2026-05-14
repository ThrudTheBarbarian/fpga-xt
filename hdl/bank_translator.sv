// bank_translator.sv — combinational logical-to-physical address
// translator for Atari memory banking. Handles two independent
// banking schemes that share an address range with main RAM:
//
//   1. 130XE PORTB ($D301) banking. Bits 4 / 5 control whether the
//      $4000-$7FFF window for the CPU / ANTIC respectively maps to
//      the selected extended bank or to main RAM. Bits 3:2 are the
//      bank index (0..3, 16 KB each).
//
//   2. Cartridge ROM/RAM banking. Two flavours selected by
//      `cart_size_16k`:
//        size = 0 — 8 KB cart visible at $A000-$BFFF, banked into
//                   one of 16 physical 8 KB banks (cart_idx[3:0]).
//        size = 1 — 16 KB cart visible at $8000-$BFFF, banked into
//                   one of 16 physical 16 KB banks. Used by the
//                   "big cart" / Bounty Bob / OSS / Atarimax
//                   schemes — the bank-control register that drives
//                   `cart_idx` is cart-specific (typically a write
//                   to a magic address in the $D500 page).
//
// PORTB and cart windows don't overlap, so a single translator
// instance handles both. The two banking systems are also
// independent of one another — the caller can have either, both,
// or neither active for a given access.
//
// Physical layout (starting at 0):
//   $00000-$0FFFF  main RAM (64 KB Atari address space)
//   $10000-$1FFFF  130XE extended banks (4 × 16 KB)
//   $20000-$5FFFF  cartridge banks (up to 16 × 16 KB = 256 KB)

`default_nettype none

module bank_translator #(
    parameter int LOG_ADDR_W  = 16,
    parameter int PHYS_ADDR_W = 24
) (
    input  wire  [LOG_ADDR_W-1:0]  logical_addr,

    // 130XE PORTB banking.
    input  wire                    portb_bank_en,
    input  wire  [1:0]             portb_bank_idx,

    // Cartridge banking.
    input  wire                    cart_en,
    input  wire  [3:0]             cart_bank_idx,
    input  wire                    cart_size_16k,    // 0 = 8K @ $A000, 1 = 16K @ $8000

    output logic [PHYS_ADDR_W-1:0] physical_addr
);

    wire portb_win    = (logical_addr[15:14] == 2'b01);             // $4000-$7FFF
    wire cart_win_8k  = (logical_addr[15:13] == 3'b101);            // $A000-$BFFF
    wire cart_win_16k = (logical_addr[15:14] == 2'b10);             // $8000-$BFFF

    // Constants for the physical-region bases (parameterised width).
    localparam logic [PHYS_ADDR_W-1:0] PORTB_BANK_BASE = 'h010000;  // 64 KB main → first extended bank
    localparam logic [PHYS_ADDR_W-1:0] CART_BANK_BASE  = 'h020000;  // past extended-bank region

    always_comb begin
        if (portb_bank_en && portb_win) begin
            // 130XE bank: base + idx * 16 KB + offset[13:0]
            physical_addr = PORTB_BANK_BASE
                          + ({{(PHYS_ADDR_W-16){1'b0}}, portb_bank_idx, 14'h0})
                          + {{(PHYS_ADDR_W-14){1'b0}}, logical_addr[13:0]};
        end else if (cart_en && cart_size_16k && cart_win_16k) begin
            // 16 KB cart bank: base + idx * 16 KB + offset[13:0]
            physical_addr = CART_BANK_BASE
                          + ({{(PHYS_ADDR_W-18){1'b0}}, cart_bank_idx, 14'h0})
                          + {{(PHYS_ADDR_W-14){1'b0}}, logical_addr[13:0]};
        end else if (cart_en && !cart_size_16k && cart_win_8k) begin
            // 8 KB cart bank: base + idx * 8 KB + offset[12:0]
            physical_addr = CART_BANK_BASE
                          + ({{(PHYS_ADDR_W-17){1'b0}}, cart_bank_idx, 13'h0})
                          + {{(PHYS_ADDR_W-13){1'b0}}, logical_addr[12:0]};
        end else begin
            // Pass-through to main 64 KB.
            physical_addr = {{(PHYS_ADDR_W-LOG_ADDR_W){1'b0}},
                             logical_addr};
        end
    end

endmodule

`default_nettype wire
