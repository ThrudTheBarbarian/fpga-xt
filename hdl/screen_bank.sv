// screen_bank.sv — dual CPU/ANTIC banked screen RAM (Atari page-flip).
//
// Two BRAM caches over one 8 KB aperture (the existing $4000-$5FFF screen RAM),
// backed by a DDR "stack" of 8 KB chunks (256 chunks = 2 MB):
//
//   CPU-BRAM  (read/write) — the aperture as the 6502 sees it.  A write to the
//             CPU-bank register ($D5C3) is a REQUEST: flush CPU-BRAM back to its
//             old DDR chunk (if dirty), load the new chunk into CPU-BRAM, then
//             raise `ready`.  The CPU polls `ready` ($D5C5.0) before touching
//             screen RAM again.
//   ANTIC-BRAM (read-only) — the chunk ANTIC fetches.  The ANTIC-bank register
//             ($D5C4) is latched at VBI (`vbi`); on a change the engine reloads
//             that chunk DDR -> ANTIC-BRAM (no writeback — read-only).
//
// Clock domains:
//   clk        — engine + AXI master (clk_sys).  Owns the BRAM B ports.
//   clk_cpu    — 6502 side (clk_sally): CPU byte access + bank-reg writes + ready.
//   clk_antic  — ANTIC side (clk_pix/clk_sys): read-only aperture fetch + vbi.
// Bank requests cross clk_cpu/clk_antic -> clk via toggle + edge-detect, with the
// bank VALUE held stable across the handshake (stable-data + synced-flag — NOT a
// free-running multi-bit sync).  `ready` crosses clk -> clk_cpu the same way.
//
// AXI: one AXI4 master, 16-beat (128 B) bursts so the AXI4->AXI3 HP path is happy;
// 8 KB = 64 bursts per chunk transfer.  Copy (CPU) and reload (ANTIC) are
// sequenced by one FSM (neither is latency-critical; a flip never has to finish
// "now" — the RGBA triple buffer guarantees tear-free scan-out regardless).

`default_nettype none

module screen_bank #(
    parameter int unsigned AXI_ADDR_W   = 32,
    parameter logic [31:0]  STACK_BASE   = 32'h3400_0000, // DDR chunk-stack base
    parameter int unsigned APERTURE_LOG2 = 13             // 8 KB aperture
) (
    input  wire                   clk,        // engine / AXI (clk_sys)
    input  wire                   rst,        // active-high, sync to clk

    // ---- CPU side (clk_cpu = clk_sally) -----------------------------------
    input  wire                   clk_cpu,
    input  wire [APERTURE_LOG2-1:0] cpu_addr, // byte address within the aperture
    input  wire                   cpu_we,
    input  wire [7:0]             cpu_wdata,
    input  wire                   cpu_rden,    // read-strobe (= sally_rdy): freeze the read reg
                                               // during CPU stalls so it can't chase the advanced
                                               // address bus (else a stalled banked-page read returns
                                               // a neighbour word — mirror of the math_cop fix)
    output wire [7:0]             cpu_rdata,   // 1-cycle BRAM read (registered word + byte mux)
    input  wire [7:0]             cpu_bank_wval,  // $D5C3 write value
    input  wire                   cpu_bank_we,    // $D5C3 write strobe (clk_cpu)
    output wire                   ready,          // $D5C5.0 (1 = CPU-BRAM holds the requested bank)

    // ---- ANTIC side (clk_antic = clk_pix) ---------------------------------
    input  wire                   clk_antic,
    input  wire [APERTURE_LOG2-1:0] antic_addr,
    output reg  [7:0]             antic_rdata,    // registered
    input  wire [7:0]             antic_bank_wval, // $D5C4 write value (clk_cpu-written, sampled at vbi)
    input  wire                   antic_bank_we,   // $D5C4 write strobe (clk_cpu)
    input  wire                   vbi,             // 1-cycle VBI pulse (clk_antic) — latches antic bank
    output wire                   antic_banked,    // 1 = ANTIC effective bank != 0 (use ANTIC-BRAM)

    // ---- AXI3 master, 32-bit (clk) -> S_AXI_GP0.  The FSM below drives an
    // internal 64-bit AXI (m_axi_*); a serialiser maps it to this 32-bit port. --
    output wire [AXI_ADDR_W-1:0]  e_axi_araddr,
    output wire [3:0]             e_axi_arlen,    // AXI3: 4-bit len
    output wire [2:0]             e_axi_arsize,
    output wire [1:0]             e_axi_arburst,
    output wire                   e_axi_arvalid,
    input  wire                   e_axi_arready,
    input  wire [31:0]            e_axi_rdata,
    input  wire                   e_axi_rvalid,
    input  wire                   e_axi_rlast,
    output wire                   e_axi_rready,

    output wire [AXI_ADDR_W-1:0]  e_axi_awaddr,
    output wire [3:0]             e_axi_awlen,
    output wire [2:0]             e_axi_awsize,
    output wire [1:0]             e_axi_awburst,
    output wire                   e_axi_awvalid,
    input  wire                   e_axi_awready,
    output wire [31:0]            e_axi_wdata,
    output wire [3:0]             e_axi_wstrb,
    output wire                   e_axi_wlast,
    output wire                   e_axi_wvalid,
    input  wire                   e_axi_wready,
    input  wire                   e_axi_bvalid,
    output wire                   e_axi_bready
);
    // ---- geometry ----------------------------------------------------------
    localparam int WORDS      = (1 << APERTURE_LOG2) / 8;   // 1024 64-bit words
    localparam int WORD_AW    = APERTURE_LOG2 - 3;          // 10
    localparam int BURST      = 8;        // 64-bit words per burst (-> 16 AXI3 32-bit beats, 64 B)
    localparam int NBURST     = WORDS / BURST;               // 128 bursts per chunk
    localparam int BURST_AW   = $clog2(NBURST);             // 7

    // Internal 64-bit AXI driven by the FSM (a serialiser below maps it to the
    // 32-bit e_axi_* port).  Same names/semantics as the original 64-bit master,
    // so the FSM is unchanged.
    logic [AXI_ADDR_W-1:0] m_axi_araddr;  logic [7:0] m_axi_arlen;
    logic                  m_axi_arvalid; logic m_axi_arready;
    logic [63:0]           m_axi_rdata;   logic m_axi_rvalid, m_axi_rlast;  wire m_axi_rready;
    logic [AXI_ADDR_W-1:0] m_axi_awaddr;  logic [7:0] m_axi_awlen;
    logic                  m_axi_awvalid; logic m_axi_awready;
    logic [63:0]           m_axi_wdata;   logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic                  m_axi_bvalid;  wire  m_axi_bready;
    assign m_axi_rready = 1'b1;
    assign m_axi_bready = 1'b1;

    // ---- 64<->32 serialiser (internal 64-bit AXI  <->  e_axi_* 32-bit AXI3) --
    // AR/AW: same addr; double the beat count (each 64-bit word = 2 x 32-bit).
    assign e_axi_araddr  = m_axi_araddr;
    assign e_axi_arlen   = (({4'd0, m_axi_arlen} + 4'd1) << 1) - 4'd1;  // 8 words ->16 beats: 15
    assign e_axi_arsize  = 3'b010;   // 4 bytes/beat
    assign e_axi_arburst = 2'b01;
    assign e_axi_arvalid = m_axi_arvalid;
    assign m_axi_arready = e_axi_arready;
    assign e_axi_awaddr  = m_axi_awaddr;
    assign e_axi_awlen   = (({4'd0, m_axi_awlen} + 4'd1) << 1) - 4'd1;
    assign e_axi_awsize  = 3'b010;
    assign e_axi_awburst = 2'b01;
    assign e_axi_awvalid = m_axi_awvalid;
    assign m_axi_awready = e_axi_awready;
    assign e_axi_bready  = m_axi_bready;
    assign m_axi_bvalid  = e_axi_bvalid;

    // Read deserialise: collect 2 x 32-bit -> 1 x 64-bit, pulse m_axi_rvalid.
    logic        rdes_phase = 1'b0;
    logic [31:0] rdes_lo;
    assign e_axi_rready = 1'b1;
    always_ff @(posedge clk) begin
        if (rst) begin rdes_phase <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0; end
        else begin
            m_axi_rvalid <= 1'b0;
            if (e_axi_rvalid) begin
                if (!rdes_phase) begin rdes_lo <= e_axi_rdata; rdes_phase <= 1'b1; end
                else begin
                    m_axi_rdata  <= {e_axi_rdata, rdes_lo};
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= e_axi_rlast;
                    rdes_phase   <= 1'b0;
                end
            end
        end
    end

    // Write serialise: emit each 64-bit m_axi_wdata as lo then hi 32-bit beats.
    logic wser_phase = 1'b0;
    assign e_axi_wdata  = wser_phase ? m_axi_wdata[63:32] : m_axi_wdata[31:0];
    assign e_axi_wstrb  = 4'hF;
    assign e_axi_wvalid = m_axi_wvalid;
    assign e_axi_wlast  = m_axi_wlast & wser_phase;       // external last = hi beat of last word
    assign m_axi_wready = e_axi_wready & wser_phase;      // FSM advances after the hi beat
    always_ff @(posedge clk) begin
        if (rst) wser_phase <= 1'b0;
        else if (e_axi_wvalid & e_axi_wready) wser_phase <= ~wser_phase;
    end

    // ====================================================================
    // BRAMs — true dual port.  Port A = CPU/ANTIC side, Port B = engine.
    // 64-bit words, byte-write-enable on the CPU port.
    // ====================================================================
    (* ram_style = "block" *) logic [63:0] cpu_bram   [0:WORDS-1];
    (* ram_style = "block" *) logic [63:0] antic_bram [0:WORDS-1];

    // ---- CPU port A (clk_cpu): byte write-enable + full-word read ----
    // Per-lane write with a CONSTANT index (loop) so Vivado infers a true
    // byte-write-enable BRAM (a variable [boff*8+:8] write is an unsupported
    // RAM template).  Read the whole word + register boff; mux the byte after.
    wire [WORD_AW-1:0] cpu_word = cpu_addr[APERTURE_LOG2-1:3];
    wire [2:0]         cpu_boff = cpu_addr[2:0];
    wire [63:0]        cpu_wdata64 = {8{cpu_wdata}};               // broadcast to all lanes
    wire [7:0]         cpu_be = cpu_we ? (8'd1 << cpu_boff) : 8'd0; // one-hot byte enable
    logic [63:0]       cpu_rd_word_q;
    logic [2:0]        cpu_boff_q;
    always_ff @(posedge clk_cpu) begin
        for (int bb = 0; bb < 8; bb = bb + 1)
            if (cpu_be[bb]) cpu_bram[cpu_word][bb*8 +: 8] <= cpu_wdata64[bb*8 +: 8];
        if (cpu_rden) begin                    // freeze during stalls (aligned with was_scrn_q)
            cpu_rd_word_q <= cpu_bram[cpu_word];
            cpu_boff_q    <= cpu_boff;
        end
    end
    assign cpu_rdata = cpu_rd_word_q[cpu_boff_q*8 +: 8];

    // ---- ANTIC port A (clk_antic): read only ----
    wire [WORD_AW-1:0] an_word = antic_addr[APERTURE_LOG2-1:3];
    wire [2:0]         an_boff = antic_addr[2:0];
    always_ff @(posedge clk_antic)
        antic_rdata <= antic_bram[an_word][an_boff*8 +: 8];

    // ---- engine port B (clk): full 64-bit r/w ----
    logic [WORD_AW-1:0] cpu_b_addr;
    logic [63:0]        cpu_b_wdata, cpu_b_rdata;
    logic               cpu_b_we;
    logic [WORD_AW-1:0] an_b_addr;
    logic [63:0]        an_b_wdata;
    logic               an_b_we;
    always_ff @(posedge clk) begin
        if (cpu_b_we) cpu_bram[cpu_b_addr] <= cpu_b_wdata;
        cpu_b_rdata <= cpu_bram[cpu_b_addr];
        if (an_b_we)  antic_bram[an_b_addr] <= an_b_wdata;
    end

    // ====================================================================
    // Dirty flag — set on any CPU write (clk_cpu), sampled+cleared by the
    // engine at copy start.  Safe without a fancy CDC: the CPU polls `ready`
    // before drawing, so no CPU write overlaps a copy.  Toggle-style so the
    // engine sees a clean level.
    // ====================================================================
    logic cpu_dirty_set_tgl = 1'b0;   // clk_cpu: toggles on each write
    always_ff @(posedge clk_cpu)
        if (cpu_we) cpu_dirty_set_tgl <= ~cpu_dirty_set_tgl;

    // ---- CPU-bank request: toggle + held value (clk_cpu -> clk) ----
    logic [7:0] cpu_bank_q   = 8'd0;
    logic       cpu_req_tgl  = 1'b0;
    always_ff @(posedge clk_cpu)
        if (cpu_bank_we) begin cpu_bank_q <= cpu_bank_wval; cpu_req_tgl <= ~cpu_req_tgl; end

    // ---- ANTIC-bank: written any time (clk_cpu), latched to effective at VBI ----
    logic [7:0] antic_bank_shadow = 8'd0;  // last $D5C4 write
    always_ff @(posedge clk_cpu)
        if (antic_bank_we) antic_bank_shadow <= antic_bank_wval;
    logic [7:0] antic_bank_eff = 8'd0;     // latched at VBI (clk_antic)
    assign antic_banked = (antic_bank_eff != 8'd0);
    logic       antic_req_tgl  = 1'b0;
    always_ff @(posedge clk_antic)
        if (vbi && (antic_bank_eff != antic_bank_shadow)) begin
            antic_bank_eff <= antic_bank_shadow;
            antic_req_tgl  <= ~antic_req_tgl;
        end

    // ---- synchronise the request toggles + dirty into clk ----
    wire cpu_req_s, antic_req_s, dirty_s;
    wire [7:0] cpu_bank_s, antic_bank_s;   // stable buses (held since the toggle)
    cdc_sync_bit u_s_cpu  (.dst_clk(clk), .src_sig(cpu_req_tgl),      .dst_sig(cpu_req_s));
    cdc_sync_bit u_s_ant  (.dst_clk(clk), .src_sig(antic_req_tgl),    .dst_sig(antic_req_s));
    cdc_sync_bit u_s_drt  (.dst_clk(clk), .src_sig(cpu_dirty_set_tgl),.dst_sig(dirty_s));
    // the bank values are stable by the time the synced toggle edge arrives
    assign cpu_bank_s   = cpu_bank_q;
    assign antic_bank_s = antic_bank_eff;

    logic cpu_req_s_d, antic_req_s_d, dirty_s_d;
    logic cpu_pending, antic_pending;     // latched requests awaiting service
    logic engine_dirty;                   // CPU-BRAM dirty since last flush

    // ====================================================================
    // Engine FSM (clk)
    // ====================================================================
    typedef enum logic [3:0] {
        IDLE,
        WB_AR, WB_PRE, WB_W, WB_B,        // CPU flush: CPU-BRAM -> DDR[old]
        FILL_AR, FILL_R,                  // CPU fill : DDR[new] -> CPU-BRAM
        REL_AR, REL_R,                    // ANTIC reload: DDR[bank] -> ANTIC-BRAM
        DONE_CPU
    } state_t;
    state_t st;

    logic [7:0]          cur_old, cur_new, cur_antic;  // chunk indices in flight
    logic [BURST_AW-1:0] burst_q;        // 0..NBURST-1
    logic [4:0]          beat_q;         // 0..BURST (one extra for pre-read latency)
    logic [63:0]         wbuf [0:BURST-1]; // flush pre-read buffer

    function automatic [AXI_ADDR_W-1:0] chunk_addr(input [7:0] bank, input [BURST_AW-1:0] b);
        chunk_addr = STACK_BASE
                   + (bank << APERTURE_LOG2)
                   + (b << ($clog2(BURST) + 3));   // burst * 128
    endfunction

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            st <= IDLE;
            m_axi_arvalid <= 0; m_axi_awvalid <= 0; m_axi_wvalid <= 0; m_axi_wlast <= 0;
            cpu_b_we <= 0; an_b_we <= 0;
            cpu_req_s_d <= 0; antic_req_s_d <= 0; dirty_s_d <= 0;
            cpu_pending <= 0; antic_pending <= 0; engine_dirty <= 0;
            burst_q <= 0; beat_q <= 0;
        end else begin
            cpu_b_we <= 0; an_b_we <= 0;

            // edge-detect the synced request toggles -> latch a pending job
            cpu_req_s_d   <= cpu_req_s;
            antic_req_s_d <= antic_req_s;
            dirty_s_d     <= dirty_s;
            if (cpu_req_s   ^ cpu_req_s_d)   cpu_pending   <= 1;
            if (antic_req_s ^ antic_req_s_d) antic_pending <= 1;
            if (dirty_s     ^ dirty_s_d)     engine_dirty  <= 1;   // CPU dirtied the BRAM

            case (st)
            // ---------------------------------------------------------------
            IDLE: begin
                if (cpu_pending) begin
                    cpu_pending <= 0;
                    cur_new <= cpu_bank_s;
                    burst_q <= 0; beat_q <= 0;
                    if (engine_dirty) st <= WB_AR; else st <= FILL_AR;
                end else if (antic_pending) begin
                    antic_pending <= 0;
                    cur_antic <= antic_bank_s;
                    burst_q <= 0; beat_q <= 0;
                    st <= REL_AR;
                end
            end

            // ---- CPU flush: read CPU-BRAM burst into wbuf, AXI-write ------
            WB_AR: begin
                m_axi_awaddr  <= chunk_addr(cur_old, burst_q);
                m_axi_awlen   <= BURST - 1;
                m_axi_awvalid <= 1;
                cpu_b_addr <= burst_q * BURST;          // beat-0 read in flight
                beat_q <= 0;
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 0;
                    cpu_b_addr <= burst_q * BURST + 1;  // overrides: prefetch beat 1
                    st <= WB_PRE;
                end
            end
            WB_PRE: begin
                // capture word[base+beat_q] (its read was launched 1 cycle ago),
                // and keep the read address one beat ahead (BRAM 1-cycle latency).
                wbuf[beat_q] <= cpu_b_rdata;
                cpu_b_addr   <= burst_q * BURST + beat_q + 2;
                if (beat_q == BURST - 1) begin
                    beat_q       <= 0;
                    m_axi_wvalid <= 1;
                    m_axi_wdata  <= wbuf[0];      // wbuf[0] captured BURST cycles ago
                    m_axi_wlast  <= (BURST == 1);
                    st <= WB_W;
                end else begin
                    beat_q <= beat_q + 1;
                end
            end
            WB_W: begin
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast) begin
                        m_axi_wvalid <= 0; m_axi_wlast <= 0;
                        st <= WB_B;
                    end else begin
                        beat_q <= beat_q + 1;
                        m_axi_wdata <= wbuf[beat_q + 1];
                        m_axi_wlast <= (beat_q + 1 == BURST - 1);
                    end
                end
            end
            WB_B: if (m_axi_bvalid) begin
                if (burst_q == NBURST - 1) begin
                    burst_q <= 0; beat_q <= 0; engine_dirty <= 0;
                    st <= FILL_AR;
                end else begin
                    burst_q <= burst_q + 1;
                    st <= WB_AR;
                end
            end

            // ---- CPU fill: AXI-read DDR[new] -> CPU-BRAM -----------------
            FILL_AR: begin
                m_axi_araddr  <= chunk_addr(cur_new, burst_q);
                m_axi_arlen   <= BURST - 1;
                m_axi_arvalid <= 1;
                beat_q <= 0;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 0;
                    st <= FILL_R;
                end
            end
            FILL_R: if (m_axi_rvalid) begin
                cpu_b_addr  <= burst_q * BURST + beat_q;
                cpu_b_wdata <= m_axi_rdata;
                cpu_b_we    <= 1;
                beat_q <= beat_q + 1;
                if (m_axi_rlast) begin
                    if (burst_q == NBURST - 1) st <= DONE_CPU;
                    else begin burst_q <= burst_q + 1; st <= FILL_AR; end
                end
            end
            DONE_CPU: begin
                cur_old <= cur_new;    // resident CPU chunk
                st <= IDLE;
            end

            // ---- ANTIC reload: AXI-read DDR[antic] -> ANTIC-BRAM --------
            REL_AR: begin
                m_axi_araddr  <= chunk_addr(cur_antic, burst_q);
                m_axi_arlen   <= BURST - 1;
                m_axi_arvalid <= 1;
                beat_q <= 0;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 0;
                    st <= REL_R;
                end
            end
            REL_R: if (m_axi_rvalid) begin
                an_b_addr  <= burst_q * BURST + beat_q;
                an_b_wdata <= m_axi_rdata;
                an_b_we    <= 1;
                beat_q <= beat_q + 1;
                if (m_axi_rlast) begin
                    if (burst_q == NBURST - 1) st <= IDLE;
                    else begin burst_q <= burst_q + 1; st <= REL_AR; end
                end
            end
            default: st <= IDLE;
            endcase
        end
    end

    // ---- ready: low from a CPU request until the copy finishes ----------
    // Track in clk, export to clk_cpu via a synced level.
    logic ready_clk;
    always_ff @(posedge clk) begin
        if (rst) ready_clk <= 1'b1;
        else if (cpu_pending || st == WB_AR || st == WB_PRE || st == WB_W ||
                 st == WB_B || st == FILL_AR || st == FILL_R) ready_clk <= 1'b0;
        else if (st == DONE_CPU) ready_clk <= 1'b1;
    end
    cdc_sync_bit u_s_rdy (.dst_clk(clk_cpu), .src_sig(ready_clk), .dst_sig(ready));

endmodule

`default_nettype wire
