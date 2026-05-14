// cache_line_ram.sv — wide-write / byte-read cache-line BRAM,
// portable across FPGA vendors.
//
// Encapsulates the wide-data-path pattern used by bank_cache's per-way
// memory under the M-cache-rework Step 7 (HR-burst CDC) refactor.
// Goal: write WORD_BYTES bytes per cycle (refill from HR) while
// reading 1 byte per cycle (CPU hit). Vendor-neutral on its surface
// so the cache logic doesn't carry vendor-specific BRAM directives.
//
// On Efinix Titanium (current target), the implementation relies on
// `syn_ramstyle = "block_ram"` inference. Synplify maps a wide
// symmetric memory ([WIDTH-1:0] mem [0:DEPTH-1]) onto:
//   - 1 × EFX_RAM10  for 16-bit-wide aspect (single-port, 1R+1W),
//   - 2 × EFX_RAM10  for 32-bit-wide aspect.
// Port A and port B share a clock; reads and writes can occur in the
// same cycle to different addresses (the existing bank_cache FSM
// guarantees no read/write collision on the same address).
//
// Why not direct EFX_DPRAM10 instantiation? Because Efinix's
// EFX_DPRAM10 caps each port at 10 bits in hardware, so a true
// asymmetric "8-bit read / 64-bit write" port pair is impossible
// regardless of how you instantiate it. Wider effective widths
// always require multiple BRAMs in parallel, and Synplify's inference
// path produces the same primitive count as a hand-instantiated
// version while staying portable.
//
// To port to another vendor:
//   - Xilinx: replace the `(* syn_ramstyle ... *)` attribute with
//     `(* ram_style = "block" *)` and the inference is identical.
//   - Lattice: drop the attribute (Diamond infers BRAM from the
//     pattern alone for simple 1R+1W).
//   - For a primitive-level swap, replace the `mem` array + always_ff
//     pair with N parallel vendor primitive instances; the wrapper's
//     port list (rdata 8-bit, wdata WORD_BYTES wide, etc.) stays the
//     same so bank_cache need not change.
//
// Geometry:
//   - Total storage: DEPTH * WORD_BYTES bytes (= LINE_BYTES per cache
//     line × NUM_SETS sets per way).
//   - Read port:  byte-wide; raddr is a byte address (log2(DEPTH *
//     WORD_BYTES) bits).
//   - Write port: WORD_BYTES-wide; waddr is a word address (log2(DEPTH)
//     bits). Writes always commit a full word — useful for HR-refill
//     bursts that arrive WORD_BYTES bytes per cycle.
//
// Read-modify-write writes (CPU's per-byte hits) are handled in
// bank_cache by going through a small byte-buffer; this module
// presents a clean wide write so the BRAM stays simple.

`default_nettype none

module cache_line_ram #(
    // Bytes per write — the BRAM aspect ratio. 1 (= today's byte-wide
    // cache) keeps the original behavior; 2 / 4 widen for HR refill
    // bandwidth. Larger values cost more BRAM blocks (Synplify splits
    // wider memories across multiple primitives).
    parameter int unsigned WORD_BYTES = 4,

    // Number of words. Total storage = DEPTH * WORD_BYTES bytes.
    parameter int unsigned DEPTH      = 256,

    // Derived widths.
    parameter int unsigned WORD_W     = WORD_BYTES * 8,
    parameter int unsigned WADDR_W    = $clog2(DEPTH),
    parameter int unsigned RADDR_W    = $clog2(DEPTH * WORD_BYTES),
    parameter int unsigned BYTE_OFF_W = $clog2(WORD_BYTES)
) (
    input  wire                     clk,

    // Read port — byte-wide for CPU access (`rdata`) plus a wide
    // word-view (`rd_word`) for eviction streaming. Both come from
    // the same registered BRAM read; the byte-mux that produces
    // `rdata` adds one LUT level on the CPU-rdata path while
    // `rd_word` skips the mux and lands raw 1 cycle after the
    // address is presented.
    input  wire                     re,
    input  wire [RADDR_W-1:0]       raddr,
    output logic [7:0]              rdata,
    output logic [WORD_W-1:0]       rd_word,

    // Write port — per-byte-lane masked write. we_mask[b]=1 commits
    // wdata[b*8 +: 8] into byte lane b at waddr; lanes with we_mask=0
    // are unchanged. Set we_mask = '1 for a full word write (refill);
    // set we_mask = (1 << byte_off) for a single-byte CPU hit-write.
    input  wire [WORD_BYTES-1:0]    we_mask,
    input  wire [WADDR_W-1:0]       waddr,
    input  wire [WORD_W-1:0]        wdata
);

    (* syn_ramstyle = "block_ram" *)
    logic [WORD_W-1:0] mem [0:DEPTH-1];

    // Synchronous read of the word containing the requested byte;
    // capture the byte offset alongside so the post-read mux can
    // select the right lane.
    logic [WORD_W-1:0] rd_word_q;

    generate
        if (WORD_BYTES == 1) begin : g_narrow
            // Byte-wide path — backwards-compatible with the original
            // bank_cache shape. we_mask is a 1-bit signal here.
            always_ff @(posedge clk) begin
                if (re)         rd_word_q <= mem[raddr];
                if (we_mask[0]) mem[waddr] <= wdata;
            end
            assign rdata   = rd_word_q[7:0];
            assign rd_word = rd_word_q;
        end else begin : g_wide
            logic [BYTE_OFF_W-1:0] byte_off_q;
            always_ff @(posedge clk) begin
                if (re) begin
                    rd_word_q  <= mem[raddr[RADDR_W-1:BYTE_OFF_W]];
                    byte_off_q <= raddr[BYTE_OFF_W-1:0];
                end
                // Standard byte-WE inference idiom: a separate
                // conditional-write per byte lane. Synplify maps this
                // onto EFX_RAM10's per-byte WE pins (WE_POLARITY[1:0])
                // for 16-bit aspect; wider configs map onto multiple
                // BRAMs in parallel with byte-WE on each.
                for (int b = 0; b < WORD_BYTES; b++) begin
                    if (we_mask[b]) mem[waddr][b*8 +: 8] <= wdata[b*8 +: 8];
                end
            end
            // Registered byte mux on the read path. 1 LUT level for
            // WORD_BYTES ∈ {2, 4} (LUT4 implements 2:1 / 4:1 muxes
            // natively); 2 levels for WORD_BYTES = 8.
            assign rdata   = rd_word_q[byte_off_q*8 +: 8];
            assign rd_word = rd_word_q;
        end
    endgenerate

endmodule

`default_nettype wire
