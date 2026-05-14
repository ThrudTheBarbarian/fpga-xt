// sally_mem.sv — SALLY memory subsystem (M24-2..M24-4 stage).
//
// CPU's view of memory in tiered form:
//
//   $0000-$3FFF  Direct BRAM (zero page + stack + main RAM lo)
//   $4000-$7FFF  Bank cache window — bank_cache.sv with 16 lines.
//                bank_xlat translates (cpu_addr, bank-select state,
//                view) into a 16-bit bank_id. CPU bank-select state
//                is snooped from zero-page $0082-$0085. ANTIC's view
//                comes from chiplet-ext registers $D488-$D48B.
//   $8000-$BFFF  Direct BRAM (main RAM hi)
//   $C000-$CFFF  OS ROM lo (loadable, M24-6)
//   $D000-$D7FF  Hardware-register page — combinational override of
//                BRAM. Receiver (GTIA / ANTIC / POKEY) supplies
//                hwreg_dout combinationally; sally_mem registers it
//                alongside the BRAM read so both share the N → N+1
//                pipeline.
//   $D800-$FFFF  OS ROM hi (loadable, M24-6)
//
// Pipeline summary:
//   Cycle N: cpu_addr = X presented (combinational from CPU state).
//   Cycle N posedge: bram_dout_q ← mem[X];
//                    hwreg_dout_q ← hwreg_dout (current cycle's);
//                    bank_cache cpu_req fires if X ∈ $4000-$7FFF;
//                    was_hwreg_q / was_bank_q latched.
//   Cycle N+1: data_out = was_hwreg_q ? hwreg_dout_q :
//                         was_bank_q  ? bank_cache.cpu_rdata :
//                                       bram_dout_q.
//
// Stall path:
//   When bank_cache misses, its cpu_ready drops to 0. sally_mem
//   exposes `busy` = !bank_cache.cpu_ready; sally_clock gates the
//   global rdy with this so SALLY freezes addr/data while the
//   cache walks its eviction + fetch FSM.
//
// rdy gating: BRAM/hwreg paths only update on rdy=1 (so Arlet's
// pipeline doesn't see data drift during stall windows). The
// bank_cache has its own internal RDY (cpu_ready); sally_mem only
// pulses cpu_req on rdy=1.

`default_nettype none

module sally_mem #(
    // Cache geometry — defaults sized for sim speed; production builds
    // override (16 sets × 4 ways × 1 KB lines = 64 KB total).
    parameter int unsigned CACHE_NUM_SETS   = 4,
    parameter int unsigned CACHE_NUM_WAYS   = 4,
    parameter int unsigned CACHE_LINE_BYTES = 64,
    parameter int unsigned CACHE_LINES      = CACHE_NUM_SETS * CACHE_NUM_WAYS,
    parameter int unsigned CACHE_LINE_W     = $clog2(CACHE_LINES),
    parameter int unsigned CACHE_OFFSET_W   = $clog2(CACHE_LINE_BYTES),
    // Streaming-bypass slot geometry (M-cache-rework Step 4). 2 sets ×
    // 2 ways per partition, same line size as the main cache. With the
    // production line size (1 KB) this is 4 KB per partition / 8 KB
    // total / 8 EFX_RAM10. Sized intentionally small: streaming
    // workloads sweep through a buffer faster than the partition cache
    // could promote, so the bypass just absorbs misses without
    // evicting hot partition lines.
    parameter int unsigned STREAM_NUM_SETS  = 2,
    parameter int unsigned STREAM_NUM_WAYS  = 2,
    // M-cache-rework Step 7 wide-data path. WORD_BYTES bytes commit
    // per HR refill cycle; the cache memory aspect ratio widens to
    // match. 1 = legacy byte-wide; 2 = production target (2× refill
    // speed, 1 BRAM per memory still).
    parameter int unsigned CACHE_WORD_BYTES = 1,
    // OS ROM image baked into the BRAM at synth/sim init via $readmemh.
    // Empty string = leave BRAM uninitialised (current sim behaviour).
    // Production builds override with a path to a 64 KB hex image
    // (one byte per line, addresses $0000..$FFFF — only $C000-$CFFF
    // and $D800-$FFFF need to be populated; the rest is overwritten
    // by RAM accesses). The runtime rom-load chiplet path ($D48C-$F)
    // remains usable on top of this for live OS swaps.
    parameter string       OS_ROM_HEX_PATH  = ""
) (
    input  wire        clk,
    input  wire        rst,

    // SALLY-side memory port.
    input  wire [15:0] addr,
    input  wire [7:0]  data_in,
    input  wire        rw,
    output logic [7:0] data_out,
    input  wire        rdy,
    output wire        busy,           // 1 when bank_cache miss-FSM in flight

    // Hardware-register passthrough.
    output wire [15:0] hwreg_addr,
    output wire        hwreg_we,
    output wire [7:0]  hwreg_din,
    input  wire [7:0]  hwreg_dout,

    // CPU bank-select state — latched from zero-page writes.
    // Exposed as outputs so antic_top can mirror to ANTIC's read path
    // if needed (currently only used internally by bank_xlat).
    output wire [7:0]  cpu_code_bank_q,
    output wire [7:0]  cpu_data_bank_q,
    output wire [7:0]  cpu_regc_bank_lo_q,
    output wire [7:0]  cpu_regc_bank_hi_q,

    // ANTIC-view bank-select state (from antic_regs $D488..$D48B).
    // Tie low for CPU-only configurations.
    input  wire [7:0]  antic_code_bank,
    input  wire [7:0]  antic_data_bank,
    input  wire [7:0]  antic_regc_bank_lo,
    input  wire [7:0]  antic_regc_bank_hi,

    // View selector — 0 = CPU view, 1 = ANTIC view.
    // The CPU-side instance ties this 0; the ANTIC read-mux instance
    // (when wired up at antic_top) ties it 1.
    input  wire        view_is_antic,

    // M-PBI step 2/3: /MPD Math-Pack Disable from the PBI device.
    // 2-FF synchronised into clk_bus by antic_top. Active-low (0 = a
    // PBI device wants to substitute its own RAM/ROM for $D800-$DFFF;
    // the FPGA's internal OS-ROM hi must mask off). When asserted,
    // reads in the $D800-$DFFF window return `bus_pbi_rdata` (the
    // 2-FF synced D[7:0] from the external bus, which the PBI device
    // is driving) instead of the BRAM contents.
    input  wire        bus_mpd_n_in,

    // M-PBI step 3: external bus D[7:0] sample, 2-FF synced + phi2-
    // fall-gated in antic_top (M-PBI deferred #1). Stable through phi2-
    // low so SALLY consumes a clean late-phi2-cycle value. Used as the
    // read response for both the /MPD-window override and the cart-
    // slot RD4/RD5-asserted override below.
    input  wire [7:0]  bus_pbi_rdata,

    // M-PBI deferred #2: cart-detect inputs (active-low; 0 = a physical
    // cart is plugged into the corresponding slot). 2-FF synced in
    // antic_top. When asserted, reads from the matching cart-window
    // range bypass the HyperRAM-cached cart bank and route to
    // `bus_pbi_rdata` so the physical cart wins over any emulated cart
    // image. Writes to those ranges still go through the cache (cart
    // hardware ignores writes; HR caches them harmlessly).
    input  wire        bus_rd4_n_in,   // $8000-$9FFF cart present
    input  wire        bus_rd5_n_in,   // $A000-$BFFF cart present

    // HyperRAM-side port — bank_cache uses this for line refills /
    // dirty writebacks. Burst protocol per M-cache-rework Step 5:
    // one hr_req pulse covers a full cache-line transfer (read or
    // write), with hr_burst_len = (LINE_BYTES/WORD_BYTES)-1 and per-
    // word data streamed via hr_rdata+hr_rvalid (read) or hr_wdata
    // (write). At Step 7 (CACHE_WORD_BYTES=2) one hr_rvalid pulse
    // delivers 2 bytes; the bridge / mock packs accordingly. hr_done
    // pulses on the last word of the burst.
    output wire [22:0]                          hr_addr,
    output wire [9:0]                           hr_burst_len,    // 10 bits → covers any LINE_WORDS up to 1024
    output wire                                 hr_we,
    output wire [CACHE_WORD_BYTES*8-1:0]        hr_wdata,
    output wire                                 hr_req,
    input  wire [CACHE_WORD_BYTES*8-1:0]        hr_rdata,
    input  wire                                 hr_rvalid,
    input  wire                                 hr_done,

    // M24-6 OS ROM load port. Pulse rom_we high for one cycle with
    // a valid rom_addr / rom_data to commit a byte directly into
    // the BRAM, bypassing the normal CPU write pipeline. Caller
    // (antic_regs) gates by WRITE_LOCK and address-range validity;
    // sally_mem just commits the write blindly. The rom_we pulse
    // must NOT collide with a CPU write to the same address (in
    // practice impossible — CPU is writing to $D48E in the hwreg
    // page when rom_we fires).
    input  wire [15:0] rom_addr,
    input  wire [7:0]  rom_data,
    input  wire        rom_we,

    // M-cache-rework Step 4 — per-bank attribute lookup.
    //
    // attr_lookup_idx is a 12-bit address into cache_regs's attribute
    // SRAM, composed combinationally from the live bank_id_w. The
    // composition matches cache_regs's internal attr_addr_q layout
    // ({region, bank_id_hi, bank_id_lo}) so software writes through
    // $D382-$D385 land on the same SRAM cell that the cache miss
    // path looks up.
    //
    // attr_lookup_data is the 4-bit attribute (read with 1-cycle
    // sync-BRAM latency in cache_regs). Bit assignments per
    // xtc/doc/large-allocations.md:
    //   bit 0 — reserved
    //   bit 1 — code-affinity hint (informational)
    //   bit 2 — streaming (route to bypass cache)
    //   bit 3 — spare
    //
    // Because the SRAM read is 1-cycle late, the routing decision on
    // the access cycle reflects the PRIOR cycle's bank — Option 1 of
    // the M-cache-rework Step 4 design (`docs/Issues.md`). First
    // access after a bank switch may route to the wrong cache; that
    // is functionally harmless and software contract is "≥3-cycle
    // gap between attribute-write and dependent access."
    output wire [11:0] attr_lookup_idx,
    input  wire [3:0]  attr_lookup_data
);

    // ---- Backing BRAM ($0000-$3FFF, $8000-$FFFF less hwreg page) ---
    logic [7:0] mem [0:65535];

    // BRAM init from a baked-in OS image when OS_ROM_HEX_PATH is set.
    // The hex file is a 65536-line one-byte-per-line image. For the
    // baked-in case it's typically only $C000-$CFFF (OS lo) and
    // $D800-$FFFF (OS hi) that hold real ROM; everything else can be
    // any value (RAM gets clobbered by software, hwreg page is
    // overridden combinationally). $readmemh() is a synth-time
    // construct on Efinity (Synplify maps it to BRAM init values).
    initial if (OS_ROM_HEX_PATH != "") $readmemh(OS_ROM_HEX_PATH, mem);

    // ---- Address-decode helpers -----------------------------------
    wire is_hwreg_page = (addr[15:11] == 5'b1101_0);   // $D000-$D7FF
    wire is_bank_window = (addr[15:14] == 2'b01);      // $4000-$7FFF

    // ---- CPU bank-select snoop -----------------------------------
    // Mirror writes to $0082-$0085 into latched registers so bank_xlat
    // sees the live values without needing a BRAM read port.
    logic [7:0] cpu_code_bank, cpu_data_bank;
    logic [7:0] cpu_regc_bank_lo, cpu_regc_bank_hi;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cpu_code_bank    <= 8'h00;
            cpu_data_bank    <= 8'h00;
            cpu_regc_bank_lo <= 8'h00;
            cpu_regc_bank_hi <= 8'h00;
        end else if (rdy && !rw) begin
            case (addr)
                16'h0082: cpu_code_bank    <= data_in;
                16'h0083: cpu_data_bank    <= data_in;
                16'h0084: cpu_regc_bank_lo <= data_in;
                16'h0085: cpu_regc_bank_hi <= data_in;
                default: ;
            endcase
        end
    end

    assign cpu_code_bank_q    = cpu_code_bank;
    assign cpu_data_bank_q    = cpu_data_bank;
    assign cpu_regc_bank_lo_q = cpu_regc_bank_lo;
    assign cpu_regc_bank_hi_q = cpu_regc_bank_hi;

    // ---- Bank translator -----------------------------------------
    wire [15:0] bank_id_w;
    wire [11:0] offset_in_block_w;
    wire        is_in_window_w;        // identical to is_bank_window when CPU view

    bank_xlat u_xlat (
        .cpu_code_bank      (cpu_code_bank),
        .cpu_data_bank      (cpu_data_bank),
        .cpu_regc_bank_lo   (cpu_regc_bank_lo),
        .cpu_regc_bank_hi   (cpu_regc_bank_hi),
        .antic_code_bank    (antic_code_bank),
        .antic_data_bank    (antic_data_bank),
        .antic_regc_bank_lo (antic_regc_bank_lo),
        .antic_regc_bank_hi (antic_regc_bank_hi),
        .cpu_addr           (addr),
        .view_is_antic      (view_is_antic),
        .is_in_window       (is_in_window_w),
        .offset_in_block    (offset_in_block_w),
        .bank_id            (bank_id_w)
    );

    // ---- bank_cache instances (M-cache-rework Step 4 — 4 quadrants) ---
    //
    // Four physically separate bank_caches arranged as
    // {code,data} × {partition,stream-bypass}:
    //
    //   u_bank_cache_code         partition  for $82-routed banks
    //   u_bank_cache_data         partition  for $83/$84/$85-routed banks
    //   u_bank_cache_code_stream  bypass     for streaming-tagged $82 banks
    //   u_bank_cache_data_stream  bypass     for streaming-tagged $83+ banks
    //
    // Routing classifiers:
    //
    //   is_code      = ~bank_id_w[15]                    (live, current cycle)
    //   is_streaming = attr_lookup_data[2]               (1-cycle stale —
    //                                                     see Step 4
    //                                                     "Option 1" note
    //                                                     in docs/Issues.md)
    //
    // CPU-side: cpu_req fires to exactly one of the four caches per
    // access. The other three see no req and stay IDLE. Because the
    // CPU stalls while ANY cache is non-IDLE, only one cache is ever
    // in the miss FSM at a time.
    //
    // HR-side: shared port across all four caches via 4-way priority
    // mux on hr_req. The inactive caches see hr_rdata / hr_done but
    // ignore it (their FSMs are IDLE).
    //
    // Geometry: partition caches at half-CACHE_NUM_SETS × CACHE_NUM_WAYS
    // (8 × 4 × 1 KB = 32 KB each at the antic_top defaults). Stream
    // caches at STREAM_NUM_SETS × STREAM_NUM_WAYS (2 × 2 × 1 KB = 4 KB
    // each, 8 KB total). Total cache footprint: 72 KB / 72 EFX_RAM10.
    wire cache_cpu_req = rdy && is_in_window_w;
    wire [7:0] cache_bank_id_8 = bank_id_w[7:0];      // see widening note in M-cache-rework
    wire       is_code_partition = (bank_id_w[15] == 1'b0);
    wire       is_data_partition = (bank_id_w[15] == 1'b1);

    // attr_lookup_idx composition — combinational from bank_id_w. The
    // layout is `{region[1:0], bank_id_hi[1:0], bank_id_lo[7:0]}`,
    // matching cache_regs's internal attr_addr_q so software writes
    // through $D382-$D385 land on the same SRAM cell.
    //
    // For region 00/01/10 (code lo / code hi / data) bank_id_w[9:8]
    // are zero (bank_xlat zero-pads the 8-bit selector). For region
    // 11 (regc) bank_id_w[9:8] = regc_bank_hi[1:0] and bank_id_w[7:0]
    // = regc_bank_lo (14-bit composite). Either way the index is
    // unique per (region, bank).
    assign attr_lookup_idx = {bank_id_w[15:14], bank_id_w[9:8], bank_id_w[7:0]};
    wire is_streaming = attr_lookup_data[2];

    wire       code_part_cpu_req = cache_cpu_req && is_code_partition && !is_streaming;
    wire       data_part_cpu_req = cache_cpu_req && is_data_partition && !is_streaming;
    wire       code_strm_cpu_req = cache_cpu_req && is_code_partition &&  is_streaming;
    wire       data_strm_cpu_req = cache_cpu_req && is_data_partition &&  is_streaming;

    wire [7:0] code_part_cpu_rdata, data_part_cpu_rdata;
    wire [7:0] code_strm_cpu_rdata, data_strm_cpu_rdata;
    wire       code_part_cpu_ready, data_part_cpu_ready;
    wire       code_strm_cpu_ready, data_strm_cpu_ready;

    wire [22:0] code_part_hr_addr,  data_part_hr_addr;
    wire [22:0] code_strm_hr_addr,  data_strm_hr_addr;
    wire [CACHE_WORD_BYTES*8-1:0] code_part_hr_wdata, data_part_hr_wdata;
    wire [CACHE_WORD_BYTES*8-1:0] code_strm_hr_wdata, data_strm_hr_wdata;
    wire        code_part_hr_we,    data_part_hr_we;
    wire        code_strm_hr_we,    data_strm_hr_we;
    wire        code_part_hr_req,   data_part_hr_req;
    wire        code_strm_hr_req,   data_strm_hr_req;

    // Step 5/7 burst handshake — bank_cache's hr_burst_len width is
    // WORD_OFFSET_W = $clog2(LINE_BYTES / WORD_BYTES). Per-cache wires
    // use that width; sally_mem's external port is fixed at 10 bits
    // (covers any LINE_WORDS up to 1024) with zero-extension.
    localparam int unsigned LINE_WORDS  = CACHE_LINE_BYTES / CACHE_WORD_BYTES;
    localparam int unsigned BURST_LEN_W = $clog2(LINE_WORDS);
    wire [BURST_LEN_W-1:0] code_part_hr_burst_len, data_part_hr_burst_len;
    wire [BURST_LEN_W-1:0] code_strm_hr_burst_len, data_strm_hr_burst_len;

    // Partition cache geometry — half NUM_SETS × full NUM_WAYS so each
    // partition still uses bank_id LSBs in the set index.
    localparam int unsigned PART_NUM_SETS = (CACHE_NUM_SETS > 1) ? CACHE_NUM_SETS / 2 : 1;

    bank_cache #(
        .NUM_SETS     (PART_NUM_SETS),
        .NUM_WAYS     (CACHE_NUM_WAYS),
        .LINE_BYTES   (CACHE_LINE_BYTES),
        .CPU_OFFSET_W (12),
        .BANK_ID_W    (8),
        .HR_ADDR_W    (23),
        .WORD_BYTES   (CACHE_WORD_BYTES)
    ) u_bank_cache_code (
        .clk          (clk),
        .rst          (rst),
        .cpu_offset   (offset_in_block_w),
        .cpu_bank_id  (cache_bank_id_8),
        .cpu_wdata    (data_in),
        .cpu_we       (code_part_cpu_req && !rw),
        .cpu_req      (code_part_cpu_req),
        .cpu_rdata    (code_part_cpu_rdata),
        .cpu_ready    (code_part_cpu_ready),
        .hr_addr      (code_part_hr_addr),
        .hr_burst_len (code_part_hr_burst_len),
        .hr_wdata     (code_part_hr_wdata),
        .hr_we        (code_part_hr_we),
        .hr_req       (code_part_hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done)
    );

    bank_cache #(
        .NUM_SETS     (PART_NUM_SETS),
        .NUM_WAYS     (CACHE_NUM_WAYS),
        .LINE_BYTES   (CACHE_LINE_BYTES),
        .CPU_OFFSET_W (12),
        .BANK_ID_W    (8),
        .HR_ADDR_W    (23),
        .WORD_BYTES   (CACHE_WORD_BYTES)
    ) u_bank_cache_data (
        .clk          (clk),
        .rst          (rst),
        .cpu_offset   (offset_in_block_w),
        .cpu_bank_id  (cache_bank_id_8),
        .cpu_wdata    (data_in),
        .cpu_we       (data_part_cpu_req && !rw),
        .cpu_req      (data_part_cpu_req),
        .cpu_rdata    (data_part_cpu_rdata),
        .cpu_ready    (data_part_cpu_ready),
        .hr_addr      (data_part_hr_addr),
        .hr_burst_len (data_part_hr_burst_len),
        .hr_wdata     (data_part_hr_wdata),
        .hr_we        (data_part_hr_we),
        .hr_req       (data_part_hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done)
    );

    bank_cache #(
        .NUM_SETS     (STREAM_NUM_SETS),
        .NUM_WAYS     (STREAM_NUM_WAYS),
        .LINE_BYTES   (CACHE_LINE_BYTES),
        .CPU_OFFSET_W (12),
        .BANK_ID_W    (8),
        .HR_ADDR_W    (23),
        .WORD_BYTES   (CACHE_WORD_BYTES)
    ) u_bank_cache_code_stream (
        .clk          (clk),
        .rst          (rst),
        .cpu_offset   (offset_in_block_w),
        .cpu_bank_id  (cache_bank_id_8),
        .cpu_wdata    (data_in),
        .cpu_we       (code_strm_cpu_req && !rw),
        .cpu_req      (code_strm_cpu_req),
        .cpu_rdata    (code_strm_cpu_rdata),
        .cpu_ready    (code_strm_cpu_ready),
        .hr_addr      (code_strm_hr_addr),
        .hr_burst_len (code_strm_hr_burst_len),
        .hr_wdata     (code_strm_hr_wdata),
        .hr_we        (code_strm_hr_we),
        .hr_req       (code_strm_hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done)
    );

    bank_cache #(
        .NUM_SETS     (STREAM_NUM_SETS),
        .NUM_WAYS     (STREAM_NUM_WAYS),
        .LINE_BYTES   (CACHE_LINE_BYTES),
        .CPU_OFFSET_W (12),
        .BANK_ID_W    (8),
        .HR_ADDR_W    (23),
        .WORD_BYTES   (CACHE_WORD_BYTES)
    ) u_bank_cache_data_stream (
        .clk          (clk),
        .rst          (rst),
        .cpu_offset   (offset_in_block_w),
        .cpu_bank_id  (cache_bank_id_8),
        .cpu_wdata    (data_in),
        .cpu_we       (data_strm_cpu_req && !rw),
        .cpu_req      (data_strm_cpu_req),
        .cpu_rdata    (data_strm_cpu_rdata),
        .cpu_ready    (data_strm_cpu_ready),
        .hr_addr      (data_strm_hr_addr),
        .hr_burst_len (data_strm_hr_burst_len),
        .hr_wdata     (data_strm_hr_wdata),
        .hr_we        (data_strm_hr_we),
        .hr_req       (data_strm_hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done)
    );

    // CPU-side mux — pick the active cache's response. Both selectors
    // are REGISTERED (not the live bank_id_w[15] / attr_lookup_data[2])
    // for two reasons:
    //
    //   1. Pipeline correctness: cache cpu_rdata at cycle N+1 reflects
    //      cycle N's access; the routing selectors therefore need to
    //      be cycle N's values too. Using the live signals at N+1
    //      would mux the wrong cache's data.
    //
    //   2. Combinational-loop avoidance: SALLY's u_cpu has a
    //      combinational path from data_in (sally_mem_dout) through
    //      its instruction decode back to addr_out (sally_hwreg_addr).
    //      If cache_cpu_rdata depends on the LIVE bank_id_w[15] (which
    //      depends on the live address), the loop closes through the
    //      partition mux. Registering the selectors decouples it.
    //      (Same fix as M-cache-rework Step 3 commit 3519e68.)
    logic is_data_partition_q;
    logic is_streaming_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            is_data_partition_q <= 1'b0;
            is_streaming_q      <= 1'b0;
        end else begin
            is_data_partition_q <= is_data_partition;
            is_streaming_q      <= is_streaming;
        end
    end

    wire [7:0] cache_cpu_rdata =
        is_streaming_q ? (is_data_partition_q ? data_strm_cpu_rdata : code_strm_cpu_rdata)
                       : (is_data_partition_q ? data_part_cpu_rdata : code_part_cpu_rdata);

    wire       cache_cpu_ready = code_part_cpu_ready & data_part_cpu_ready
                               & code_strm_cpu_ready & data_strm_cpu_ready;

    // HR-side mux — only one cache is ever non-IDLE, so a 4-way
    // priority mux on hr_req picks the active one. hr_req is the OR
    // of the four (mutually-exclusive in practice). hr_burst_len /
    // hr_addr / hr_we / hr_wdata follow the same priority. The
    // priority mux is keyed on the registered hr_req of each cache,
    // so it's stable for the duration of the burst — bank_cache only
    // updates hr_addr/hr_we/hr_burst_len in the cycle hr_req=1, but
    // hr_wdata is updated each cycle of EVICT_STREAM. Since only one
    // cache's hr_req fires in a given window, the mux passes the
    // active cache's signals throughout the burst.
    assign hr_addr  = code_part_hr_req ? code_part_hr_addr
                    : data_part_hr_req ? data_part_hr_addr
                    : code_strm_hr_req ? code_strm_hr_addr
                                       : data_strm_hr_addr;
    assign hr_wdata = (code_part_hr_we | code_part_hr_req) ? code_part_hr_wdata
                    : (data_part_hr_we | data_part_hr_req) ? data_part_hr_wdata
                    : (code_strm_hr_we | code_strm_hr_req) ? code_strm_hr_wdata
                                                           : data_strm_hr_wdata;
    assign hr_we    = code_part_hr_req ? code_part_hr_we
                    : data_part_hr_req ? data_part_hr_we
                    : code_strm_hr_req ? code_strm_hr_we
                                       : data_strm_hr_we;
    assign hr_burst_len = code_part_hr_req ? {{(10-BURST_LEN_W){1'b0}}, code_part_hr_burst_len}
                        : data_part_hr_req ? {{(10-BURST_LEN_W){1'b0}}, data_part_hr_burst_len}
                        : code_strm_hr_req ? {{(10-BURST_LEN_W){1'b0}}, code_strm_hr_burst_len}
                                           : {{(10-BURST_LEN_W){1'b0}}, data_strm_hr_burst_len};
    assign hr_req   = code_part_hr_req | data_part_hr_req
                    | code_strm_hr_req | data_strm_hr_req;

    assign busy = !cache_cpu_ready;

    // ---- Read pipeline --------------------------------------------
    // Track which path served each access; the registered "was_*"
    // flops feed the data_out mux on the cycle after the access.
    logic [7:0] bram_dout_q;
    logic [7:0] hwreg_dout_q;
    logic       was_hwreg_q;
    logic       was_bank_q;
    logic       was_mpd_window_q;     // M-PBI step 2: was the prev addr in $D800-$DFFF
    logic       was_cart_external_q;  // M-PBI #2: prev addr was cart-window AND RD asserted

    // $D800-$DFFF window (OS-ROM hi region; PBI /MPD targets this range).
    wire is_mpd_window = (addr[15:11] == 5'b11011);

    // M-PBI #2: cart-slot read windows. RD4/RD5 active-low → asserted = 0.
    wire is_cart_s4_window = (addr[15:13] == 3'b100);  // $8000-$9FFF
    wire is_cart_s5_window = (addr[15:13] == 3'b101);  // $A000-$BFFF
    wire cart_external_read = rw                                // reads only
                            & ((is_cart_s4_window & ~bus_rd4_n_in)
                            |  (is_cart_s5_window & ~bus_rd5_n_in));

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bram_dout_q          <= 8'h00;
            hwreg_dout_q         <= 8'h00;
            was_hwreg_q          <= 1'b0;
            was_bank_q           <= 1'b0;
            was_mpd_window_q     <= 1'b0;
            was_cart_external_q  <= 1'b0;
        end else begin
            if (rdy) begin
                // BRAM path
                bram_dout_q          <= mem[addr];
                hwreg_dout_q         <= hwreg_dout;
                was_hwreg_q          <= is_hwreg_page;
                was_bank_q           <= is_in_window_w;
                was_mpd_window_q     <= is_mpd_window;
                was_cart_external_q  <= cart_external_read;
                // BRAM write — gated by rdy AND not-hwreg AND not-in-window.
                if (!rw && !is_hwreg_page && !is_in_window_w)
                    mem[addr] <= data_in;
            end
            // ROM-load write port — independent of CPU rdy. Always
            // committed when rom_we is high. antic_regs gates by
            // WRITE_LOCK upstream so we trust the strobe here.
            if (rom_we) mem[rom_addr] <= rom_data;
        end
    end

    // ---- Output mux ------------------------------------------------
    // M-PBI step 2/3 + #1 + #2: external-bus overrides for the read
    // path. Priorities, top to bottom:
    //   1. was_hwreg_q              -> hwreg_dout_q (internal regs)
    //   2. was_cart_external_q      -> bus_pbi_rdata (physical cart wins
    //                                  over HyperRAM-mirrored cart image)
    //   3. was_mpd_window_q & /MPD  -> bus_pbi_rdata (PBI replaces FP ROM)
    //   4. was_bank_q               -> cache_cpu_rdata (HR cart/130XE bank)
    //   5. default                  -> bram_dout_q
    // `bus_pbi_rdata` is the phi2-fall-captured external D[7:0] sample
    // (M-PBI #1), stable through phi2-low. /MPD is already 2-FF synced
    // upstream so consumed live.
    wire mpd_active = ~bus_mpd_n_in;
    assign data_out = was_hwreg_q                       ? hwreg_dout_q
                    : was_cart_external_q               ? bus_pbi_rdata
                    : (was_mpd_window_q & mpd_active)   ? bus_pbi_rdata
                    : was_bank_q                        ? cache_cpu_rdata
                                                        : bram_dout_q;

    // ---- Hardware-register write passthrough ----------------------
    assign hwreg_we   = !rw && is_hwreg_page;
    assign hwreg_din  = data_in;
    assign hwreg_addr = addr;

endmodule

`default_nettype wire
