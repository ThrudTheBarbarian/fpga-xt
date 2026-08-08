// plane_fetch.sv — per-plane DDR3 line fetch unit (video-arch phase 1b).
//
// docs/video/video-architecture.md section 4/11.  An AXI-read + ping-pong
// line-buffer per-plane source: it
// fetches one source ROW of a DDR3 surface into a line buffer, and serves the
// compositor a pixel read indexed by source COLUMN.  One instance per plane.
//
//   clk_sys: AXI4 read master (16-beat bursts, 8-byte beats = 2 RGBA px).
//            n_bursts = ceil(src_w/32); over-fetches up to 31 px (unused).
//            Row base = surface_base + fetch_row*stride_bytes.
//   clk_pix: line buffer read at rd_col -> rd_pixel (registered 1 clk).
//
// Pipeline: the row latched at line_start is fetched
// into the WRITE ping-pong half during that line; the READ half flips at the
// next line_start.  So drive `fetch_row` with the row that should DISPLAY on
// the NEXT line (the compositor's src_row_next).  `enable`=0 idles the AXI
// master (read returns stale/zero — the compositor gates via plane enable).
//
// CDC: line_start (clk_pix->clk_sys) via toggle + 2-FF + edge detect;
// fetch_row is stable between line_starts, carried by a 2-FF sync and sampled
// only after the synchronised line_start edge (stable-data + sync-flag).

`default_nettype none

module plane_fetch #(
    parameter int LB_WORDS = 1024     // 64-bit words per ping-pong half (2048 px)
) (
    // ---- AXI / fetch domain (clk_sys) ------------------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        enable,
    input  wire [31:0] surface_base,
    input  wire [15:0] stride_bytes,
    input  wire [11:0] src_w,         // source pixels per row

    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready,

    // ---- Raster domain (clk_pix) -----------------------------------------
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        line_start,
    input  wire        line_start_e,  // one cycle earlier (vbeam): flips the READ half
                                      // while still in blanking, so the first active
                                      // pixel's read (h_count==0) addresses the fresh
                                      // line — flipped at line_start_d1 the first two
                                      // reads hit the PREVIOUS line's half
    input  wire [11:0] fetch_row,     // source row to display NEXT line
    input  wire [11:0] rd_col,        // source column to read this pixel
    output wire [31:0] rd_pixel,      // RGBA8888, registered 1 clk after rd_col

    // ---- Diagnostics (clk_sys) -------------------------------------------
    output reg         read_abort,    // 1-cyc pulse when a line read times out
                                      // (AR not accepted / R stalled) and is
                                      // abandoned — the watchdog firing in
                                      // steady state means DDR-port contention.
    output reg         fetch_overrun  // 1-cyc pulse when a new line's fetch is
                                      // triggered while the previous one is still
                                      // in flight (fetch slower than a scanline)
                                      // — the other way a stale/adjacent row can
                                      // reach the display.
);

    // Read-burst sizing.  Reduced 16->8 beats as a silicon read-path
    // experiment: 16-beat PL->DDR reads never returned data on HW (the PS HP
    // read channel accepted the AR but never produced rvalid), while the
    // blitter's HP1 path was built at 8-beat reads.  All burst geometry below
    // derives from this so it stays correct if the value changes again.
    localparam int BEATS_PER_BURST = 8;
    localparam int BURST_BYTES     = BEATS_PER_BURST * 8;   // 8-byte (64-bit) beats
    localparam int BURST_PX        = BEATS_PER_BURST * 2;   // 2 RGBA px per beat

    // Pipelined read: keep up to MAX_OUTSTANDING AR requests in flight so DDR
    // read latency OVERLAPS instead of serialising.  The full-width desktop
    // plane is ~120 bursts/row; one-AR-at-a-time it couldn't finish a row within
    // a scanline under DDR contention -> the ping-pong served an unfinished half
    // -> tearing.  Reads use a single ARID, so responses return IN ORDER and R
    // beats land at a sequential wr_idx.
    localparam int MAX_OUTSTANDING = 4;          // ARs in flight once reads are alive
    typedef enum logic [1:0] { S_IDLE, S_FETCH, S_DRAIN } state_t;
    state_t      state;
    logic [6:0]  ar_idx;    // next burst to request (0..n_bursts)
    logic [6:0]  r_done;    // bursts fully received (rlast count)
    wire  [6:0]  outstanding = ar_idx - r_done;
    // CRITICAL: PL->DDR reads are DEAD for ~0.7 ms after reset (ARs accepted,
    // no rvalid).  Firing pipelined ARs into that window jams the HP read FIFO
    // with phantom reads that never complete and DEADLOCKS the interconnect
    // (hangs the A9 + kills video).  So cap to ONE outstanding until the first
    // rvalid proves reads work — gentle like the old serial fetch — THEN pipeline.
    logic        reads_alive;
    wire  [6:0]  max_out = reads_alive ? 7'(MAX_OUTSTANDING) : 7'd1;

    // ---- Line buffer (clk_sys write / clk_pix read) ----------------------
    (* ram_style = "block" *)
    logic [63:0] line_buf [0:2*LB_WORDS-1];

    // Double-buffered.  ping_pong_rd (clk_pix) flips at line_start; ping_pong_wr
    // is DERIVED from it via CDC (wr = ~sync(rd)) rather than flipped
    // independently in clk_sys.  Two independent flips in two close-but-unequal
    // clocks (148.4 vs 150 MHz) could slip into the SAME half for a line, serving
    // the read the half being written = an adjacent/wrong row (the intermittent
    // text offset, "3 ahead / 8 behind").  Deriving wr from rd makes them always
    // opposite by construction; rd is stable for a whole line, so the synced wr
    // is stable across the fetch.
    logic        ping_pong_rd;        // clk_pix (init 0)
    logic [1:0]  pp_rd_sync;          // ping_pong_rd synced into clk_sys (2-FF)
    wire         ping_pong_wr = ~pp_rd_sync[1];   // always the half rd is NOT on
    logic [10:0] wr_idx;
    // Combinational write strobe so each beat lands in its own slot on the
    // cycle it arrives (a registered wr_en would drop the first beat).
    wire         wr_en = (state == S_FETCH) && m_axi_rvalid;   // discard in S_DRAIN
    always_ff @(posedge clk_sys) begin
        if (wr_en) line_buf[{ping_pong_wr, wr_idx[9:0]}] <= m_axi_rdata;
    end

    // Read port (clk_pix): word at rd_col[10:1], half by rd_col[0] (1-cyc).
    logic [63:0] rd_word_q;
    logic        rd_lsb_q;
    always_ff @(posedge clk_pix) begin
        rd_word_q <= line_buf[{ping_pong_rd, rd_col[10:1]}];
        rd_lsb_q  <= rd_col[0];
    end
    assign rd_pixel = rd_lsb_q ? rd_word_q[63:32] : rd_word_q[31:0];

    // ---- line_start + fetch_row CDC (clk_pix -> clk_sys) -----------------
    // The compositor's src_row_next (driven onto fetch_row) is combinational
    // from the vertical accumulator, which UPDATES at line_start.  Sampling
    // fetch_row AT line_start captures the PRE-update value, which lags the
    // accumulator by a line: the image shifts down a row, the bottom row is
    // dropped, and at the window's top boundary (where the accumulator has just
    // reset) the stale previous-frame state predicts an out-of-range row -> a
    // garbage line.  Sample one cycle later, when src_row_next has settled to
    // the next scanline's true source row.  The read-half flip + fetch trigger
    // + row latch are delayed together so the ping-pong rd/wr phase stays
    // coherent; the 1-cycle slip is hidden by the horizontal blanking before
    // the active read.
    // SAME-ROW FETCHES ARE SKIPPED.  A scaled plane presents one source row
    // for `scale` consecutive scanlines (plane_compositor's src_row_next only
    // advances at vsub == scale-1), and refetching the identical row every
    // output line multiplied the plane's DDR read traffic by the scale factor
    // -- at XL fullscreen scale each of those redundant fetches raced the
    // ANTIC writeback on the shared HP2/HP3 DDRC port and lost often enough
    // to flood hdmi-mon with ovr(x) events.  So: trigger a fetch only when
    // the row CHANGES, and flip the read half only on the line that starts
    // displaying a row that was actually fetched.  A scale-1 plane changes
    // row every line, so its behaviour is exactly as before.
    // The row-change decision is PIPELINED: fetch_row is the compositor's
    // combinational src_row_next (a long carry chain), and comparing it in
    // the same cycle that samples it put the compare on clk_pix's critical
    // path (build 4 closed at +0.019 ns; build 5's seed went negative).  So
    // d1 does a plain capture -- the original timing shape -- and d2 runs
    // the register-to-register compare.  The toggle fires one clk_pix later
    // than before, which the clk_sys side never sees: fetch_row_pix is
    // stable for a whole line either way.
    logic       ls_toggle_pix;
    logic [11:0] fetch_row_pix;
    logic       line_start_d1, line_start_d2;
    logic [11:0] fetch_row_cap;      // d1's plain capture of fetch_row
    logic [11:0] prev_row_q;          // last row handed to the fetcher
    logic        flip_pend_q;         // a fetch ran last line: flip at next _e
    logic [1:0]  en_pix_sync;         // enable (quasi-static, clk_sys) -> pix
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            ls_toggle_pix <= 1'b0;
            fetch_row_pix <= 12'd0;
            ping_pong_rd  <= 1'b0;
            line_start_d1 <= 1'b0;
            line_start_d2 <= 1'b0;
            fetch_row_cap <= 12'd0;
            prev_row_q    <= 12'hFFF;
            flip_pend_q   <= 1'b0;
            en_pix_sync   <= 2'b00;
        end else begin
            en_pix_sync   <= {en_pix_sync[0], enable};
            line_start_d1 <= line_start;
            line_start_d2 <= line_start_d1;
            // While disabled the buffer holds stale content: forget the row so
            // the first line after re-enable always fetches fresh.
            if (!en_pix_sync[1]) prev_row_q <= 12'hFFF;
            if (line_start_e && flip_pend_q) begin
                ping_pong_rd <= ~ping_pong_rd;     // flip IN blanking: the
                flip_pend_q  <= 1'b0;              // h==0 read wants the new half
            end
            if (line_start_d1) fetch_row_cap <= fetch_row;
            if (line_start_d2 && (fetch_row_cap != prev_row_q)) begin
                ls_toggle_pix <= ~ls_toggle_pix;
                fetch_row_pix <= fetch_row_cap;
                prev_row_q    <= fetch_row_cap;
                flip_pend_q   <= 1'b1;
            end
        end
    end

    // CDC: only the 1-bit line_start TOGGLE is synchronised (2-FF + edge).  The
    // 12-bit fetch_row is NOT free-run through a 2-FF — that is a multi-bit CDC
    // violation: a clk_sys edge coincident with fetch_row_pix's transition
    // resolves each bit to old-or-new INDEPENDENTLY, capturing a garbage mixed
    // value.  Worst at the 127->128 (0x07F->0x080) transition where all 8 low
    // bits flip -> a wild row number -> plane_fetch reads a wrong DDR address ->
    // multi-coloured garbage that is NOT in the buffer, blinking at the
    // clk_pix/clk_sys phase-drift beat (the row-128 rainbow line; the READY
    // off-by-1/3 blends are the small-transition version of the same bug).
    // Correct stable-data+flag: fetch_row_pix is held stable from line_start_d1
    // until the next one, and line_start_sys fires ~2-3 clk_sys later, so
    // capturing fetch_row_pix DIRECTLY on line_start_sys samples a settled bus.
    // The clk_pix->clk_sys path is bounded by a set_max_delay -datapath_only
    // (constraints/cdc_fetch_row.xdc).
    logic [1:0] ls_sync;
    logic       ls_sync_prev;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            ls_sync      <= 2'b0;
            ls_sync_prev <= 1'b0;
            pp_rd_sync   <= 2'b00;        // rd init 0 -> wr = ~0 = 1 (opposite)
        end else begin
            ls_sync      <= {ls_sync[0], ls_toggle_pix};
            ls_sync_prev <= ls_sync[1];
            pp_rd_sync   <= {pp_rd_sync[0], ping_pong_rd};
        end
    end
    wire line_start_sys = ls_sync[1] ^ ls_sync_prev;

    // ---- Fetch bookkeeping (clk_sys) -------------------------------------
    // n_bursts = ceil(src_w / BURST_PX) (BURST_PX source px per burst).
    wire [6:0] n_bursts = 7'((src_w + 12'(BURST_PX-1)) >> $clog2(BURST_PX));
    logic [11:0] row_to_fetch;
    logic        line_pending;
    logic        fetch_done;     // 1-cycle pulse when a line's fetch completes

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            row_to_fetch  <= 12'd0;
            line_pending  <= 1'b0;
            fetch_overrun <= 1'b0;
        end else begin
            // Overrun: a new line started while the prior fetch was still pending.
            fetch_overrun <= line_start_sys && line_pending;
            if (line_start_sys) begin
                // Stable-data + synced-flag CDC: fetch_row_pix has been held
                // stable since line_start_d1 (~2-3 clk_sys before this flag),
                // so sampling it directly here is clean — no multi-bit 2-FF
                // bus sync that could capture a mid-transition garbage row.
                row_to_fetch <= fetch_row_pix;
                line_pending <= 1'b1;
                // ping_pong_wr is derived from pp_rd_sync (see its declaration) —
                // no independent flip here.
            end else if (fetch_done) begin
                line_pending <= 1'b0;
            end
        end
    end

    // Row byte base = surface_base + row*stride (one multiply per line).
    // REGISTERED so the DSP multiply keeps an output register: the raw
    // combinational product fed m_axi_araddr straight into the PS7 HP AR
    // port — the design's worst clk_sys setup path (2 logic levels, ~72%
    // logic delay, measured −17 ps).  row_to_fetch loads at line_start and
    // S_FETCH begins two cycles later, so the one-cycle latency is absorbed
    // before the first AR is offered.
    logic [31:0] row_base;
    always_ff @(posedge clk_sys)
        row_base <= surface_base + (32'(row_to_fetch) * 32'(stride_bytes));

    // ---- AXI read (clk_sys) ---------------------------------------------
    assign m_axi_arsize  = 3'b011;     // 8 bytes/beat
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_arlen   = 8'(BEATS_PER_BURST - 1);
    assign m_axi_rready  = 1'b1;

    // Issue ARs for bursts 0..n_bursts-1, up to MAX_OUTSTANDING in flight.
    // araddr/arvalid are combinational off ar_idx, which only advances on
    // arready — so the offered address is held stable until accepted (AXI-legal),
    // and outstanding can only fall (R completes) while we wait, never rising.
    assign m_axi_arvalid = (state == S_FETCH) && (ar_idx < n_bursts)
                                              && (outstanding < max_out);
    assign m_axi_araddr  = row_base + (32'(ar_idx) << $clog2(BURST_BYTES));

    // Read watchdog.  HW bring-up found that PL->DDR reads fail for a short
    // window right after reset (~0.7 ms) and then work — proven by the HP2
    // hp_read_probe, which only survives because it RETRIES.  Without a
    // watchdog, plane_fetch's first read (issued on scanline 0, inside that
    // dead window) gets no rvalid and wedges S_R forever (AR=1, R-beats=0 on
    // silicon).  So: if AR or R stalls for RD_TIMEOUT cycles, abort the line
    // and let the next line_start re-issue.  RD_TIMEOUT >> normal read latency
    // (~tens of cycles) but << one scanline, so it never fires in steady state
    // — only during the startup window, after which lines fill normally.
    localparam int RD_TIMEOUT = 2048;
    logic [12:0] rd_wd;

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            state       <= S_IDLE;
            ar_idx      <= 7'd0;
            r_done      <= 7'd0;
            wr_idx      <= 11'd0;
            fetch_done  <= 1'b0;
            read_abort  <= 1'b0;
            rd_wd       <= 13'd0;
            reads_alive <= 1'b0;
        end else begin
            fetch_done <= 1'b0;
            read_abort <= 1'b0;

            // R collection (responses in AR order, single ID): wr_en
            // (combinational) writes this beat; advance the slot + burst count.
            if (m_axi_rvalid) begin
                reads_alive <= 1'b1;          // first real read -> allow pipelining
                if (state == S_FETCH) wr_idx <= wr_idx + 11'd1;
                if (m_axi_rlast)      r_done <= r_done + 7'd1;
            end
            // AR accepted -> request the next burst.
            if (m_axi_arvalid && m_axi_arready) ar_idx <= ar_idx + 7'd1;
            // Watchdog: reset on any AR/R progress, else count toward abort.
            if ((m_axi_arvalid && m_axi_arready) || m_axi_rvalid) rd_wd <= 13'd0;
            else                                                  rd_wd <= rd_wd + 13'd1;

            unique case (state)
                S_IDLE: begin
                    if (line_pending && enable) begin
                        state  <= S_FETCH;
                        ar_idx <= 7'd0;
                        r_done <= 7'd0;
                        wr_idx <= 11'd0;
                        rd_wd  <= 13'd0;
                    end
                end
                S_FETCH: begin
                    // Done when the final burst's rlast arrives.
                    if (m_axi_rvalid && m_axi_rlast && (r_done == n_bursts - 7'd1)) begin
                        state      <= S_IDLE;
                        fetch_done <= 1'b1;
                    end else if (rd_wd >= RD_TIMEOUT[12:0]) begin
                        // Startup dead-window (PL->DDR reads fail ~0.7 ms after
                        // reset).  Abort; drain any in-flight responses first so a
                        // late beat can't corrupt the next line.
                        read_abort <= 1'b1;
                        if (outstanding != 7'd0) state <= S_DRAIN;
                        else begin state <= S_IDLE; fetch_done <= 1'b1; end
                    end
                end
                S_DRAIN: begin
                    // Swallow the aborted line's responses (wr_en is off here)
                    // until none remain — or give up if they never come.
                    if ((m_axi_rvalid && m_axi_rlast && outstanding == 7'd1)
                        || outstanding == 7'd0) begin
                        state <= S_IDLE; fetch_done <= 1'b1;
                    end else if (rd_wd >= RD_TIMEOUT[12:0]) begin
                        state <= S_IDLE; fetch_done <= 1'b1;   // dead window: drop them
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
