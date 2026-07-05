// math_cop.sv — math-coprocessor mailbox page (A9-offloaded FPU/integer unit).
//
// A resident 8 KB BRAM ("math page") that sally_mem overlays onto the CPU's
// $4000-$5FFF aperture when $D5C6.0 (MAP) is set — mapping is a register flip,
// never a DDR copy, so entering/leaving the page costs nothing in the hot loop.
// The page's contents (operand slots + op program, laid out by software) are
// exchanged with a per-task 8 KB DDR chunk in the screen_bank chunk stack:
//
//   $D5C7 write (EXEC)  — doorbell: flush the page's DIRTY 64 B lines to the
//         backing chunk, then push the chunk index into the event FIFO (level
//         IRQ to the A9).  The A9 reads the chunk from DDR, does the math,
//         writes results + status back into the chunk, then writes MATH_DONE.
//   MATH_DONE (GP0)     — if that chunk is still resident, reload the result
//         span (first line, line count) DDR -> BRAM and raise $D5C7.0 (done).
//         A non-resident chunk is ignored: the task was context-switched away,
//         its results are already in its chunk in DDR, and the OS delivers the
//         completion; the next $D5C8 switch back fills them into the page.
//   $D5C8 write (CHUNK) — retarget the page to another task's chunk: spill
//         dirty lines to the old chunk, fill all of the new one.  This is the
//         context-switch path (tens of µs) — never the per-call path.
//
// Protocol: after EXEC the CPU must not touch the page until $D5C7.0 (done) —
// the page IS the in-flight mailbox.  That quiescence is also what makes the
// dirty-bitmap CDC below safe.
//
// Clock domains (same shape as screen_bank):
//   clk     — engine + AXI master (clk_sys) + the GP0-side ports (xt_gp0_regs
//             is also clk_sys, so evt/done/stat are same-domain wires).
//   clk_cpu — 6502 side (clk_sally): byte access, EXEC/CHUNK strobes, status.
// Requests cross clk_cpu -> clk as toggle + edge-detect with the value held
// stable across the handshake; status levels cross back through cdc_sync_bit.
// The 128-bit dirty bitmap lives in clk_cpu and is sampled in clk only after
// a synced request edge — by protocol the CPU is quiescent then, so the bits
// are stable data under a synced flag (NOT a free-running multi-bit sync).
//
// AXI: one 32-bit AXI3 master (e_axi_*), muxed with screen_bank's onto
// S_AXI_GP0 by gp0_axi_mux.  Each 64 B line = one 8x64-bit burst = 16 beats.

`default_nettype none

module math_cop #(
    parameter int unsigned AXI_ADDR_W   = 32,
    parameter logic [31:0] STACK_BASE   = 32'h2080_0000, // DDR chunk-stack base
    parameter int unsigned APERTURE_LOG2 = 13            // 8 KB page
) (
    input  wire                   clk,        // engine / AXI / GP0 side (clk_sys)
    input  wire                   rst,        // active-high, sync to clk

    // ---- CPU side (clk_cpu = clk_sally) -----------------------------------
    input  wire                   clk_cpu,
    input  wire [APERTURE_LOG2-1:0] cpu_addr, // byte address within the page
    input  wire                   cpu_we,
    input  wire [7:0]             cpu_wdata,
    output wire [7:0]             cpu_rdata,  // 1-cycle BRAM read (registered word + byte mux)
    input  wire                   exec_we,    // $D5C7 write strobe (doorbell)
    input  wire [7:0]             chunk_wval, // $D5C8 write value
    input  wire                   chunk_we,   // $D5C8 write strobe
    output wire                   math_done,  // $D5C7.0 — results reloaded, page readable
    output wire                   math_busy,  // $D5C7.1 — engine flushing/filling
    output wire                   chunk_ready,// $D5C7.2 — page holds the requested chunk

    // ---- A9 side (clk — wired to xt_gp0_regs, same domain) -----------------
    output wire [8:0]             evt_data,   // {valid, chunk} — event FIFO head
    input  wire                   evt_pop,    // consume one event (MATH_EVT read)
    output wire                   evt_irq,    // level: FIFO non-empty -> IRQ_F2P[1]
    input  wire [23:0]            done_word,  // {count[7:0], first[7:0], chunk[7:0]}
    input  wire                   done_we,    // MATH_DONE write strobe
    output wire [31:0]            stat_word,  // MATH_STAT readback

    // ---- AXI3 master, 32-bit (clk) -> gp0_axi_mux -> S_AXI_GP0 -------------
    output wire [AXI_ADDR_W-1:0]  e_axi_araddr,
    output wire [3:0]             e_axi_arlen,
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
    localparam int WORDS    = (1 << APERTURE_LOG2) / 8;  // 1024 64-bit words
    localparam int WORD_AW  = APERTURE_LOG2 - 3;         // 10
    localparam int BURST    = 8;                         // 64-bit words per line/burst
    localparam int NLINE    = WORDS / BURST;             // 128 lines of 64 B
    localparam int LINE_AW  = $clog2(NLINE);             // 7
    localparam logic [8:0] FILL_ALL = 9'(NLINE);         // whole-page fill count

    // Internal 64-bit AXI driven by the FSM; serialised to the 32-bit e_axi_*
    // port below (identical scheme to screen_bank).
    logic [AXI_ADDR_W-1:0] m_axi_araddr;  logic [7:0] m_axi_arlen;
    logic                  m_axi_arvalid; logic m_axi_arready;
    logic [63:0]           m_axi_rdata;   logic m_axi_rvalid, m_axi_rlast;  wire m_axi_rready;
    logic [AXI_ADDR_W-1:0] m_axi_awaddr;  logic [7:0] m_axi_awlen;
    logic                  m_axi_awvalid; logic m_axi_awready;
    logic [63:0]           m_axi_wdata;   logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic                  m_axi_bvalid;  wire  m_axi_bready;
    assign m_axi_rready = 1'b1;
    assign m_axi_bready = 1'b1;

    // ---- 64<->32 serialiser -------------------------------------------------
    assign e_axi_araddr  = m_axi_araddr;
    assign e_axi_arlen   = (({4'd0, m_axi_arlen} + 4'd1) << 1) - 4'd1;
    assign e_axi_arsize  = 3'b010;
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

    logic wser_phase = 1'b0;
    assign e_axi_wdata  = wser_phase ? m_axi_wdata[63:32] : m_axi_wdata[31:0];
    assign e_axi_wstrb  = 4'hF;
    assign e_axi_wvalid = m_axi_wvalid;
    assign e_axi_wlast  = m_axi_wlast & wser_phase;
    assign m_axi_wready = e_axi_wready & wser_phase;
    always_ff @(posedge clk) begin
        if (rst) wser_phase <= 1'b0;
        else if (e_axi_wvalid & e_axi_wready) wser_phase <= ~wser_phase;
    end

    // ====================================================================
    // Math-page BRAM — true dual port. Port A = CPU (clk_cpu, byte), port B =
    // engine (clk, 64-bit).  Same byte-enable inference shape as screen_bank.
    // ====================================================================
    (* ram_style = "block" *) logic [63:0] page_bram [0:WORDS-1];

    wire [WORD_AW-1:0] cpu_word = cpu_addr[APERTURE_LOG2-1:3];
    wire [2:0]         cpu_boff = cpu_addr[2:0];
    wire [63:0]        cpu_wdata64 = {8{cpu_wdata}};
    wire [7:0]         cpu_be = cpu_we ? (8'd1 << cpu_boff) : 8'd0;
    logic [63:0]       cpu_rd_word_q;
    logic [2:0]        cpu_boff_q;
    always_ff @(posedge clk_cpu) begin
        for (int bb = 0; bb < 8; bb = bb + 1)
            if (cpu_be[bb]) page_bram[cpu_word][bb*8 +: 8] <= cpu_wdata64[bb*8 +: 8];
        cpu_rd_word_q <= page_bram[cpu_word];
        cpu_boff_q    <= cpu_boff;
    end
    assign cpu_rdata = cpu_rd_word_q[cpu_boff_q*8 +: 8];

    logic [WORD_AW-1:0] eng_addr;
    logic [63:0]        eng_wdata, eng_rdata;
    logic               eng_we;
    always_ff @(posedge clk) begin
        if (eng_we) page_bram[eng_addr] <= eng_wdata;
        eng_rdata <= page_bram[eng_addr];
    end

    // ====================================================================
    // Dirty-line bitmap (clk_cpu).  One bit per 64 B line, set on any CPU
    // write.  Cleared by the engine via a clear-toggle after it has sampled
    // the map (set wins over a same-cycle clear).  Stable when the engine
    // samples it: EXEC/CHUNK mean the CPU has stopped writing (protocol).
    // ====================================================================
    logic [NLINE-1:0] dirty = '0;
    wire  [LINE_AW-1:0] cpu_line = cpu_addr[APERTURE_LOG2-1:6];

    logic dirty_clr_s_d = 1'b0;
    wire  dirty_clr_s;
    always_ff @(posedge clk_cpu) begin
        dirty_clr_s_d <= dirty_clr_s;
        if (dirty_clr_s ^ dirty_clr_s_d) dirty <= '0;
        if (cpu_we) dirty[cpu_line] <= 1'b1;   // set wins over clear
    end

    // ---- CPU requests: toggle + held value (clk_cpu -> clk) ----
    logic       exec_tgl  = 1'b0;
    logic [7:0] chunk_q   = 8'd0;
    logic       chunk_tgl = 1'b0;
    always_ff @(posedge clk_cpu) begin
        if (exec_we)  exec_tgl <= ~exec_tgl;
        if (chunk_we) begin chunk_q <= chunk_wval; chunk_tgl <= ~chunk_tgl; end
    end

    wire exec_s, chunk_s;
    cdc_sync_bit u_s_exec  (.dst_clk(clk), .src_sig(exec_tgl),  .dst_sig(exec_s));
    cdc_sync_bit u_s_chunk (.dst_clk(clk), .src_sig(chunk_tgl), .dst_sig(chunk_s));

    // clear-toggle back into clk_cpu
    logic dirty_clr_tgl;
    cdc_sync_bit u_s_dclr (.dst_clk(clk_cpu), .src_sig(dirty_clr_tgl), .dst_sig(dirty_clr_s));

    // ====================================================================
    // Event FIFO (clk) — doorbell chunk indices awaiting A9 service.
    // Depth 16; an overflowing push is dropped and latched sticky in stat.
    // ====================================================================
    localparam int EVT_D = 16;
    logic [7:0]  evt_mem [0:EVT_D-1];
    logic [3:0]  evt_rd, evt_wr;
    logic [4:0]  evt_cnt;
    logic        evt_ovfl;
    wire         evt_empty = (evt_cnt == 0);
    wire         evt_full  = (evt_cnt == EVT_D);
    logic        evt_push;
    logic [7:0]  evt_push_val;

    always_ff @(posedge clk) begin
        if (rst) begin
            evt_rd <= '0; evt_wr <= '0; evt_cnt <= '0; evt_ovfl <= 1'b0;
        end else begin
            unique case ({evt_push && !evt_full, evt_pop && !evt_empty})
                2'b10: begin evt_mem[evt_wr] <= evt_push_val; evt_wr <= evt_wr + 1; evt_cnt <= evt_cnt + 1; end
                2'b01: begin evt_rd <= evt_rd + 1; evt_cnt <= evt_cnt - 1; end
                2'b11: begin evt_mem[evt_wr] <= evt_push_val; evt_wr <= evt_wr + 1; evt_rd <= evt_rd + 1; end
                default: ;
            endcase
            if (evt_push && evt_full) evt_ovfl <= 1'b1;
        end
    end
    assign evt_data = {~evt_empty, evt_empty ? 8'd0 : evt_mem[evt_rd]};
    assign evt_irq  = ~evt_empty;

    // ====================================================================
    // Engine FSM (clk)
    // ====================================================================
    typedef enum logic [3:0] {
        IDLE,
        SAMPLE,                        // capture dirty map, pulse the clear-toggle
        FL_SCAN,                       // find next dirty line (or finish flush)
        FL_AR, FL_PRE, FL_W, FL_B,     // flush one line: BRAM -> DDR[res_chunk/old]
        FL_END,                        // flush finished -> mode epilogue
        FI_AR, FI_R,                   // fill lines: DDR -> BRAM
        FI_END
    } state_t;
    state_t st;

    typedef enum logic [1:0] { M_EXEC, M_CHUNK, M_DONE } mode_t;
    mode_t mode;

    logic             exec_s_d, chunk_s_d;
    logic             exec_pend, chunk_pend, done_pend;
    logic [7:0]       done_chunk_q, done_first_q;
    logic [8:0]       done_cnt_q;          // 0..128 lines (span reload)
    logic             exec_nochunk;        // sticky diag: EXEC with no chunk resident

    logic [NLINE-1:0] flush_map;           // engine copy of the dirty map
    logic [7:0]       res_chunk;           // chunk resident in (or being loaded into) the page
    logic [7:0]       old_chunk;           // spill target during a CHUNK switch
    logic [LINE_AW-1:0] line_q;            // current line index
    logic [8:0]       fill_left;           // lines remaining in a fill
    logic [4:0]       beat_q;
    logic [63:0]      wbuf [0:BURST-1];

    logic done_lvl, busy_lvl, ready_lvl;

    function automatic [AXI_ADDR_W-1:0] line_addr(input [7:0] bank, input [LINE_AW-1:0] ln);
        line_addr = STACK_BASE + (bank << APERTURE_LOG2) + (ln << 6);   // 64 B lines
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= IDLE; mode <= M_EXEC;
            m_axi_arvalid <= 0; m_axi_awvalid <= 0; m_axi_wvalid <= 0; m_axi_wlast <= 0;
            eng_we <= 0;
            exec_s_d <= 0; chunk_s_d <= 0;
            exec_pend <= 0; chunk_pend <= 0; done_pend <= 0;
            done_chunk_q <= '0; done_first_q <= '0; done_cnt_q <= '0;
            exec_nochunk <= 0;
            flush_map <= '0; res_chunk <= 8'd0; old_chunk <= 8'd0;
            line_q <= '0; fill_left <= '0; beat_q <= '0;
            dirty_clr_tgl <= 1'b0;
            done_lvl <= 1'b0; busy_lvl <= 1'b0; ready_lvl <= 1'b1;
            evt_push <= 1'b0; evt_push_val <= '0;
        end else begin
            eng_we   <= 1'b0;
            evt_push <= 1'b0;

            // edge-detect the synced request toggles -> latch pending jobs
            exec_s_d  <= exec_s;
            chunk_s_d <= chunk_s;
            if (exec_s  ^ exec_s_d)  exec_pend  <= 1'b1;
            if (chunk_s ^ chunk_s_d) chunk_pend <= 1'b1;

            // A9 completion: only meaningful for the resident chunk — a
            // mismatch means that task was switched away; its results are in
            // DDR and the OS delivers the completion (see header).  Latch at
            // most one pending completion.
            if (done_we) begin
                if (done_word[7:0] == res_chunk && res_chunk != 8'd0 && !done_pend) begin
                    done_chunk_q <= done_word[7:0];
                    done_first_q <= done_word[15:8];
                    done_cnt_q   <= {1'b0, done_word[23:16]};
                    done_pend    <= 1'b1;
                end
            end

            case (st)
            // ---------------------------------------------------------------
            IDLE: begin
                busy_lvl <= 1'b0;
                if (chunk_pend) begin
                    // context switch: spill dirty -> old, fill all <- new
                    chunk_pend <= 1'b0;
                    mode       <= M_CHUNK;
                    old_chunk  <= res_chunk;
                    res_chunk  <= chunk_q;      // stable since the toggle
                    done_lvl   <= 1'b0;
                    ready_lvl  <= 1'b0;
                    busy_lvl   <= 1'b1;
                    st <= SAMPLE;
                end else if (exec_pend) begin
                    exec_pend <= 1'b0;
                    if (res_chunk == 8'd0) begin
                        exec_nochunk <= 1'b1;   // no backing chunk: doorbell ignored
                    end else begin
                        mode     <= M_EXEC;
                        done_lvl <= 1'b0;
                        busy_lvl <= 1'b1;
                        st <= SAMPLE;
                    end
                end else if (done_pend) begin
                    done_pend <= 1'b0;
                    if (done_chunk_q == res_chunk) begin
                        mode      <= M_DONE;
                        busy_lvl  <= 1'b1;
                        line_q    <= done_first_q[LINE_AW-1:0];
                        fill_left <= done_cnt_q;
                        if (done_cnt_q == 0) st <= FI_END;
                        else                 st <= FI_AR;
                    end
                end
            end

            // ---- sample the CPU dirty map, hand the CPU a cleared one -----
            SAMPLE: begin
                flush_map     <= dirty;          // stable: CPU quiescent (protocol)
                dirty_clr_tgl <= ~dirty_clr_tgl;
                line_q        <= '0;
                st <= FL_SCAN;
`ifndef SYNTHESIS
                $display("[math_cop] SAMPLE mode=%0d dirty=%032x res=%02x old=%02x",
                         mode, dirty, res_chunk, old_chunk);
`endif
            end

            // ---- flush: walk the map, one 64 B line per AXI write burst ---
            FL_SCAN: begin
                if (flush_map == '0) st <= FL_END;
                else if (flush_map[line_q]) st <= FL_AR;
                else line_q <= line_q + 1'b1;
            end
            FL_AR: begin
                m_axi_awaddr  <= line_addr((mode == M_CHUNK) ? old_chunk : res_chunk, line_q);
                m_axi_awlen   <= BURST - 1;
                m_axi_awvalid <= 1;
                eng_addr <= {line_q, 3'd0};
                beat_q <= 0;
`ifndef SYNTHESIS
                if (!m_axi_awvalid)
                    $display("[math_cop] FLUSH line=%0d -> chunk %02x (mode=%0d)",
                             line_q, (mode == M_CHUNK) ? old_chunk : res_chunk, mode);
`endif
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 0;
                    eng_addr <= {line_q, 3'd0} + 1;
                    st <= FL_PRE;
                end
            end
            FL_PRE: begin
                wbuf[beat_q] <= eng_rdata;
                eng_addr     <= {line_q, 3'd0} + beat_q + 2;
                if (beat_q == BURST - 1) begin
                    beat_q       <= 0;
                    m_axi_wvalid <= 1;
                    m_axi_wdata  <= wbuf[0];
                    m_axi_wlast  <= (BURST == 1);
                    st <= FL_W;
                end else begin
                    beat_q <= beat_q + 1;
                end
            end
            FL_W: begin
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast) begin
                        m_axi_wvalid <= 0; m_axi_wlast <= 0;
                        st <= FL_B;
                    end else begin
                        beat_q <= beat_q + 1;
                        m_axi_wdata <= wbuf[beat_q + 1];
                        m_axi_wlast <= (beat_q + 1 == BURST - 1);
                    end
                end
            end
            FL_B: if (m_axi_bvalid) begin
                // ascending scan: no set bits remain below line_q, so a wrap
                // from 127 re-enters FL_SCAN with an empty map and exits.
                flush_map[line_q] <= 1'b0;
                line_q <= line_q + 1'b1;
                st <= FL_SCAN;
            end

            FL_END: begin
                if (mode == M_EXEC) begin
                    // doorbell: page is coherent with the chunk — ring the A9
                    evt_push     <= 1'b1;
                    evt_push_val <= res_chunk;
                    busy_lvl     <= 1'b0;
                    st <= IDLE;
                end else begin
                    // CHUNK switch: old chunk spilled; fill all of the new one
                    // (chunk 0 = "none": leave the page as-is, just mark ready)
                    if (res_chunk == 8'd0) st <= FI_END;
                    else begin
                        line_q    <= '0;
                        fill_left <= FILL_ALL;
                        st <= FI_AR;
                    end
                end
            end

            // ---- fill: DDR -> BRAM, one 64 B line per AXI read burst ------
            FI_AR: begin
                m_axi_araddr  <= line_addr(res_chunk, line_q);
                m_axi_arlen   <= BURST - 1;
                m_axi_arvalid <= 1;
                beat_q <= 0;
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 0;
                    st <= FI_R;
                end
            end
            FI_R: if (m_axi_rvalid) begin
                eng_addr  <= {line_q, 3'd0} + beat_q;
                eng_wdata <= m_axi_rdata;
                eng_we    <= 1;
                beat_q <= beat_q + 1;
                if (m_axi_rlast) begin
                    if (fill_left <= 1) st <= FI_END;
                    else begin
                        fill_left <= fill_left - 1'b1;
                        line_q    <= line_q + 1'b1;
                        st <= FI_AR;
                    end
                end
            end
            FI_END: begin
                busy_lvl <= 1'b0;
                if (mode == M_CHUNK) ready_lvl <= 1'b1;
                else                 done_lvl  <= 1'b1;   // M_DONE: results in page
                st <= IDLE;
            end

            default: st <= IDLE;
            endcase
        end
    end

    // ---- status levels back to clk_cpu ----------------------------------
    // done/ready are MASKED on the CPU side from the strobe until the synced
    // level is seen LOW: the engine's clear takes a 2-FF round-trip (~40 ns),
    // during which the raw sync still shows the PREVIOUS op's 1 — an immediate
    // poll after EXEC/CHUNK would read stale-done and consume garbage.  The
    // mask drops the moment the cleared level lands, so the next rising edge
    // is the REAL completion.  (busy is informational only — poll done/ready.)
    wire done_sync_raw, ready_sync_raw;
    cdc_sync_bit u_s_done (.dst_clk(clk_cpu), .src_sig(done_lvl),  .dst_sig(done_sync_raw));
    cdc_sync_bit u_s_busy (.dst_clk(clk_cpu), .src_sig(busy_lvl),  .dst_sig(math_busy));
    cdc_sync_bit u_s_rdy  (.dst_clk(clk_cpu), .src_sig(ready_lvl), .dst_sig(ready_sync_raw));

    logic done_mask = 1'b0, ready_mask = 1'b0;
    always_ff @(posedge clk_cpu) begin
        if (exec_we || chunk_we)  done_mask  <= 1'b1;
        else if (!done_sync_raw)  done_mask  <= 1'b0;
        if (chunk_we)             ready_mask <= 1'b1;
        else if (!ready_sync_raw) ready_mask <= 1'b0;
    end
    assign math_done   = done_sync_raw  & ~done_mask;
    assign chunk_ready = ready_sync_raw & ~ready_mask;

    // ---- A9 status word ---------------------------------------------------
    assign stat_word = {8'd0, 3'd0, evt_cnt,          // [23:16] evt FIFO fill
                        res_chunk,                     // [15:8]  resident chunk
                        3'd0, exec_nochunk,            // [3]     EXEC-with-no-chunk (sticky)
                        ~evt_empty, ready_lvl, busy_lvl};

endmodule

`default_nettype wire
