// line_buffer.sv — ping-pong line buffer for the scan-out path.
//
// Layout: each bank holds WIDTH atari-pixel indices, stored as
// WIDTH/2 16-bit cells (each cell holds two adjacent atari px so a
// single FETCH response lands in one write cycle). The read port is
// byte-addressed (one atari px per read).
//
// On each `swap` pulse the writer/reader swap banks: scan-out then
// reads from the bank prefetch just finished writing, and prefetch
// writes into the bank scan-out is no longer reading.
//
// Single-clock module — same `clk` for both ports. The integration
// adds CDC at its instantiation (compositor in clk_bus, line_buffer +
// scan_out in clk_pix) by 2-FF-syncing the wr_en + wr_addr + wr_data
// path.
//
// BRAM mapping: the two banks live in independent 1-D memories
// instantiated via a `generate` block. Each bank gets its own clean
// 1R+1W always_ff (same pattern as bank_cache.sv:g_data after
// M24-int-cache v3) so Synplify infers EFX_DPRAM10 per bank rather
// than spilling to distributed-LUT memory. The read mux on
// bank_select is purely combinational from the per-bank read
// registers — no extra cycle of latency.
//
// M19 TODO: the read path has 2 cycles of latency (per-bank rd_q
// register + rd_hi_q register). At each atari-row transition,
// scan-out reads stale data for the first 2-3 native pixels until
// the pipeline fills. The M4 testbench masks the leading edge of
// each scanline.

`default_nettype none

module line_buffer #(
    parameter int WIDTH = 384,                     // atari px per bank
    parameter int RD_ADDR_W = $clog2(WIDTH),
    parameter int WR_ADDR_W = $clog2(WIDTH/2)
) (
    input  wire                  clk,
    input  wire                  rst,

    // Writer side (prefetch fills the OFF-bank, 16 bits per write =
    // 2 atari px per write).
    input  wire                  wr_en,
    input  wire [WR_ADDR_W-1:0]  wr_addr,        // pair index 0..WIDTH/2-1
    input  wire [15:0]           wr_data,        // {high_byte, low_byte} = px[2k+1] : px[2k]

    // Reader side (scan-out reads ON-bank one atari px at a time).
    input  wire [RD_ADDR_W-1:0]  rd_addr,        // atari x 0..WIDTH-1
    output logic [7:0]           rd_data,

    // Pulse `swap` for one cycle to flip banks.
    input  wire                  swap
);

    localparam int PAIRS = WIDTH / 2;

    logic bank_select;     // 0 → scan-out reads bank 0, prefetch writes bank 1
    always_ff @(posedge clk or posedge rst) begin
        if (rst)        bank_select <= 1'b0;
        else if (swap)  bank_select <= ~bank_select;
    end

    wire [WR_ADDR_W-1:0] rd_pair = rd_addr[RD_ADDR_W-1:1];
    wire                 rd_hi   = rd_addr[0];

    // ---- Per-bank memories (BRAM-mappable) ---------------------------
    // Each bank is its own 1-D memory with a single sync read port and a
    // gated single sync write port → Synplify maps each to one
    // EFX_RAM10/EFX_DPRAM10 BRAM block.
    logic [15:0] rd_word_per_bank [0:1];

    genvar gb;
    generate
        for (gb = 0; gb < 2; gb++) begin : g_bank
            (* syn_ramstyle = "block_ram" *)
            logic [15:0] mem [0:PAIRS-1];

            // OFF-bank for writes is `~bank_select`; this bank fires its
            // write iff this generate iteration matches.
            wire write_to_this_bank = wr_en && (~bank_select == gb[0]);

            always_ff @(posedge clk) begin
                if (write_to_this_bank) mem[wr_addr] <= wr_data;
                rd_word_per_bank[gb] <= mem[rd_pair];
            end
        end
    endgenerate

    // Combinational mux between the two per-bank read registers — pure
    // 16-bit 2:1 selector, no extra latency. rd_word is therefore
    // 1-cycle-latency w.r.t. rd_addr, matching the original timing.
    wire [15:0] rd_word = bank_select ? rd_word_per_bank[1] : rd_word_per_bank[0];

    // Match the rd_data 1-cycle latency by also registering the byte select.
    logic rd_hi_q;
    always_ff @(posedge clk) rd_hi_q <= rd_hi;

    assign rd_data = rd_hi_q ? rd_word[15:8] : rd_word[7:0];

endmodule

`default_nettype wire
