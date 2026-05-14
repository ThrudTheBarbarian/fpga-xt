// bank_xlat.sv — bank-id translator for the $4000-$7FFF window (M24-4).
//
// Combinational module: given a CPU address + the active bank-select
// state for both the CPU and the ANTIC views, plus a "who's asking"
// flag, produce a 16-bit `bank_id` that uniquely tags the 4 KB block
// being requested. Downstream consumer is bank_cache.sv.
//
// Bank-select model — XT 3-way split + XE flat 16K:
//
//   Address     Region              Selector (CPU view)    Selector (ANTIC view)
//   ----------  ------------------  ---------------------  ----------------------
//   $4000-$4FFF  Code half 0 (4 K)  $0082 (low half)       ANTIC_CODE_BANK[low]
//   $5000-$5FFF  Code half 1 (4 K)  $0082 (high half)      ANTIC_CODE_BANK[high]
//   $6000-$6FFF  Data       (4 K)   $0083                  ANTIC_DATA_BANK
//   $7000-$7FFF  Region-C   (4 K)   $0084 / $0085          ANTIC_REGC_BANK_LO/HI
//
// For XE flat 16K, software fans the same PORTB-derived bank into all
// four selectors so each 4 KB block sees the same bank_id.
//
// bank_id encoding — uses high bits as a "region tag" so banks from
// different regions never collide in the cache:
//
//   bank_id[15:14]  Region tag (00=code lo, 01=code hi, 10=data, 11=regc)
//   bank_id[13:0]   Sub-bank within that region
//
// This gives 4 × 16384 = 65536 distinct bank ids — plenty.

`default_nettype none

module bank_xlat (
    // CPU's view (latched from zero-page $0082-$0085 by sally_mem).
    input  wire [7:0]  cpu_code_bank,    // $0082
    input  wire [7:0]  cpu_data_bank,    // $0083
    input  wire [7:0]  cpu_regc_bank_lo, // $0084
    input  wire [7:0]  cpu_regc_bank_hi, // $0085

    // ANTIC's view (latched from $D488-$D48A by antic_regs).
    input  wire [7:0]  antic_code_bank,
    input  wire [7:0]  antic_data_bank,
    input  wire [7:0]  antic_regc_bank_lo,
    input  wire [7:0]  antic_regc_bank_hi,

    // Lookup inputs.
    input  wire [15:0] cpu_addr,
    input  wire        view_is_antic,    // 0 = CPU view, 1 = ANTIC view

    // Outputs.
    output wire        is_in_window,     // 1 if cpu_addr ∈ $4000-$7FFF
    output wire [11:0] offset_in_block,  // cpu_addr[11:0] (4 KB offset)
    output logic [15:0] bank_id
);

    assign is_in_window    = (cpu_addr[15:14] == 2'b01);
    assign offset_in_block = cpu_addr[11:0];

    // Sub-block within $4000-$7FFF: cpu_addr[13:12]
    //   00 → $4000-$4FFF (code lo)
    //   01 → $5000-$5FFF (code hi)
    //   10 → $6000-$6FFF (data)
    //   11 → $7000-$7FFF (region-C)
    wire [1:0] sub_block = cpu_addr[13:12];

    // Pick selectors per view.
    wire [7:0] code_bank      = view_is_antic ? antic_code_bank      : cpu_code_bank;
    wire [7:0] data_bank      = view_is_antic ? antic_data_bank      : cpu_data_bank;
    wire [7:0] regc_bank_lo   = view_is_antic ? antic_regc_bank_lo   : cpu_regc_bank_lo;
    wire [7:0] regc_bank_hi   = view_is_antic ? antic_regc_bank_hi   : cpu_regc_bank_hi;

    // Compose bank_id.
    always_comb begin
        case (sub_block)
            2'b00: bank_id = {2'b00, 6'b0, code_bank};                // code lo
            2'b01: bank_id = {2'b01, 6'b0, code_bank};                // code hi
            2'b10: bank_id = {2'b10, 6'b0, data_bank};                // data
            2'b11: bank_id = {2'b11, regc_bank_hi[5:0], regc_bank_lo}; // region-C (14-bit composite)
        endcase
    end

endmodule

`default_nettype wire
