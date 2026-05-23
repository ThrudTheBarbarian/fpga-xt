// banked_page_cache.sv — resident page cache for SALLY banked windows.
//
// Replaces banked_axi_reader.sv with a full-page-resident cache.
// Two internal banks:
//   - Code cache: 16 KB (256 lines × 64 B), read-only.
//   - Data cache: 12 KB (192 lines × 64 B), read-write with dirty-bit
//     tracking and write-back on page swap.
//
// Once a page is resident, all reads (and data writes) hit BRAM at
// single-cycle latency — no AXI round-trips.  The only DDR3 traffic
// is demand-fill of untouched lines and write-back of dirty lines on
// page swap.
//
// Interface is a superset of banked_axi_reader.sv: same req_* +
// AXI master ports, plus bank_id / is_code for swap detection.
//
// Swap detection: compare bank_id to the resident tag on every
// request.  On mismatch:
//   - Code: clear all valid bits (1 cycle), set new tag, demand-fill.
//   - Data: flush every dirty line (8-beat AXI write bursts), then
//           clear valid+dirty, set new tag, demand-fill.
//
// Design choices (from docs/Progress/banked-page-cache.md):
//   - Read-allocate on write miss (keeps lines coherent for flush).
//   - Demand fill on swap (no eager whole-page DMA).
//   - Per-line dirty granularity.
//   - Single module with both caches internal (shares one AXI master).
//   - Registered BRAM output for timing (matches sally_mem pipeline).
//
// BRAM addressing: both caches use a registered address (set explicitly
// by the FSM) to avoid combinational-path race conditions between the
// state machine update and the BRAM read sampling.

`default_nettype none

module banked_page_cache #(
    parameter int unsigned AXI_ADDR_W = 32
) (
    input  wire                   clk,
    input  wire                   rst,

    // SALLY-side request (same contract as banked_axi_reader)
    input  wire [AXI_ADDR_W-1:0]  req_addr,
    input  wire                   req_valid,
    input  wire                   req_we,
    input  wire [7:0]             req_wdata,
    output wire [7:0]             req_rdata,
    output wire                   req_ready,

    // Page info (for swap detection within the cache)
    input  wire [15:0]            bank_id,       // page index
    input  wire                   is_code,       // 1 = code window, 0 = data

    // AXI4 burst read master
    output wire [AXI_ADDR_W-1:0]  m_axi_araddr,
    output wire [7:0]             m_axi_arlen,
    output wire [2:0]             m_axi_arsize,
    output wire [1:0]             m_axi_arburst,
    output wire                   m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [63:0]            m_axi_rdata,
    input  wire                   m_axi_rvalid,
    input  wire                   m_axi_rlast,
    output wire                   m_axi_rready,

    // AXI4 burst write master (for data-cache dirty-line flush)
    output wire [AXI_ADDR_W-1:0]  m_axi_awaddr,
    output wire [7:0]             m_axi_awlen,
    output wire [2:0]             m_axi_awsize,
    output wire [1:0]             m_axi_awburst,
    output wire                   m_axi_awvalid,
    input  wire                   m_axi_awready,
    output wire [63:0]            m_axi_wdata,
    output wire [7:0]             m_axi_wstrb,
    output wire                   m_axi_wlast,
    output wire                   m_axi_wvalid,
    input  wire                   m_axi_wready,
    input  wire                   m_axi_bvalid,
    output wire                   m_axi_bready
);

    // ---- Constants ---------------------------------------------------------
    localparam int BEATS_PER_LINE = 8;
    localparam int CODE_LINES      = 256;
    localparam int CODE_BRAM_DEPTH = CODE_LINES * BEATS_PER_LINE;  // 2048
    localparam int DATA_LINES      = 192;
    localparam int DATA_BRAM_DEPTH = DATA_LINES * BEATS_PER_LINE;  // 1536

    // ---- Address decomposition -------------------------------------------
    wire [2:0]  beat_idx  = req_addr[5:3];
    wire [2:0]  byte_idx  = req_addr[2:0];
    wire [7:0]  line_idx  = req_addr[13:6];
    wire [15:0] page_tag  = bank_id;

    // ---- Resident tag + valid/dirty bookkeeping ---------------------------
    // Code cache (read-only)
    logic [15:0]            code_resident_tag_q;
    logic                   code_resident_valid_q;
    logic [CODE_LINES-1:0]  code_valid_q;
    logic [AXI_ADDR_W-1:14] code_page_base_q;      // page-aligned DDR3 base

    // Data cache (read-write)
    logic [15:0]            data_resident_tag_q;
    logic                   data_resident_valid_q;
    logic [DATA_LINES-1:0]  data_valid_q;
    logic [DATA_LINES-1:0]  data_dirty_q;
    logic [7:0]             data_flush_idx_q;
    logic [AXI_ADDR_W-1:14] data_page_base_q;

    // Flush pre-read buffer — 8 beats of 64-bit line data
    logic [63:0]            flush_buf [0:7];
    logic [2:0]             flush_beat_q;     // beat counter during pre-read
    logic                   flush_wait_q;     // 0=wait for BRAM, 1=capture & advance

    // ---- BRAM arrays ------------------------------------------------------
    (* ram_style = "block" *)
    logic [63:0] code_cache [0:CODE_BRAM_DEPTH-1];
    (* ram_style = "block" *)
    logic [63:0] data_cache [0:DATA_BRAM_DEPTH-1];

    // BRAM registered outputs
    logic [63:0] code_cache_dout;
    logic [63:0] data_cache_dout;

    // Registered BRAM addresses (set explicitly by FSM to avoid combo races)
    logic [10:0] code_cache_addr_q;
    logic [10:0] data_cache_addr_q;

    // ---- FSM --------------------------------------------------------------
    // NOTE: BRAM read (data_cache_dout / code_cache_dout) and write
    // (data_cache[addr] / code_cache[addr]) happen inside the FSM
    // always_ff block to avoid cross-block race conditions on the
    // write-enable signal.
    typedef enum logic [4:0] {
        IDLE,
        // Code page swap: invalidate all lines (1 cycle)
        CODE_SWAP_INVAL,
        // Data page swap: flush dirty lines, then invalidate
        DATA_FLUSH_SCAN,     // scan for next dirty line
        DATA_FLUSH_AR,       // AXI AW for flush write burst
        DATA_FLUSH_READ,     // pre-read line beats into flush_buf (BRAM has 1-cycle latency)
        DATA_FLUSH_W,        // AXI W for flush write burst (8 beats, from flush_buf)
        DATA_FLUSH_B,        // AXI B for flush write burst
        DATA_SWAP_INVAL,     // clear valid+dirty after flush done
        // Fill: AXI read burst
        FILL_AR,             // AXI AR
        FILL_R,              // AXI R (8 beats)
        FILL_DONE,           // 1-cycle drain after FILL_R (let BRAM output settle)
        // Data write: read-modify-write BRAM
        WRITE_R_SETUP,       // set BRAM address for the write beat
        WRITE_R,             // latch the beat from BRAM
        WRITE_COMMIT         // write modified beat back
    } state_t;

    state_t state_q;

`ifndef SYNTHESIS
    int debug_cycle_q = 0;
    always_ff @(posedge clk) debug_cycle_q <= debug_cycle_q + 1;
    string state_str;
    always_comb case (state_q)
        IDLE:             state_str = "IDLE";
        CODE_SWAP_INVAL:  state_str = "CODE_SWAP_INVAL";
        DATA_FLUSH_SCAN:  state_str = "DATA_FLUSH_SCAN";
        DATA_FLUSH_AR:    state_str = "DATA_FLUSH_AR";
        DATA_FLUSH_READ:  state_str = "DATA_FLUSH_READ";
        DATA_FLUSH_W:     state_str = "DATA_FLUSH_W";
        DATA_FLUSH_B:     state_str = "DATA_FLUSH_B";
        DATA_SWAP_INVAL:  state_str = "DATA_SWAP_INVAL";
        FILL_AR:          state_str = "FILL_AR";
        FILL_R:           state_str = "FILL_R";
        FILL_DONE:        state_str = "FILL_DONE";
        WRITE_R_SETUP:    state_str = "WRITE_R_SETUP";
        WRITE_R:          state_str = "WRITE_R";
        WRITE_COMMIT:     state_str = "WRITE_COMMIT";
        default:          state_str = "???";
    endcase
`endif

    // Captured request fields
    logic [AXI_ADDR_W-1:0]  pending_addr_q;
    logic [7:0]             pending_line_idx_q;
    logic [2:0]             pending_beat_idx_q;
    logic [2:0]             pending_byte_idx_q;
    logic [7:0]             pending_wdata_q;
    logic                   pending_is_code_q;
    logic                   pending_we_q;          // 1 = original req was a write

    // AXI burst beat counter
    logic [3:0]             axi_beat_q;

    // Write-merging register
    logic [63:0]            write_merge_q;
    logic                   write_stall_q;        // 1 cycle stall after write for BRAM dout

    // ---- Hit / miss / swap detection (combinational) ----------------------
    wire   code_page_match  = code_resident_valid_q && (page_tag == code_resident_tag_q);
    wire   data_page_match  = data_resident_valid_q && (page_tag == data_resident_tag_q);
    wire   curr_is_code     = is_code;
    wire   curr_is_data     = !is_code;
    wire   page_match       = curr_is_code ? code_page_match : data_page_match;

    wire   line_valid       = page_match && (
                                curr_is_code ? code_valid_q[line_idx]
                                             : data_valid_q[line_idx]
                            );
    wire   read_hit_w       = req_valid && !req_we && line_valid;
    wire   write_hit_w      = req_valid && req_we && curr_is_data && line_valid;

    // ---- BRAM write control (combinatorial, for Vivado inference) ---------
    // Vivado's BRAM inference engine needs to see a simple
    // `if (we) mem[addr] <= din` pattern at a consistent location.
    // The original code buried these inside the complex FSM case, which
    // confused the inference engine.  Extract the write-enable and
    // write-data signals combinatorially so the BRAM RTL at the end of
    // the always_ff block is trivial for the tool to match.
    wire code_we      = (state_q == FILL_R) && m_axi_rvalid && pending_is_code_q;
    wire data_fill_we = (state_q == FILL_R) && m_axi_rvalid && !pending_is_code_q;
    wire data_commit_we = (state_q == WRITE_COMMIT);
    wire data_we      = data_fill_we || data_commit_we;
    wire [63:0] data_cache_din = data_commit_we ?
        (write_merge_q & ~(64'hFF << (pending_byte_idx_q * 8))) |
        (64'(pending_wdata_q) << (pending_byte_idx_q * 8)) :
        m_axi_rdata;

    // ---- State machine ----------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q                <= IDLE;
            code_resident_tag_q    <= '0;
            code_resident_valid_q  <= 1'b0;
            code_valid_q           <= '0;
            code_page_base_q       <= '0;
            data_resident_tag_q    <= '0;
            data_resident_valid_q  <= 1'b0;
            data_valid_q           <= '0;
            data_dirty_q           <= '0;
            data_flush_idx_q       <= '0;
            data_page_base_q       <= '0;
            pending_addr_q         <= '0;
            pending_line_idx_q     <= '0;
            pending_beat_idx_q     <= '0;
            pending_byte_idx_q     <= '0;
            pending_wdata_q        <= '0;
            pending_is_code_q      <= '0;
            pending_we_q            <= '0;
            axi_beat_q             <= '0;
            write_merge_q          <= '0;
            write_stall_q          <= 1'b0;
            code_cache_addr_q      <= '0;
            data_cache_addr_q      <= '0;
            flush_beat_q           <= '0;
            flush_wait_q           <= 1'b0;
            flush_buf[0]           <= '0;
            flush_buf[1]           <= '0;
            flush_buf[2]           <= '0;
            flush_buf[3]           <= '0;
            flush_buf[4]           <= '0;
            flush_buf[5]           <= '0;
            flush_buf[6]           <= '0;
            flush_buf[7]           <= '0;
        end else begin
            // BRAM reads are in separate always_ff blocks below (Vivado inference).

            // Default BRAM address: current request's line+beat
            // (used for read-hit and as a safe idle address).
            code_cache_addr_q <= {line_idx, beat_idx};
            data_cache_addr_q <= {line_idx, beat_idx};

            unique case (state_q)

                // ===== IDLE =====
                IDLE: begin
`ifndef SYNTHESIS
                    if (req_valid && req_we && curr_is_data) begin
                        $display("[%0d] IDLE data write: addr=%h line=%d beat=%d byte=%d wdata=%h page_match=%d line_valid=%d (dvalid[%d]=%d)",
                            debug_cycle_q, req_addr, line_idx, beat_idx, byte_idx,
                            req_wdata, page_match, line_valid, line_idx, data_valid_q[line_idx]);
                    end
`endif
                    // Stall one cycle after a write to let data_cache_dout
                    // settle (comb read path needs updated BRAM data).
                    // During the stall, capture requests normally but block
                    // read responses via read_hit_ready gating.
                    if (write_stall_q) begin
                        write_stall_q <= 1'b0;
                    end

                    // Always capture incoming requests (even during stall).
                    if (req_valid && req_we && curr_is_code) begin
                        // Code write illegal — no-op.
                    end else if (write_hit_w) begin
`ifndef SYNTHESIS
                        $display("[%0d] IDLE → WRITE_R_SETUP: line=%d beat=%d byte=%d wdata=%02h",
                            debug_cycle_q, line_idx, beat_idx, byte_idx, req_wdata);
`endif
                        pending_line_idx_q <= line_idx;
                        pending_beat_idx_q <= beat_idx;
                        pending_byte_idx_q <= byte_idx;
                        pending_wdata_q    <= req_wdata;
                        pending_is_code_q  <= 1'b0;
                        // BRAM address at this posedge is still the old
                        // value from the previous cycle.  Go through
                        // WRITE_R_SETUP to set it correctly first.
                        state_q            <= WRITE_R_SETUP;
                    end else if (req_valid && !write_stall_q) begin
                        // Miss or read-hit.  Read-hits stay in IDLE
                        // (read_hit_ready handles req_ready).
                        // During write_stall, don't capture new misses
                        // or serve read-hits (dout is stale).
                        if (read_hit_w) begin
                            // Read hit: stay in IDLE, req_ready via
                            // read_hit_ready (which is gated by
                            // !write_stall_q).
                        end else begin
                            // Miss: capture request.
`ifndef SYNTHESIS
                            $display("[%0d] IDLE miss: addr=%h code=%d we=%d line=%d beat=%d",
                                debug_cycle_q, req_addr, curr_is_code, req_we, line_idx, beat_idx);
`endif
                            pending_addr_q     <= req_addr;
                            pending_line_idx_q <= line_idx;
                            pending_beat_idx_q <= beat_idx;
                            pending_byte_idx_q <= byte_idx;
                            pending_wdata_q    <= req_wdata;
                            pending_is_code_q  <= curr_is_code;
                            pending_we_q       <= req_we && curr_is_data;

                            if (curr_is_code && !code_page_match) begin
                                state_q <= CODE_SWAP_INVAL;
                            end else if (curr_is_data && !data_page_match) begin
                                data_flush_idx_q <= '0;
                                state_q          <= DATA_FLUSH_SCAN;
                            end else begin
                                state_q <= FILL_AR;
                            end
                        end
                    end
                end

                // ===== CODE_SWAP_INVAL =====
                CODE_SWAP_INVAL: begin
                    code_valid_q          <= '0;
                    code_resident_tag_q   <= page_tag;
                    code_resident_valid_q <= 1'b1;
                    code_page_base_q      <= pending_addr_q[AXI_ADDR_W-1:14];
                    // Set BRAM address for first fill beat
                    code_cache_addr_q     <= {pending_line_idx_q, 3'd0};
                    state_q               <= FILL_AR;
                end

                // ===== DATA_FLUSH_SCAN =====
                DATA_FLUSH_SCAN: begin
                    code_cache_addr_q <= {line_idx, beat_idx};
                    data_cache_addr_q <= {line_idx, beat_idx};
                    if (data_flush_idx_q < DATA_LINES) begin
                        if (data_dirty_q[data_flush_idx_q]) begin
                            pending_line_idx_q <= data_flush_idx_q;
                            pending_beat_idx_q <= '0;
                            axi_beat_q         <= '0;
                            state_q            <= DATA_FLUSH_AR;
                        end else begin
                            data_flush_idx_q <= data_flush_idx_q + 1'b1;
                        end
                    end else begin
                        state_q <= DATA_SWAP_INVAL;
                    end
                end

                // ===== DATA_FLUSH_AR =====
                DATA_FLUSH_AR: begin
                    // Set BRAM address to start pre-reading beat 0.
                    data_cache_addr_q <= {pending_line_idx_q, 3'd0};
                    if (m_axi_awready) begin
                        flush_beat_q <= '0;
                        // Always start with a wait cycle: the BRAM address was
                        // set at THIS posedge, but data_cache_dout at the
                        // NEXT posedge reflects the OLD address.  The cycle
                        // after that will have the correct data for beat 0.
                        flush_wait_q <= 1'b1;
                        state_q      <= DATA_FLUSH_READ;
                    end
                end

                // ===== DATA_FLUSH_READ =====
                // Pre-read all 8 beats of the dirty line into flush_buf.
                // BRAM has 1-cycle read latency: after setting the address in
                // one cycle, the data appears in data_cache_dout at the START
                // of the SECOND subsequent cycle.  We alternate between a
                // "wait" cycle (let BRAM read) and a "capture" cycle.
                DATA_FLUSH_READ: begin
`ifndef SYNTHESIS
                    $display("[%0d] DATA_FLUSH_READ: beat=%d wait=%d dout=%016h",
                        debug_cycle_q, flush_beat_q, flush_wait_q, data_cache_dout);
`endif
                    // Keep BRAM address stable — the default {line_idx, beat_idx}
                    // from req_addr would reset it, so override explicitly.
                    if (flush_wait_q) begin
                        // Wait cycle: hold current address so BRAM reads it.
                        // data_cache_dout START has stale data (from the
                        // PREVIOUS cycle's capture).  We let the BRAM read
                        // the address set in the previous cycle.
                        data_cache_addr_q <= {pending_line_idx_q, flush_beat_q};
                        flush_wait_q <= 1'b0;
                    end else begin
                        // Capture cycle: data_cache_dout START now has the
                        // data for the address set TWO cycles ago.
                        flush_buf[flush_beat_q] <= data_cache_dout;
`ifndef SYNTHESIS
                        $display("[%0d] DATA_FLUSH_READ: capture buf[%d]=%016h",
                            debug_cycle_q, flush_beat_q, data_cache_dout);
`endif
                        if (flush_beat_q == 7) begin
                            // All 8 beats pre-read.  Start sending.
                            axi_beat_q  <= '0;
                            state_q     <= DATA_FLUSH_W;
                        end else begin
                            // Advance BRAM address to the next beat.
                            data_cache_addr_q <= {pending_line_idx_q,
                                                   flush_beat_q + 1'b1};
                            flush_beat_q <= flush_beat_q + 1'b1;
                            flush_wait_q <= 1'b1;   // wait after advancing
                        end
                    end
                end

                // ===== DATA_FLUSH_W =====
                // Send 8 beats from flush_buf to the AXI write channel.
                DATA_FLUSH_W: begin
                    if (m_axi_wready) begin
`ifndef SYNTHESIS
                        $display("[%0d] DATA_FLUSH_W: beat=%d wdata=%016h",
                            debug_cycle_q, axi_beat_q, flush_buf[axi_beat_q]);
`endif
                        if (axi_beat_q == 7) begin
                            state_q <= DATA_FLUSH_B;
                        end else begin
                            axi_beat_q <= axi_beat_q + 1'b1;
                        end
                    end
                end

                // ===== DATA_FLUSH_B =====
                DATA_FLUSH_B: begin
                    if (m_axi_bvalid) begin
`ifndef SYNTHESIS
                        $display("[%0d] DATA_FLUSH_B: line=%d done",
                            debug_cycle_q, data_flush_idx_q);
`endif
                        data_dirty_q[data_flush_idx_q] <= 1'b0;
                        data_flush_idx_q <= data_flush_idx_q + 1'b1;
                        state_q <= DATA_FLUSH_SCAN;
                    end
                end

                // ===== DATA_SWAP_INVAL =====
                DATA_SWAP_INVAL: begin
                    data_valid_q          <= '0;
                    data_dirty_q          <= '0;
                    data_resident_tag_q   <= page_tag;
                    data_resident_valid_q <= 1'b1;
                    data_page_base_q      <= pending_addr_q[AXI_ADDR_W-1:14];
                    // Set BRAM address for first fill beat
                    data_cache_addr_q     <= {pending_line_idx_q, 3'd0};
                    state_q               <= FILL_AR;
                end

                // ===== FILL_AR =====
                FILL_AR: begin
                    // Keep BRAM address pointing to first beat of
                    // the line being filled (set in swap_inval states).
                    if (m_axi_arready) begin
                        axi_beat_q <= '0;
                        state_q    <= FILL_R;
                    end
                end

                // ===== FILL_R =====
                FILL_R: begin
                    if (m_axi_rvalid) begin
                        // BRAM write handled by combinatorial code_we / data_we (below).
                        // Advance BRAM address for next beat.
                        if (!m_axi_rlast) begin
                            if (pending_is_code_q) begin
                                code_cache_addr_q <= {
                                    pending_line_idx_q,
                                    axi_beat_q + 1'b1
                                };
                            end else begin
                                data_cache_addr_q <= {
                                    pending_line_idx_q,
                                    axi_beat_q + 1'b1
                                };
                            end
                        end
                        axi_beat_q <= axi_beat_q + 1'b1;
                        if (m_axi_rlast) begin
                            if (pending_is_code_q) begin
                                code_valid_q[pending_line_idx_q] <= 1'b1;
                                state_q <= FILL_DONE;
                            end else begin
                                data_valid_q[pending_line_idx_q] <= 1'b1;
                                // Read-allocate: if original request was a
                                // write, apply it now.  Set BRAM address
                                // to the beat containing the write target
                                // (WRITE_R_SETUP will use it next cycle).
                                if (pending_we_q) begin
                                    state_q <= WRITE_R_SETUP;
                                end else begin
                                    state_q <= FILL_DONE;
                                end
                            end
                        end
                    end
                end

                // ===== FILL_DONE =====
                // Drain cycle: let BRAM output settle.  data_cache_dout
                // at the start of this cycle still has data from the last
                // fill beat (address {line, 7}).  We hold one cycle so
                // BRAM reads the address set via default {line_idx, beat_idx}
                // in the previous cycle (FILL_R's last beat).
                FILL_DONE: begin
                    state_q <= IDLE;
                end

                // ===== WRITE_R_SETUP =====
                // Set BRAM address to the beat containing the write target.
                // Used when coming from read-allocate (FILL_R) — the BRAM
                // address is still pointing at the last fill beat.
                WRITE_R_SETUP: begin
`ifndef SYNTHESIS
                    $display("[%0d] WRITE_R_SETUP: addr_q <= {line=%d, beat=%d}",
                        debug_cycle_q, pending_line_idx_q, pending_beat_idx_q);
`endif
                    data_cache_addr_q <= {pending_line_idx_q, pending_beat_idx_q};
                    state_q           <= WRITE_R;
                end

                // ===== WRITE_R =====
                // BRAM output has the current beat (address was set in the
                // previous cycle, either by the IDLE default or WRITE_R_SETUP).
                // Latch it into the merge register.
                WRITE_R: begin
`ifndef SYNTHESIS
                    $display("[%0d] WRITE_R: data_cache_dout=%016h", debug_cycle_q, data_cache_dout);
`endif
                    write_merge_q <= data_cache_dout;
                    state_q       <= WRITE_COMMIT;
                end

                // ===== WRITE_COMMIT =====
                // Merge byte into captured beat and write back to BRAM.
                // Single expression avoids non-blocking merge races.
                WRITE_COMMIT: begin
`ifndef SYNTHESIS
                    $display("[%0d] WRITE_COMMIT: merge_q=%016h byte=%d wdata=%02h",
                        debug_cycle_q, write_merge_q, pending_byte_idx_q, pending_wdata_q);
`endif
                    data_dirty_q[pending_line_idx_q] <= 1'b1;
                    // Keep BRAM address fixed (override default from req_addr
                    // which may have changed).
                    data_cache_addr_q <= {pending_line_idx_q, pending_beat_idx_q};
                    // Stall one cycle so data_cache_dout reflects the new
                    // BRAM data (comb read path on the next cycle sees
                    // stale dout from before the write).
                    write_stall_q      <= 1'b1;
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase


        end
    end

// ---- BRAM code cache (separate always_ff for Vivado inference) ------------
// Vivado's BRAM inference engine needs a clean read-first pattern in its
// own always_ff block.  The write-enable and write-data are combinatorial
// signals computed from the FSM state above.
always_ff @(posedge clk) begin
    if (code_we)
        code_cache[code_cache_addr_q] <= m_axi_rdata;
    code_cache_dout <= code_cache[code_cache_addr_q];
end

// ---- BRAM data cache (separate always_ff for Vivado inference) ------------
always_ff @(posedge clk) begin
    if (data_we)
        data_cache[data_cache_addr_q] <= data_cache_din;
    data_cache_dout <= data_cache[data_cache_addr_q];
end


    // ---- AXI master assignments -------------------------------------------
    // Read channel (fill)
    wire [AXI_ADDR_W-1:0] fill_line_base = {pending_addr_q[AXI_ADDR_W-1:6], 6'b0};

    assign m_axi_araddr  = fill_line_base;
    assign m_axi_arlen   = 8'd7;
    assign m_axi_arsize  = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (state_q == FILL_AR);
    assign m_axi_rready  = (state_q == FILL_R);

    // Write channel (flush) — 8-beat INCR, full line write-back.
    // Address = {old_page_base, line_idx, 6'b0}
    wire [AXI_ADDR_W-1:0] flush_line_addr = {
        data_page_base_q[AXI_ADDR_W-1:14],
        pending_line_idx_q,
        6'b0
    };

    assign m_axi_awaddr  = flush_line_addr;
    assign m_axi_awlen   = 8'd7;
    assign m_axi_awsize  = 3'd3;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state_q == DATA_FLUSH_AR);
    assign m_axi_wdata   = (state_q == DATA_FLUSH_W) ? flush_buf[axi_beat_q] : data_cache_dout;
    assign m_axi_wstrb   = 8'hFF;
    assign m_axi_wlast   = (state_q == DATA_FLUSH_W) && (axi_beat_q == 7);
    assign m_axi_wvalid  = (state_q == DATA_FLUSH_W);
    assign m_axi_bready  = (state_q == DATA_FLUSH_B);

    // ---- Read-data path ---------------------------------------------------
    wire [63:0] hit_beat = curr_is_code ? code_cache_dout : data_cache_dout;
    wire [7:0]  hit_byte = hit_beat[byte_idx * 8 +: 8];
    wire [7:0]  fill_byte = m_axi_rdata[pending_byte_idx_q * 8 +: 8];

    wire fill_deliver = (state_q == FILL_R) && m_axi_rvalid &&
                        (axi_beat_q == pending_beat_idx_q);

    // read_hit_ready and code_write_nop gate on !write_stall_q: during
    // the stall cycle after a write, the comb read path still sees stale
    // dout from just before the write, so the CPU must stall until dout
    // catches up (the write_stall cycle gives the BRAM read a chance to
    // sample the committed write data).
    wire read_hit_ready    = (state_q == IDLE) && read_hit_w && !write_stall_q;
    wire write_commit_done = (state_q == WRITE_COMMIT);
    wire code_write_nop    = (state_q == IDLE) && req_valid && req_we && curr_is_code && !write_stall_q;

    assign req_rdata = fill_deliver      ? fill_byte :
                       write_commit_done ? pending_wdata_q :
                       read_hit_ready    ? hit_byte  :
                                           hit_byte;
    assign req_ready  = read_hit_ready || fill_deliver ||
                        write_commit_done || code_write_nop;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (read_hit_ready) begin
            $display("[%0d] READ HIT: addr=%h line=%d beat=%d byte=%d dout=%016h byte_val=%02h",
                debug_cycle_q, req_addr, line_idx, beat_idx, byte_idx,
                hit_beat, hit_byte);
        end
        if (fill_deliver) begin
            $display("[%0d] FILL DELIVER: addr=%h byte=%d val=%02h",
                debug_cycle_q, req_addr, pending_byte_idx_q, fill_byte);
        end
    end
`endif

endmodule

`default_nettype wire
