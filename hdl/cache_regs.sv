// cache_regs.sv — M-cache-rework Step 1.
//
// Owns the $D380-$D3FF PIA-mirror window register file used by xtc-aware
// software to control the bank cache, and the per-bank attribute SRAM
// looked up on the cache miss path.
//
// Register map (per docs/Issues.md `M-cache-rework`):
//
//   $D380 CACHE_CTL          bit 0 = ENABLE_PARTITION (R/W)
//   $D381 CACHE_CODE_LINES   lines reserved for code partition (R/W, default 24)
//   $D382 BANK_ATTR_REGION   0=A ($82), 1=B ($83/$84/$85), 2=C (16-bit) (R/W)
//   $D383 BANK_ATTR_ID_LO    bank id low byte (R/W)
//   $D384 BANK_ATTR_ID_HI    bank id high byte (region C only, R/W)
//   $D385 BANK_ATTR_DATA     attribute bits at composed bank address.
//                              Write: stores low 4 bits at attr_addr_q.
//                              Read:  returns SRAM data at attr_addr_q.
//   $D386 CURRENT_TASK_ID    OS writes on context switch (4 bits, reserved)
//   $D387 CACHE_FLUSH        write-any-value triggers cache_flush_pulse
//   $D388-$D3FF              reserved (read $00, writes ignored)
//
// The PIA itself still sees these writes (we share the bus); xtc-compiled
// software is expected to use $D300-$D303 for actual PIA peripheral
// access, never the mirrors.
//
// Attribute SRAM:
//   Address composition: {region[1:0], bank_id_hi[1:0], bank_id_lo[7:0]}
//     Region A (region==00): bank_id_hi unused, 256 entries used
//     Region B (region==01): bank_id_hi unused, 256 entries used
//     Region C (region==10): full 10 bits of bank-id (1024 entries)
//   Total addressable: 4096 entries × 4 bits = 16 kbit (~2 EFX_RAM10).
//   Bit assignments per xtc/doc/large-allocations.md (4 bits per bank):
//     bit 0 — reserved (must be 0)
//     bit 1 — code-affinity hint
//     bit 2 — streaming (BANK_ATTR_STREAM — bypass cache)
//     bit 3 — spare
//
// Read latency for $D385 is 1 cycle (synchronous BRAM read off attr_addr_q).
// Software writing $D382/$D383/$D384 then reading $D385 will see the
// settled SRAM value because $D385 read decode races against the
// pre-registered attr_addr_q. The write port is registered through
// bus_snoop (1-cycle delay) which gives the SRAM another full cycle —
// software always sees a stable read.
//
// At Step 1 the cache itself doesn't yet consume any of these outputs;
// they exist so xtc can build against `bankAttrSet` / `bankAttrGet`
// builtins immediately. Steps 2-5 (`docs/Issues.md`) wire them in.

`default_nettype none

module cache_regs #(
    parameter int unsigned ATTR_ADDR_W = 12,                  // 4096 banks
    parameter int unsigned ATTR_DATA_W = 4,                   // 4 bits/bank
    parameter int unsigned ATTR_DEPTH  = (1 << ATTR_ADDR_W),
    parameter logic [7:0]  CODE_LINES_DEFAULT = 8'd32
) (
    input  wire        clk,
    input  wire        rst,

    // Write port (registered from bus_snoop).
    input  wire        we,                 // snoop_we_cache
    input  wire [15:0] waddr,              // snoop_addr (full 16 bits — only [6:0] meaningful)
    input  wire [7:0]  wdata,

    // Read port (combinational off live SALLY hwreg address).
    input  wire [15:0] raddr,
    output logic [7:0] rdata,

    // Outputs to bank_cache (consumed in later steps; left dangling at
    // Step 1 so synth elides them safely).
    output logic       enable_partition_q, // $D380 bit 0
    output logic [7:0] code_lines_q,       // $D381
    output logic [3:0] current_task_q,     // $D386 (reserved)
    output logic       flush_pulse,        // 1-cycle pulse on $D387 write

    // Attribute SRAM lookup port — used by bank_cache miss path
    // (Step 4). Always-on read; address externally driven.
    input  wire [ATTR_ADDR_W-1:0]  attr_lookup_idx,
    output wire [ATTR_DATA_W-1:0]  attr_lookup_data
);

    // ---- Address decode ---------------------------------------------
    // Window: $D380-$D3FF (128 bytes). Within: low 7 bits of address.
    localparam logic [8:0] WIN_PREFIX = 9'b1101_0011_1;  // $D380-$D3FF
    wire write_in_win = we && (waddr[15:7] == WIN_PREFIX);
    wire read_in_win  = (raddr[15:7] == WIN_PREFIX);
    wire [6:0] wreg = waddr[6:0];
    wire [6:0] rreg = raddr[6:0];

    // ---- Indirect-bank-select scratch state -------------------------
    // Updated on writes to $D382 / $D383 / $D384. attr_addr_q is the
    // SRAM read/write index; rebuilt every time one of the three feeders
    // changes so $D385 access targets the right bank.
    logic [1:0] region_q;
    logic [1:0] bank_id_hi_q;
    logic [7:0] bank_id_lo_q;

    wire [ATTR_ADDR_W-1:0] attr_addr_q = {region_q, bank_id_hi_q, bank_id_lo_q};

    // ---- Register storage -------------------------------------------
    // Defaults: code_lines = 32 = current 32/32 partition split
    // (M-cache-rework Step 3). enable_partition starts at 0 so software
    // explicitly opts in; today's cache routes by bank_xlat region tag
    // regardless, so the bit is informational at present.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            enable_partition_q <= 1'b0;
            code_lines_q       <= CODE_LINES_DEFAULT;
            region_q           <= 2'b00;
            bank_id_hi_q       <= 2'b00;
            bank_id_lo_q       <= 8'h00;
            current_task_q     <= 4'h0;
            flush_pulse        <= 1'b0;
        end else begin
            // flush_pulse defaults to 0 each cycle; written-to-$D387
            // re-asserts it for one cycle.
            flush_pulse <= 1'b0;

            if (write_in_win) begin
                unique case (wreg)
                    7'h00: enable_partition_q <= wdata[0];                 // $D380
                    7'h01: code_lines_q       <= wdata;                    // $D381
                    7'h02: region_q           <= wdata[1:0];               // $D382
                    7'h03: bank_id_lo_q       <= wdata;                    // $D383
                    7'h04: bank_id_hi_q       <= wdata[1:0];               // $D384
                    // 7'h05: $D385 — handled in attr SRAM block below.
                    7'h06: current_task_q     <= wdata[3:0];               // $D386
                    7'h07: flush_pulse        <= 1'b1;                     // $D387
                    default: ;  // $D388-$D3FF reserved — ignore
                endcase
            end
        end
    end

    // ---- Attribute SRAM ---------------------------------------------
    // Two-port: port A serves the cache miss-path lookup (always-on read
    // at attr_lookup_idx); port B serves the software access at
    // attr_addr_q (read for $D385, write on $D385 write).
    //
    // Synplify maps `(* syn_ramstyle = "block_ram" *)` 1R+1W per port to
    // EFX_DPRAM10 with byte/nibble-wide data. With 4 bits × 4096 entries
    // this draws ~2 EFX_RAM10 blocks.

    (* syn_ramstyle = "block_ram" *)
    logic [ATTR_DATA_W-1:0] attr_mem [0:ATTR_DEPTH-1];

    // Default attribute = $0 (no flags) for every bank. Synplify carries
    // this through to the EFX_RAM10 init contents, so power-on state on
    // hardware matches sim — software can read any bank before writing
    // it and gets all-zero attributes (the cache treats $0 as "no
    // hints", same as today's behavior).
    integer init_i;
    initial begin
        for (init_i = 0; init_i < ATTR_DEPTH; init_i++)
            attr_mem[init_i] = '0;
    end

    // Software write to $D385: store wdata[3:0] at attr_addr_q.
    wire attr_we = write_in_win && (wreg == 7'h05);

    // Port B (software) — sync read of attr_addr_q for $D385 reads.
    // Writes happen on $D385 write; on the same cycle the read result
    // for the new value isn't yet visible (sync read), but software
    // typically re-issues a $D385 read after the write to read back.
    logic [ATTR_DATA_W-1:0] attr_rdata_sw_q;
    always_ff @(posedge clk) begin
        if (attr_we) attr_mem[attr_addr_q] <= wdata[ATTR_DATA_W-1:0];
        attr_rdata_sw_q <= attr_mem[attr_addr_q];
    end

    // Port A (cache miss path) — sync read at attr_lookup_idx.
    logic [ATTR_DATA_W-1:0] attr_rdata_cache_q;
    always_ff @(posedge clk) begin
        attr_rdata_cache_q <= attr_mem[attr_lookup_idx];
    end
    assign attr_lookup_data = attr_rdata_cache_q;

    // ---- Read mux ----------------------------------------------------
    // Combinational off live raddr so SALLY's hwreg_dout sees the
    // value within the same cycle. attr_rdata_sw_q is the registered
    // SRAM output — settled by the time software reads $D385 because
    // the write that updated attr_addr_q (or attr_mem) was registered
    // through bus_snoop one cycle earlier.
    always_comb begin
        rdata = 8'h00;
        if (read_in_win) begin
            unique case (rreg)
                7'h00: rdata = {7'h00, enable_partition_q};
                7'h01: rdata = code_lines_q;
                7'h02: rdata = {6'h00, region_q};
                7'h03: rdata = bank_id_lo_q;
                7'h04: rdata = {6'h00, bank_id_hi_q};
                7'h05: rdata = {{(8-ATTR_DATA_W){1'b0}}, attr_rdata_sw_q};
                7'h06: rdata = {4'h0, current_task_q};
                7'h07: rdata = 8'h00;   // $D387 read returns 0 (write-only flush)
                default: rdata = 8'h00; // reserved
            endcase
        end
    end

endmodule

`default_nettype wire
