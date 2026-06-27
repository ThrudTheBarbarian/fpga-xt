// cdc_flag_data.sv — safe multi-bit clock-domain transfer (data + toggle flag).
//
// THE canonical fix for the recurring "garbage intermediate" CDC bug.  Twice we
// shipped a free-running multi-bit value 2-FF *bus*-synced across clocks; on a
// multi-bit carry (e.g. 127->128) some flops latched the old value and some the
// new, producing a value that never existed — the row-128 "rainbow line"
// (fetch_row) and the sprite-cursor flicker (pix_next_vcount).  See
// docs/Design/cdc-guidelines.md.
//
// This primitive transfers ONE multi-bit word per src_valid pulse with a
// data+toggle handshake:
//   - on src_valid we latch src_data into a holding reg AND flip a toggle;
//   - the toggle (a single bit) is 2-FF synchronised into dst_clk and edge-
//     detected; the held data is sampled in dst_clk ONLY on that edge, by which
//     time it has been stable for ≥2 dst cycles.
// Because only the 1-bit toggle crosses asynchronously, there is no multi-bit
// race: the data is sampled when it is guaranteed settled.  Robust to ANY clock
// ratio provided src_valid pulses are spaced ≳3 dst_clk cycles apart (always
// true for the line-rate / frame-rate transfers this replaces).
//
// Pair with constraints/cdc_*.xdc: set_false_path -from the src holding reg.
//
// Usage:
//   cdc_flag_data #(.WIDTH(12)) u_row_cdc (
//       .src_clk (clk_pix), .src_data(fetch_row_pix), .src_valid(line_start),
//       .dst_clk (clk_sys), .dst_data(row_to_fetch),  .dst_valid(row_valid));

`default_nettype none

module cdc_flag_data #(
    parameter int WIDTH = 8
) (
    input  wire             src_clk,
    input  wire [WIDTH-1:0] src_data,   // sampled at the src_valid edge
    input  wire             src_valid,  // 1-cycle strobe in src_clk

    input  wire             dst_clk,
    output reg  [WIDTH-1:0] dst_data,   // updated on dst_valid; holds otherwise
    output reg              dst_valid   // 1-cycle strobe in dst_clk
);

    // ---- source domain: latch data + flip the crossing toggle ----
    reg [WIDTH-1:0] src_hold = '0;
    reg             src_tog  = 1'b0;
    always_ff @(posedge src_clk) begin
        if (src_valid) begin
            src_hold <= src_data;
            src_tog  <= ~src_tog;
        end
    end

    // ---- 1-bit toggle across the boundary (the ONLY async crossing) ----
    wire tog_sync;
    cdc_sync_bit u_tog (
        .dst_clk (dst_clk),
        .src_sig (src_tog),
        .dst_sig (tog_sync)
    );

    // ---- destination domain: edge-detect toggle, sample the (settled) data ----
    reg tog_sync_d = 1'b0;
    always_ff @(posedge dst_clk) begin
        tog_sync_d <= tog_sync;
        dst_valid  <= 1'b0;
        if (tog_sync ^ tog_sync_d) begin
            dst_data  <= src_hold;   // stable since the toggle was raised
            dst_valid <= 1'b1;
        end
    end

endmodule

`default_nettype wire
