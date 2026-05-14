// bank_cache.sv — N-way set-associative bank cache for the SALLY
// $4000-$7FFF window.
//
// M-cache-rework Step 2 refactor: unified `block_addr` decomposition
// so the set index can include bank-id LSBs and the cache geometry can
// scale to 64 KB with 1 KB lines / 16 sets / 4 ways without widening
// `cpu_offset` past 12 bits.
//
// M-cache-rework Step 5 refactor: HR port switched from byte-at-a-time
// to a burst handshake. The cache now issues a single `hr_req` pulse
// per refill / writeback with `hr_addr` + `hr_we` + `hr_burst_len`
// (= N-1 bytes), and the HR controller streams bytes back-to-back via
// `hr_rdata` + `hr_rvalid` (read) or accepts them per-cycle via
// `hr_wdata` (write). `hr_done` pulses on the last byte of the burst.
// Effective fill rate goes from 1 byte / 2 clk_bus cycles (handshake-
// limited) to 1 byte / clk_bus cycle — halves the SALLY-cycle stall
// per miss. (A future ram_clk → clk_bus CDC FIFO + DDR-rate HR data
// path can lift this to ~2 bytes / clk_bus cycle, matching HR's
// 400 MB/s ceiling at fMax.)
//
// Address model
// -------------
// The cache covers a flat (bank_id, sub_block) address space. Any line
// in the cache is uniquely identified by `block_addr = {bank_id,
// sub_block_idx}` where:
//
//   sub_block_idx = cpu_offset[CPU_OFFSET_W-1 : BYTE_OFFSET_W]
//                   (which 1<<BYTE_OFFSET_W chunk inside the bank)
//   block_addr    = {cpu_bank_id, sub_block_idx}      (BLOCK_ADDR_W bits)
//   set_idx       = block_addr[SET_W-1:0]             (low SET_W bits)
//   tag_v         = block_addr[BLOCK_ADDR_W-1:SET_W]  (the rest)
//   byte_off      = cpu_offset[BYTE_OFFSET_W-1:0]
//
// For the M24-3 geometry (NUM_SETS=4, NUM_WAYS=4, LINE_BYTES=64,
// CPU_OFFSET_W=12, BANK_ID_W=8) the decomposition reduces to the
// previous layout: set_idx = cpu_offset[7:6], tag_v = {bank_id[7:0],
// cpu_offset[11:8]} (12 bits). Functionally identical to the old
// {addr_tag, bank_id} tag — same set/hit behavior.
//
// For the M-cache-rework Step 2 geometry (NUM_SETS=16, NUM_WAYS=4,
// LINE_BYTES=1024, CPU_OFFSET_W=12, BANK_ID_W=8): set_idx =
// {bank_id[1:0], cpu_offset[11:10]} (4 bits), tag_v = bank_id[7:2]
// (6 bits). Each bank's 4 sub-blocks distribute across 4 different
// sets, so a single bank fully fits in the cache without self-
// conflict. 4-way associativity allows up to 4 distinct banks-with-
// the-same-bank_id[1:0] to coexist per set.
//
// HR address layout
// -----------------
// `hr_addr = {pad, bank_id, sub_block_idx, byte_off}` — i.e. the
// cache addresses HyperRAM as a linear array indexed by full
// (bank_id, cpu_offset). Geometry-independent.
//
// Pipeline (1-cycle hit latency, BRAM-mapped):
//
//   Cycle N:    cpu_offset / cpu_bank_id presented (registered upstream
//               via sally_core.AB → sally_mem). Combinational tag-match
//               across NUM_WAYS yields hit_vec / hit_way / any_hit.
//               Per-way speculative BRAM read at {set_idx, byte_off}.
//   Cycle N+1:  data_rd_q[w] now holds cycle-N's read result for each
//               way. cpu_rdata = data_rd_q[hit_way_q] (the hit way
//               registered at the same posedge). ANTIC's RDY contract
//               (data on N+1 from addr on N) holds.
//
// Misses go through the existing EVICT / FETCH / INSTALL FSM. INSTALL
// seeds hit_way_q + data_rd_q[miss_way_q] so the CPU sees the
// just-installed byte on the cycle that cpu_ready returns to 1 (no
// extra "post-install hit" lookup cycle).

`default_nettype none

module bank_cache #(
    parameter int unsigned NUM_SETS     = 4,
    parameter int unsigned NUM_WAYS     = 4,
    parameter int unsigned LINE_BYTES   = 64,
    parameter int unsigned CPU_OFFSET_W = 12,
    parameter int unsigned BANK_ID_W    = 8,
    parameter int unsigned HR_ADDR_W    = 23,

    // M-cache-rework Step 7 wide-data path: HR refill / writeback
    // commits WORD_BYTES bytes per cycle (1 = legacy byte-wide,
    // 2 = production target = 2× refill speed). Larger values are
    // bounded by the BRAM aspect ratio (EFX_RAM10 max width 20 bits;
    // > 16-bit costs multiple BRAMs per cache memory).
    parameter int unsigned WORD_BYTES   = 1,

    // Derived widths — declared as parameters so iverilog / Synplify
    // both accept them in port-list expressions.
    parameter int unsigned BYTE_OFFSET_W      = $clog2(LINE_BYTES),
    parameter int unsigned SET_W              = $clog2(NUM_SETS),
    parameter int unsigned WAY_W              = $clog2(NUM_WAYS),
    parameter int unsigned NUM_SUB_BLOCK_BITS = CPU_OFFSET_W - BYTE_OFFSET_W,
    parameter int unsigned BLOCK_ADDR_W       = BANK_ID_W + NUM_SUB_BLOCK_BITS,
    parameter int unsigned TAG_W              = BLOCK_ADDR_W - SET_W,
    parameter int unsigned WAY_DEPTH          = NUM_SETS * LINE_BYTES,
    parameter int unsigned WAY_ADDR_W         = $clog2(WAY_DEPTH),
    // Wide-data derived widths.
    parameter int unsigned LINE_WORDS         = LINE_BYTES / WORD_BYTES,
    parameter int unsigned WORD_OFFSET_W      = $clog2(LINE_WORDS),
    parameter int unsigned HR_DATA_W          = WORD_BYTES * 8
) (
    input  wire                       clk,
    input  wire                       rst,

    input  wire [CPU_OFFSET_W-1:0]    cpu_offset,
    input  wire [BANK_ID_W-1:0]       cpu_bank_id,
    input  wire [7:0]                 cpu_wdata,
    input  wire                       cpu_we,
    input  wire                       cpu_req,
    output wire [7:0]                 cpu_rdata,
    output wire                       cpu_ready,

    // ---- HR-side burst handshake (M-cache-rework Step 5 / Step 7) ---
    //
    // Read-burst protocol:
    //   - cache pulses hr_req=1 for one cycle with hr_addr=start,
    //     hr_we=0, hr_burst_len=N-1 (number of WORDs minus 1, where
    //     a WORD is WORD_BYTES bytes).
    //   - controller responds with hr_rdata + hr_rvalid pulses, one
    //     per word (WORD_BYTES bytes per pulse), in address order.
    //   - hr_done pulses on the same cycle as the last hr_rvalid.
    //
    // Write-burst protocol:
    //   - cache pulses hr_req=1 for one cycle with hr_addr=start,
    //     hr_we=1, hr_burst_len=N-1, hr_wdata=word0.
    //   - on each subsequent cycle the cache holds the next word on
    //     hr_wdata; controller consumes them at clk_bus rate.
    //   - hr_done pulses on the cycle the controller commits the last
    //     word.
    //
    // hr_addr and hr_burst_len carry the address in BYTES — the
    // controller is byte-addressed externally even when WORD_BYTES > 1
    // for the cache's internal data path. The bridge / controller
    // packs WORD_BYTES bytes per beat of the HR transaction.
    output logic [HR_ADDR_W-1:0]      hr_addr,
    output logic [WORD_OFFSET_W-1:0]  hr_burst_len,
    output logic [HR_DATA_W-1:0]      hr_wdata,
    output logic                      hr_we,
    output logic                      hr_req,
    input  wire  [HR_DATA_W-1:0]      hr_rdata,
    input  wire                       hr_rvalid,
    input  wire                       hr_done
);

    // ---- Address decode (combinational, from registered inputs) -------
    wire [BYTE_OFFSET_W-1:0]      byte_off      = cpu_offset[BYTE_OFFSET_W-1:0];
    wire [NUM_SUB_BLOCK_BITS-1:0] sub_block_idx = cpu_offset[CPU_OFFSET_W-1:BYTE_OFFSET_W];
    wire [BLOCK_ADDR_W-1:0]       block_addr    = {cpu_bank_id, sub_block_idx};
    wire [SET_W-1:0]              set_idx       = block_addr[SET_W-1:0];
    wire [TAG_W-1:0]              tag_v         = block_addr[BLOCK_ADDR_W-1:SET_W];

    // ---- Tag / valid / dirty (per-way, per-set) -----------------------
    logic [TAG_W-1:0]        tag    [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic                    valid  [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic                    dirty  [0:NUM_WAYS-1][0:NUM_SETS-1];

    // ---- Combinational hit detection ----------------------------------
    logic [NUM_WAYS-1:0] hit_vec;
    genvar gw;
    generate
        for (gw = 0; gw < NUM_WAYS; gw++) begin : g_hit
            assign hit_vec[gw] = valid[gw][set_idx] && (tag[gw][set_idx] == tag_v);
        end
    endgenerate

    wire any_hit = |hit_vec;

    logic [WAY_W-1:0] hit_way;
    integer pe_i;
    always_comb begin
        hit_way = '0;
        for (pe_i = NUM_WAYS - 1; pe_i >= 0; pe_i--)
            if (hit_vec[pe_i]) hit_way = WAY_W'(pe_i);
    end

    // ---- Speculative-read pipeline registers --------------------------
    // data_rd_q[w] holds the speculative BRAM read of way w from the
    // PREVIOUS cycle's address (byte-wide for cpu_rdata via the
    // cache_line_ram byte mux). data_rd_word_q[w] is the wide-view
    // of the same registered read — used by EVICT_STREAM to ship
    // WORD_BYTES bytes per cycle to HR.
    logic [7:0]            data_rd_q       [0:NUM_WAYS-1];
    logic [HR_DATA_W-1:0]  data_rd_word_q  [0:NUM_WAYS-1];
    logic [WAY_W-1:0] hit_way_q;

    // Post-INSTALL override: holds the just-installed byte for one
    // cycle after INSTALL completes, so the CPU sees the right value
    // at cpu_ready=1. This bypass keeps the data_rd_q always_ff a pure
    // BRAM-inferable read template (no conditional override mixed in).
    logic [7:0]       post_install_q;
    logic             post_install_valid_q;

    assign cpu_rdata = post_install_valid_q
                       ? post_install_q
                       : data_rd_q[hit_way_q];

    // Read-address mux is declared further down (after the FSM-state
    // register declarations); see `rd_set_idx` / `rd_byte_off`.

    // ---- Refill FSM ---------------------------------------------------
    //
    // Step 5 collapses the old per-byte FETCH / FETCH_WAIT pair into
    // a single FETCH_WAIT (the burst handshake makes the 1-cycle
    // FETCH-state pause unnecessary — hr_req is asserted in the
    // transition INTO FETCH_WAIT and the controller streams responses
    // until hr_done fires). The FETCH enum value is retained as a
    // noop for ABI stability of the state encoding (some wave-dump
    // configs read it back).
    typedef enum logic [2:0] {
        IDLE,
        EVICT_PREP,         // 1-cycle wait for first byte to land in data_rd_q
        EVICT_STREAM,       // pipeline-stream eviction bytes via data_rd_q
        EVICT_DRAIN,        // wait for last HR write to complete (hr_done)
        FETCH,              // unused; reserved for future use
        FETCH_WAIT,         // streaming receive of read-burst bytes
        INSTALL
    } state_t;

    state_t                    state_q;
    logic [WAY_W-1:0]          victim_way_q;
    logic [SET_W-1:0]          victim_set_q;
    logic [WAY_W-1:0]          rr_q [0:NUM_SETS-1];
    // burst_q indexes WORDS within a line (LINE_WORDS deep), not
    // bytes — at WORD_BYTES=2 each cycle of FETCH_WAIT/EVICT_STREAM
    // moves 2 bytes.
    logic [WORD_OFFSET_W-1:0]  burst_q;

    // Latched original miss request (replayed at INSTALL).
    logic [BYTE_OFFSET_W-1:0]  miss_byte_off_q;
    logic [SET_W-1:0]          miss_set_q;
    logic [TAG_W-1:0]          miss_tag_q;
    logic [7:0]                miss_wdata_q;
    logic                      miss_we_q;
    logic [WAY_W-1:0]          miss_way_q;
    logic [7:0]                miss_loaded_byte_q;  // byte at miss_byte_off, captured during FETCH_WAIT

    assign cpu_ready = (state_q == IDLE);

    // ---- Read-address mux (declared here, after state_q + victim_*_q
    // are in scope). EVICT path takes priority because cache_cpu_ready
    // is 0 during eviction; the speculative-read pipeline can be
    // repurposed without disturbing CPU visibility.
    //
    // During EVICT_PREP: read word 0 of victim line.
    // During EVICT_STREAM: pre-fetch the NEXT word (burst_q+1) so it
    // is available in data_rd_word_q on the cycle we issue the
    // current word.
    //
    // The cache_line_ram inside each way takes a byte-level address
    // and internally splits into word-address + byte-offset. We
    // synthesise the byte address by shifting the word index left by
    // log2(WORD_BYTES) — for WORD_BYTES=1 the shift is zero and the
    // legacy semantics return.
    localparam int unsigned WORD_BYTE_OFF_W = (WORD_BYTES > 1) ? $clog2(WORD_BYTES) : 1;

    wire [SET_W-1:0]         rd_set_idx  = (state_q == EVICT_PREP || state_q == EVICT_STREAM)
                                            ? victim_set_q : set_idx;
    wire [BYTE_OFFSET_W-1:0] rd_byte_off = (state_q == EVICT_PREP)
                                            ? '0
                                          : (state_q == EVICT_STREAM)
                                            ? BYTE_OFFSET_W'((burst_q + 1'b1) << (WORD_BYTES > 1 ? WORD_BYTE_OFF_W : 0))
                                            : byte_off;

    // ---- HR address composition ---------------------------------------
    // Linear: hr_addr = {pad, bank_id, sub_block_idx, byte_off}
    //                 = {pad, block_addr, byte_off}.
    // Recover (bank_id, sub_block_idx) from a stored (tag, set_idx) by
    // stitching them back into block_addr.
    function automatic [HR_ADDR_W-1:0] hr_line_addr(
        input [TAG_W-1:0]         t,
        input [SET_W-1:0]         si,
        input [BYTE_OFFSET_W-1:0] bo
    );
        logic [BLOCK_ADDR_W-1:0] ba;
        ba = {t, si};
        hr_line_addr = {{(HR_ADDR_W - BLOCK_ADDR_W - BYTE_OFFSET_W){1'b0}}, ba, bo};
    endfunction

    integer init_w, init_s;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q          <= IDLE;
            burst_q          <= '0;
            miss_byte_off_q  <= '0;
            miss_set_q       <= '0;
            miss_tag_q       <= '0;
            miss_wdata_q     <= 8'h00;
            miss_we_q        <= 1'b0;
            miss_way_q       <= '0;
            miss_loaded_byte_q <= 8'h00;
            victim_way_q     <= '0;
            victim_set_q     <= '0;
            hit_way_q        <= '0;
            post_install_q       <= 8'h00;
            post_install_valid_q <= 1'b0;
            hr_addr          <= '0;
            hr_burst_len     <= '0;
            hr_wdata         <= 8'h00;
            hr_we            <= 1'b0;
            hr_req           <= 1'b0;
            for (init_s = 0; init_s < NUM_SETS; init_s++) rr_q[init_s] <= '0;
            for (init_w = 0; init_w < NUM_WAYS; init_w++) begin
                for (init_s = 0; init_s < NUM_SETS; init_s++) begin
                    valid[init_w][init_s] <= 1'b0;
                    dirty[init_w][init_s] <= 1'b0;
                    tag[init_w][init_s]   <= '0;
                end
            end
        end else begin
            // hit_way_q tracks WHICH way's data_rd_q to return on the
            // cycle the read result is consumed.
            hit_way_q <= hit_way;

            // post_install override is a 1-cycle bypass: cleared on the
            // cycle the CPU consumes a request (cpu_ready was high).
            if (post_install_valid_q && cpu_req)
                post_install_valid_q <= 1'b0;

            // hr_req is a 1-cycle pulse — defaults to 0 each cycle and
            // is asserted only on the cycle a new burst is initiated.
            hr_req <= 1'b0;

            unique case (state_q)
                IDLE: if (cpu_req) begin
                    if (any_hit) begin
                        // ---- HIT — write commits in the per-way generate
                        // block (`g_data[hit_way].mem`). Dirty flag still
                        // tracked here.
                        if (cpu_we) begin
                            dirty[hit_way][set_idx] <= 1'b1;
                        end
                    end else begin
                        // ---- MISS — start refill ----
                        miss_byte_off_q  <= byte_off;
                        miss_set_q       <= set_idx;
                        miss_tag_q       <= tag_v;
                        miss_wdata_q     <= cpu_wdata;
                        miss_we_q        <= cpu_we;
                        miss_way_q       <= rr_q[set_idx];
                        rr_q[set_idx]    <= rr_q[set_idx] + 1'b1;
                        burst_q          <= '0;
                        if (valid[rr_q[set_idx]][set_idx] && dirty[rr_q[set_idx]][set_idx]) begin
                            // Dirty victim — writeback first. Don't issue HR yet;
                            // EVICT_PREP gives data_rd_q[victim] one cycle to settle
                            // with byte 0 of the victim line.
                            state_q      <= EVICT_PREP;
                            victim_way_q <= rr_q[set_idx];
                            victim_set_q <= set_idx;
                            // burst_q already 0 (set above).
                        end else begin
                            // Clean victim — issue read-burst, jump straight
                            // to FETCH_WAIT to receive WORDs.
                            state_q      <= FETCH_WAIT;
                            hr_addr      <= hr_line_addr(tag_v, set_idx, '0);
                            hr_we        <= 1'b0;
                            hr_burst_len <= WORD_OFFSET_W'(LINE_WORDS - 1);
                            hr_req       <= 1'b1;
                        end
                    end
                end

                EVICT_PREP: begin
                    // 1-cycle wait. The speculative-read pipeline's rd_addr
                    // mux is now pointing at {victim_set_q, 0}, so at THIS
                    // cycle's posedge data_rd_q[victim_way_q] gets byte 0.
                    // Move to STREAM next.
                    state_q <= EVICT_STREAM;
                end

                EVICT_STREAM: begin
                    // Stream WORD burst_q out as hr_wdata. Each cycle the
                    // controller consumes WORD_BYTES bytes. hr_req is
                    // pulsed only on the FIRST cycle (burst_q==0) along
                    // with the burst-setup signals (hr_addr, hr_we,
                    // hr_burst_len). data_rd_word_q[victim_way_q] holds
                    // the WORD at burst_q (1-cycle BRAM read latency —
                    // see the rd_byte_off mux that pre-fetches word
                    // burst_q+1).
                    hr_wdata <= data_rd_word_q[victim_way_q];
                    if (burst_q == '0) begin
                        hr_addr      <= hr_line_addr(
                            tag[victim_way_q][victim_set_q],
                            victim_set_q,
                            '0);
                        hr_we        <= 1'b1;
                        hr_burst_len <= WORD_OFFSET_W'(LINE_WORDS - 1);
                        hr_req       <= 1'b1;
                    end

                    if (burst_q == WORD_OFFSET_W'(LINE_WORDS - 1)) begin
                        // Just queued the last word. Wait for the
                        // controller to ack it via hr_done.
                        state_q <= EVICT_DRAIN;
                    end else begin
                        burst_q <= burst_q + 1'b1;
                    end
                end

                EVICT_DRAIN: if (hr_done) begin
                    // Writeback complete. Issue the read-burst to fetch
                    // the new line.
                    burst_q      <= '0;
                    state_q      <= FETCH_WAIT;
                    hr_addr      <= hr_line_addr(miss_tag_q, miss_set_q, '0);
                    hr_we        <= 1'b0;
                    hr_burst_len <= WORD_OFFSET_W'(LINE_WORDS - 1);
                    hr_req       <= 1'b1;
                end

                FETCH: begin
                    // Reserved enum value — not entered by current FSM.
                    // Drop back to IDLE if ever reached (e.g. via post-
                    // reset undefined-state recovery).
                    state_q <= IDLE;
                end

                FETCH_WAIT: begin
                    // Capture each WORD as it arrives.
                    // miss_loaded_byte_q pins the requested byte (the
                    // one within the WORD whose offset matches
                    // miss_byte_off_q's word index) for the post-INSTALL
                    // bypass. miss_byte_off_q is byte-level; we split it
                    // into word-index (high bits) and byte-in-word
                    // (low bits) for the capture.
                    if (hr_rvalid) begin
                        if (WORD_BYTES == 1) begin
                            if (burst_q == miss_byte_off_q[WORD_OFFSET_W-1:0])
                                miss_loaded_byte_q <= hr_rdata[7:0];
                        end else begin
                            // Word index = miss_byte_off_q[BYTE_OFFSET_W-1 : WORD_BYTE_OFF_W].
                            // Byte-in-word = miss_byte_off_q[WORD_BYTE_OFF_W-1 : 0].
                            if (burst_q == miss_byte_off_q[BYTE_OFFSET_W-1:WORD_BYTE_OFF_W]) begin
                                miss_loaded_byte_q <= hr_rdata[
                                    miss_byte_off_q[WORD_BYTE_OFF_W-1:0]*8 +: 8];
                            end
                        end
                        burst_q <= burst_q + 1'b1;
                    end
                    // Burst end is signalled coincident with the last
                    // hr_rvalid pulse — controller drives hr_done = 1
                    // for one cycle on the final word.
                    if (hr_done) begin
                        state_q <= INSTALL;
                    end
                end

                INSTALL: begin
                    tag[miss_way_q][miss_set_q]   <= miss_tag_q;
                    valid[miss_way_q][miss_set_q] <= 1'b1;
                    dirty[miss_way_q][miss_set_q] <= miss_we_q;
                    // miss_wdata_q write also commits in the per-way generate block.
                    // Seed post_install_q with the byte to return on
                    // the cycle cpu_ready returns to 1. cpu_rdata mux
                    // picks this over data_rd_q for that one cycle.
                    post_install_q       <= miss_we_q ? miss_wdata_q : miss_loaded_byte_q;
                    post_install_valid_q <= 1'b1;
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

    // ---- Per-way data + read pipeline -------------------------------
    // Each iteration instantiates a cache_line_ram — a portable
    // wrapper around an EFX_RAM10 (or vendor equivalent) configured
    // for byte-wide read + WORD_BYTES-wide write. Three writers (CPU
    // hit, refill, install) are muxed into a SINGLE write port per
    // memory so the BRAM stays 1R+1W; CPU hit / install writes use
    // we_mask to update only the target byte lane while refill writes
    // the full word at once.
    localparam int unsigned WORD_DEPTH = NUM_SETS * LINE_WORDS;
    genvar gw_data;
    generate
        for (gw_data = 0; gw_data < NUM_WAYS; gw_data++) begin : g_data

            logic [WORD_BYTES-1:0]               we_mask;
            logic [SET_W+WORD_OFFSET_W-1:0]      waddr_word;
            logic [HR_DATA_W-1:0]                wdata_wide;

            always_comb begin
                we_mask    = '0;
                waddr_word = '0;
                wdata_wide = '0;

                // CPU hit-write — single byte at byte_off within the
                // target word. We replicate cpu_wdata across all lanes;
                // we_mask selects which lane actually commits.
                if (state_q == IDLE && cpu_req && cpu_we && hit_vec[gw_data]) begin
                    if (WORD_BYTES == 1) begin
                        we_mask    = 1'b1;
                        waddr_word = {set_idx, byte_off[WORD_OFFSET_W-1:0]};
                    end else begin
                        we_mask    = WORD_BYTES'(1) << byte_off[WORD_BYTE_OFF_W-1:0];
                        waddr_word = {set_idx, byte_off[BYTE_OFFSET_W-1:WORD_BYTE_OFF_W]};
                    end
                    wdata_wide = {WORD_BYTES{cpu_wdata}};
                end
                // Refill burst write — one WORD per hr_rvalid pulse,
                // every byte lane enabled.
                else if (state_q == FETCH_WAIT && hr_rvalid
                         && miss_way_q == gw_data[WAY_W-1:0]) begin
                    we_mask    = '1;
                    waddr_word = {miss_set_q, burst_q};
                    wdata_wide = hr_rdata;
                end
                // Install write of the original miss byte.
                else if (state_q == INSTALL && miss_we_q
                         && miss_way_q == gw_data[WAY_W-1:0]) begin
                    if (WORD_BYTES == 1) begin
                        we_mask    = 1'b1;
                        waddr_word = {miss_set_q, miss_byte_off_q[WORD_OFFSET_W-1:0]};
                    end else begin
                        we_mask    = WORD_BYTES'(1) << miss_byte_off_q[WORD_BYTE_OFF_W-1:0];
                        waddr_word = {miss_set_q, miss_byte_off_q[BYTE_OFFSET_W-1:WORD_BYTE_OFF_W]};
                    end
                    wdata_wide = {WORD_BYTES{miss_wdata_q}};
                end
            end

            cache_line_ram #(
                .WORD_BYTES (WORD_BYTES),
                .DEPTH      (WORD_DEPTH)
            ) u_mem (
                .clk     (clk),
                .re      (1'b1),
                .raddr   ({rd_set_idx, rd_byte_off}),
                .rdata   (data_rd_q[gw_data]),
                .rd_word (data_rd_word_q[gw_data]),
                .we_mask (we_mask),
                .waddr   (waddr_word),
                .wdata   (wdata_wide)
            );
        end
    endgenerate

endmodule

`default_nettype wire
