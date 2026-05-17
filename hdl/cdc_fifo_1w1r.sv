// cdc_fifo_1w1r.sv — minimal async FIFO for SALLY→ANTIC register writes.
//
// Single-clock write port, independent single-clock read port.  Uses
// binary-coded pointers with 2-FF synchroniser crossings.  Depth is
// parameterised (default 4 entries — plenty for register writes which
// are infrequent relative to either clock).
//
// Full/empty flags are registered (1-cycle latency on empty assertion
// on the read side).  This is acceptable for register writes — the
// write side never needs to poll full (it just drops writes if full,
// which shouldn't happen in normal operation).
//
// Write interface (src_clk domain, SALLY side):
//   wr_en  — 1-cycle pulse to push {addr, data} into FIFO
//   wr_data — {addr[15:0], data[7:0]} — 24-bit register write descriptor
//
// Read interface (dst_clk domain, ANTIC side):
//   rd_en  — 1-cycle pulse to pop next entry
//   rd_data — {addr[15:0], data[7:0]}
//   rd_empty — 1 when FIFO is empty (poll before rd_en)

`default_nettype none

module cdc_fifo_1w1r #(
    parameter int DATA_W = 24,      // {addr[15:0], data[7:0]}
    parameter int ADDR_W = 2        // 2 → 4 entries
) (
    input  wire              src_clk,
    input  wire              src_rst,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              wr_full,

    input  wire              dst_clk,
    input  wire              dst_rst,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              rd_empty
);

    localparam int DEPTH = 1 << ADDR_W;

    // ---- Storage (dual-clock distributed RAM / BRAM) --------------------
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // ---- Pointer management ---------------------------------------------
    logic [ADDR_W:0] wr_ptr, rd_ptr;          // MSB = flag bit for full/empty
    logic [ADDR_W:0] wr_ptr_gray, rd_ptr_gray;
    logic [ADDR_W:0] wr_ptr_sync, rd_ptr_sync;

    // Write pointer (src_clk domain) — kept in an async-reset block so the
    // FIFO empties cleanly on src_rst.
    always_ff @(posedge src_clk or posedge src_rst) begin
        if (src_rst) wr_ptr <= '0;
        else if (wr_en && !wr_full) wr_ptr <= wr_ptr + 1'b1;
    end

    // mem write must be in a sync-only block — the async reset on the
    // pointer always_ff would otherwise block both BRAM and distributed-RAM
    // inference (Synth 8-4767 "RAM is sensitive to asynchronous reset
    // signal").  The storage doesn't actually need reset: stale bytes
    // become unreachable once wr_ptr/rd_ptr return to 0.
    always_ff @(posedge src_clk) begin
        if (wr_en && !wr_full) mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
    end

    // Read pointer (dst_clk domain)
    always_ff @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) rd_ptr <= '0;
        else if (rd_en && !rd_empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];

    // ---- Gray-code conversion (for CDC) ---------------------------------
    function automatic [ADDR_W:0] bin2gray(input [ADDR_W:0] bin);
        bin2gray = bin ^ (bin >> 1);
    endfunction

    assign wr_ptr_gray = bin2gray(wr_ptr);
    assign rd_ptr_gray = bin2gray(rd_ptr);

    // Synchronise write pointer into dst_clk domain (for empty detection)
    logic [ADDR_W:0] wr_ptr_gray_sync0, wr_ptr_gray_sync1;
    always_ff @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) begin
            wr_ptr_gray_sync0 <= '0;
            wr_ptr_gray_sync1 <= '0;
        end else begin
            wr_ptr_gray_sync0 <= wr_ptr_gray;
            wr_ptr_gray_sync1 <= wr_ptr_gray_sync0;
        end
    end
    assign wr_ptr_sync = wr_ptr_gray_sync1;

    // Synchronise read pointer into src_clk domain (for full detection)
    logic [ADDR_W:0] rd_ptr_gray_sync0, rd_ptr_gray_sync1;
    always_ff @(posedge src_clk or posedge src_rst) begin
        if (src_rst) begin
            rd_ptr_gray_sync0 <= '0;
            rd_ptr_gray_sync1 <= '0;
        end else begin
            rd_ptr_gray_sync0 <= rd_ptr_gray;
            rd_ptr_gray_sync1 <= rd_ptr_gray_sync0;
        end
    end
    assign rd_ptr_sync = rd_ptr_gray_sync1;

    // ---- Gray-to-binary conversion --------------------------------------
    function automatic [ADDR_W:0] gray2bin(input [ADDR_W:0] gray);
        logic [ADDR_W:0] bin;
        bin[ADDR_W] = gray[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--)
            bin[i] = bin[i+1] ^ gray[i];
        return bin;
    endfunction

    // ---- Full / empty detection -----------------------------------------
    wire [ADDR_W:0] wr_ptr_sync_bin = gray2bin(wr_ptr_sync);
    wire [ADDR_W:0] rd_ptr_sync_bin = gray2bin(rd_ptr_sync);

    assign wr_full  = (wr_ptr[ADDR_W] != rd_ptr_sync_bin[ADDR_W])
                    && (wr_ptr[ADDR_W-1:0] == rd_ptr_sync_bin[ADDR_W-1:0]);

    assign rd_empty = (rd_ptr == wr_ptr_sync);

endmodule

`default_nettype wire
