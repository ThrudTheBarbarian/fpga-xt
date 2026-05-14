// prefetch.sv — drives FETCH bursts onto rp_tx to fill the line
// buffer's off-bank with the next atari row's worth of FB data.
//
// On vbi_start: prefetch atari row 0 (initial fill).
// On every atari_row transition: pulse swap (off-bank's data is now
// "current" for scan-out) AND start prefetching atari_row + 1.
//
// FB layout assumed: 1024 atari-pixel indices per row, byte-addressed.
// Per-row source offset (LMS slide) and HSCROL margin are pre-computed
// upstream and fed in as `prefetch_offset` (in atari pixels). For M4
// the only consumer is a stub feeding 0 — the wiring is in place for
// the M5 DL parser to populate it.
//
// rp_tx is the standard FPGA->RP TX module (1 FETCH = 2 bus cycles
// because the TX FSM goes IDLE→BEAT0→IDLE). At pix_clk = 25 MHz, 192
// FETCHes complete in ~15 µs; the available window is 2 native
// scanlines = 63.6 µs. ~4× headroom.

`default_nettype none
`include "bus_opcodes.vh"

module prefetch #(
    parameter int FB_ROW_STRIDE  = 1024,    // bytes per FB row (= atari px per row)
    parameter int LB_WIDTH       = 384,     // line buffer atari px (visible + HSCROL margin)
    parameter int LB_PAIR_AW     = 8,       // ceil(log2(384/2)) = 8
    parameter int FB_ADDR_W      = 24       // bus-side address width
) (
    input  wire        clk,
    input  wire        rst,

    // Vbeam-side triggers and metadata.
    input  wire        vbi_start,           // pulse at start of VBI
    input  wire [15:0] atari_row,           // current atari row (0..239 in band, 0xFFFF outside)
    input  wire [15:0] prefetch_offset,     // atari px offset into FB row (LMS slide + HSCROL margin)

    // rp_tx command interface (we issue FETCHes).
    output logic [1:0]              cmd_tag,
    output logic [FB_ADDR_W-1:0]    cmd_addr,
    output logic [15:0]             cmd_data,
    output logic                    cmd_valid,
    input  wire                     cmd_ready,

    // rp_rx response interface. rsp_pop is combinational on rsp_valid
    // so the FIFO drains in lockstep with capture; otherwise a 1-cycle
    // pop latency double-captures the same response.
    input  wire [15:0]              rsp_data,
    input  wire                     rsp_valid,
    output wire                     rsp_pop,

    // Line buffer write port (off-bank). One write = 16-bit pair = 2 atari px.
    output logic                    lb_wr_en,
    output logic [LB_PAIR_AW-1:0]   lb_wr_addr,
    output logic [15:0]             lb_wr_data,

    // Bank swap pulse, fired at start of each atari row's scan-out
    // (after prefetch of that row has completed).
    output logic                    swap
);

    // Total FETCHes per row: 2 atari px per FETCH response.
    localparam int TOTAL_FETCHES = LB_WIDTH / 2;

    // FSM states.
    typedef enum logic [1:0] {
        S_IDLE   = 2'd0,
        S_ISSUE  = 2'd1,
        S_DRAIN  = 2'd2,
        S_READY  = 2'd3
    } state_t;
    state_t state;

    logic [LB_PAIR_AW:0]  issue_count;     // FETCHes issued so far this row
    logic [LB_PAIR_AW:0]  capture_count;   // beats captured so far this row
    logic [15:0]          target_row;      // atari row currently being prefetched
    logic [15:0]          atari_row_q;     // for edge detection
    logic                 off_bank_ready;  // off-bank holds valid data for some row

    // Edge-detect on atari_row.
    wire atari_row_changed = (atari_row != atari_row_q);

    // Combinational pop — see header comment.
    assign rsp_pop = rsp_valid;

    // Compute the FB byte address for the next FETCH.
    // Each FETCH returns 2 atari px (= 2 bytes). issue_count is the
    // FETCH index; byte offset within row = issue_count * 2 + prefetch_offset.
    wire [FB_ADDR_W-1:0] row_base = target_row[15:0] * FB_ROW_STRIDE;
    wire [FB_ADDR_W-1:0] beat_addr = row_base + {issue_count, 1'b0} + prefetch_offset;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            issue_count     <= '0;
            capture_count   <= '0;
            target_row      <= 16'h0;
            atari_row_q     <= 16'hFFFF;
            off_bank_ready  <= 1'b0;
            cmd_valid       <= 1'b0;
            cmd_tag         <= `BUS_TAG_NOP;
            cmd_addr        <= '0;
            cmd_data        <= 16'h0;
            lb_wr_en        <= 1'b0;
            lb_wr_addr      <= '0;
            lb_wr_data      <= 16'h0;
            swap            <= 1'b0;
        end else begin
            // Defaults — overridden in cases below.
            cmd_valid <= 1'b0;
            lb_wr_en  <= 1'b0;
            swap      <= 1'b0;
            atari_row_q <= atari_row;

            // Reset frame state on VBI.
            if (vbi_start) off_bank_ready <= 1'b0;

            // Bank-swap event: a new atari row has begun on the scan-out
            // side. Swap so the just-prefetched data becomes "current."
            if (atari_row_changed && off_bank_ready
                && (atari_row != 16'hFFFF)) begin
                swap           <= 1'b1;
                off_bank_ready <= 1'b0;
            end

            // Hold cmd_valid (not the default-low) for proper ready/
            // valid handshake. When the FSM has nothing to issue we
            // override to 0 below.
            cmd_valid <= cmd_valid;

            // Capture FETCH responses as they arrive. rsp_pop is
            // combinational on rsp_valid (driven outside this block).
            if (rsp_valid) begin
                lb_wr_en   <= 1'b1;
                lb_wr_addr <= capture_count[LB_PAIR_AW-1:0];
                lb_wr_data <= rsp_data;
                capture_count <= capture_count + 1'b1;
            end

            unique case (state)
                S_IDLE: begin
                    cmd_valid <= 1'b0;
                    if (vbi_start) begin
                        target_row    <= 16'h0;
                        issue_count   <= '0;
                        capture_count <= '0;
                        // Set up first cmd (cmd_valid raises next cycle in S_ISSUE).
                        state         <= S_ISSUE;
                    end else if (atari_row_changed
                                 && atari_row != 16'hFFFF
                                 && (atari_row + 16'd1) != 16'hFFFF) begin
                        target_row    <= atari_row + 16'd1;
                        issue_count   <= '0;
                        capture_count <= '0;
                        state         <= S_ISSUE;
                    end
                end
                S_ISSUE: begin
                    // Standard ready/valid handshake. Hold cmd_valid
                    // high while there are FETCHes left to issue. Only
                    // advance issue_count + cmd_addr when both
                    // cmd_valid and cmd_ready are high (= transfer).
                    if (cmd_valid && cmd_ready) begin
                        if (issue_count + 1'b1 == TOTAL_FETCHES[LB_PAIR_AW:0]) begin
                            cmd_valid <= 1'b0;
                            issue_count <= issue_count + 1'b1;
                            state <= S_DRAIN;
                        end else begin
                            issue_count <= issue_count + 1'b1;
                            cmd_addr    <= cmd_addr + 24'd2;
                        end
                    end else if (!cmd_valid) begin
                        // Initial issue on S_ISSUE entry.
                        cmd_valid <= 1'b1;
                        cmd_tag   <= `BUS_TAG_FETCH;
                        cmd_addr  <= beat_addr;
                    end
                end
                S_DRAIN: begin
                    cmd_valid <= 1'b0;
                    if (capture_count == TOTAL_FETCHES[LB_PAIR_AW:0]) begin
                        off_bank_ready <= 1'b1;
                        state          <= S_READY;
                    end
                end
                S_READY: begin
                    cmd_valid <= 1'b0;
                    if (atari_row_changed) begin
                        if (atari_row != 16'hFFFF
                            && (atari_row + 16'd1) != 16'hFFFF) begin
                            target_row    <= atari_row + 16'd1;
                            issue_count   <= '0;
                            capture_count <= '0;
                            state         <= S_ISSUE;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
