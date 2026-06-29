// tb_blitter_bridge.sv — integrated GP0-bridge -> xt_blitter -> DDR testbench.
//
// tb_xt_blitter drives the blitter's SALLY bus DIRECTLY; the GP0 path
// (axi_blitter_bridge -> bl_addr/data/we -> blitter) is UNTESTED there.  On
// hardware an A9-issued RECT_FILL (vdi.hwfill) completes (STATUS idle) but lands
// no visible pixels and corrupts the running Atari.  This tb replays the EXACT
// A9 byte-write sequence over AXI4-Lite and checks what the blitter actually
// writes to DDR — to reproduce the bug in sim.
//
// Bridge->blitter wiring mirrors fpga_xt_top.sv: the bridge emits a 6-bit
// bl_addr; the 16-bit bus addr is {8'hD4, bl_addr[5]?4'hB:4'hC, bl_addr[3:0]}.

`timescale 1ns/1ps

module tb_blitter_bridge;

    localparam logic [31:0] FB_BASE = 32'h3000_0000;

    logic clk = 0;
    logic rst = 1;
    always #3.333 clk = ~clk;        // ~150 MHz clk_sys

    // ---- AXI4-Lite master side (driven by axi_write8) ---------------------
    logic [31:0] s_axi_awaddr  = 0;
    logic        s_axi_awvalid = 0;
    wire         s_axi_awready;
    logic [31:0] s_axi_wdata   = 0;
    logic [3:0]  s_axi_wstrb   = 0;
    logic        s_axi_wvalid  = 0;
    wire         s_axi_wready;
    wire [1:0]   s_axi_bresp;
    wire         s_axi_bvalid;
    logic        s_axi_bready  = 0;
    logic [31:0] s_axi_araddr  = 0;
    logic        s_axi_arvalid = 0;
    wire         s_axi_arready;
    wire [31:0]  s_axi_rdata;
    wire [1:0]   s_axi_rresp;
    wire         s_axi_rvalid;
    logic        s_axi_rready  = 0;

    // ---- bridge -> blitter register bus -----------------------------------
    wire [5:0]  bl_addr;
    wire [7:0]  bl_data;
    wire        bl_we;
    // Reconstruct the 16-bit SALLY-style bus address exactly as fpga_xt_top:
    // bl_addr[5:4] = page (00=$D4Bx, 01=$D4Cx, 10=$D4Dx, 11=$D4Ex).
    wire [15:0] blit_bus_addr = {8'hD4,
        (bl_addr[5:4] == 2'b00) ? 4'hB :
        (bl_addr[5:4] == 2'b01) ? 4'hC :
        (bl_addr[5:4] == 2'b10) ? 4'hD : 4'hE,
        bl_addr[3:0]};

    // ---- blitter AXI master (write side captured below) -------------------
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    wire        m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    wire        m_axi_wready;
    logic       m_axi_bvalid;
    wire        m_axi_bready;
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    logic       m_axi_arready;
    logic [63:0] m_axi_rdata;
    logic        m_axi_rvalid;
    logic        m_axi_rlast;
    wire         m_axi_rready;

    // blitter status
    wire        bl_busy, bl_cq_full, bl_pat_blocked;
    wire [15:0] bl_seq_counter;

    // ---- new-map device outputs (checked in the new-block test below) ------
    wire [7:0]  spr_addr_o, spr_data_o;
    wire        spr_we_o;
    wire [7:0]  gp0_ctrl_o;
    wire        xt_unlock_we_o;
    wire [31:0] ovl_base_o;
    wire [11:0] ovl_x_o, ovl_y_o, ovl_w_o, ovl_h_o;
    wire        ovl_en_o, ovl_commit_o;
    // diag words driven with known patterns to test the 0x4xx read block, and
    // known clock_mult / unlock for the control-block read-backs.
    localparam [31:0] DIAG0=32'hD1A6_0000, DIAG2=32'hD1A6_0002, DIAG3=32'hD1A6_0003,
                      DIAG4=32'hD1A6_0004, DIAG5=32'hD1A6_0005, DIAG6=32'hD1A6_0006,
                      DIAG7=32'hD1A6_0007;
    localparam [7:0]  CLKMUL_TB = 8'h2A, UNLOCK_TB = 8'h5A;

    // ---- probe: log every register strobe the bridge emits ----------------
    // Also latch the last strobed bl_addr/data and count the sprite/unlock
    // pulses, so the new-block test can verify 1-cycle strobes after the fact.
    int n_strobes = 0, n_unlock = 0, n_spr = 0;
    logic [5:0] last_bl_addr = 0;
    logic [7:0] last_bl_data = 0, last_unlock_data = 0, last_spr_data = 0;
    always @(posedge clk) begin
        if (!rst && bl_we) begin
            n_strobes++;
            last_bl_addr <= bl_addr; last_bl_data <= bl_data;
            $display("  bl_we: bus_addr=$%04X  data=$%02X  (bl_addr[5:0]=%06b)",
                     blit_bus_addr, bl_data, bl_addr);
        end
        if (!rst && xt_unlock_we_o) begin n_unlock++; last_unlock_data <= bl_data; end
        if (!rst && spr_we_o)       begin n_spr++;    last_spr_data    <= spr_data_o; end
    end

    // ---- probe: AXI write-burst events (AW accept, wlast, B handshake) -----
    logic dbg_axi = 1'b0;     // set 1 to trace
    always @(posedge clk) begin
        if (!rst && dbg_axi) begin
            if (m_axi_awvalid && m_axi_awready)
                $display("  [AW] addr=$%08x len=%0d (beats=%0d)", m_axi_awaddr, m_axi_awlen, m_axi_awlen+1);
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                $display("  [WLAST] beat seen");
            if (m_axi_bvalid && m_axi_bready)
                $display("  [B] response accepted");
        end
    end

    // ====================================================================
    // DUTs
    // ====================================================================
    xt_gp0_regs u_bridge (
        .clk            (clk),
        .rst            (rst),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        .bl_addr        (bl_addr),
        .bl_data        (bl_data),
        .bl_we          (bl_we),
        .spr_reg_addr   (spr_addr_o),
        .spr_reg_data   (spr_data_o),
        .spr_reg_we     (spr_we_o),
        .bl_busy        (bl_busy),
        .bl_queue_full  (bl_cq_full),
        .bl_pat_blocked (bl_pat_blocked),
        .bl_seq_counter (bl_seq_counter),
        .diag_word      (DIAG0),
        .diag2_word     (DIAG2),
        .diag3_word     (DIAG3),
        .diag4_word     (DIAG4),
        .diag5_word     (DIAG5),
        .diag6_word     (DIAG6),
        .diag7_word     (DIAG7),
        .clock_mult     (CLKMUL_TB),
        .gp0_ctrl       (gp0_ctrl_o),
        .xt_unlock_we   (xt_unlock_we_o),
        .xt_unlock_state(UNLOCK_TB),
        .overlay_base   (ovl_base_o),
        .overlay_x      (ovl_x_o),
        .overlay_y      (ovl_y_o),
        .overlay_w      (ovl_w_o),
        .overlay_h      (ovl_h_o),
        .overlay_en     (ovl_en_o),
        .overlay_commit (ovl_commit_o)
    );

    xt_blitter #(
        .FB_BASE     (FB_BASE),
        .FB_STRIDE_B (8192)
    ) u_blit (
        .clk          (clk),
        .rst          (rst),
        .bus_addr     (blit_bus_addr),
        .bus_data     (bl_data),
        .bus_we       (bl_we),
        .busy         (bl_busy),
        .cq_full      (bl_cq_full),
        .pat_blocked  (bl_pat_blocked),
        .seq_counter  (bl_seq_counter),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rready (m_axi_rready)
    );

    // ====================================================================
    // AXI HP write/read slave — word-indexed backing store with proper
    // INCR-burst handling (mirrors the proven model in tb_xt_blitter.sv:
    // track aw_pending and use aw_addr + beat*8 per beat; one-shot bvalid).
    // ====================================================================
    localparam int MEMB      = 6*1024*1024;   // 6 MB window from FB_BASE
    localparam int MEM_WORDS = MEMB/8;        // 64-bit words
    logic [63:0] mem [0:MEM_WORDS-1];
    int          nbeats = 0;                  // total write beats observed
    int          min_addr = 0, max_addr = 0;
    int          have_range = 0;

    function automatic int mem_idx(input [31:0] addr);
        return (addr - FB_BASE) >> 3;
    endfunction

    // Combinational bounded read of the backing store for the single-beat AXI
    // read model.  (A function here triggers an iverilog of_RET_VEC4 crash;
    // continuous-assign wires avoid it.)
    wire [31:0] ar_off  = m_axi_araddr - FB_BASE;
    wire [28:0] ar_widx = ar_off[31:3];
    wire [63:0] ar_rdata_w = (ar_widx < MEM_WORDS) ? mem[ar_widx] : 64'd0;

    // ---- write state ----
    logic        aw_pending;
    logic [31:0] aw_addr_q;
    logic [7:0]  aw_len_q;
    logic [7:0]  w_beat_count;
    logic        w_need_bvalid;

    // Combinational ready: AW always accepts; W is ready ONLY when WVALID is
    // asserted.  The blitter advances its beat counter on WREADY alone while
    // its own WVALID is registered (low on each burst's first cycle), so an
    // unconditionally-high WREADY would clock in a phantom beat per burst and
    // desync the slave.  Gating WREADY on WVALID makes the handshake coincide
    // exactly, matching how the Zynq HP interconnect behaves on real silicon.
    assign m_axi_awready = 1'b1;
    assign m_axi_wready  = m_axi_wvalid;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_bvalid <= 0;
            m_axi_arready <= 0; m_axi_rvalid <= 0; m_axi_rlast <= 0; m_axi_rdata <= 0;
            aw_pending <= 0; aw_addr_q <= 0; aw_len_q <= 0;
            w_beat_count <= 0; w_need_bvalid <= 0;
        end else begin
            m_axi_arready <= 1'b1;

            // ---- AW: accept, latch base addr + burst length ----
            if (m_axi_awvalid && m_axi_awready) begin
                aw_pending   <= 1'b1;
                aw_addr_q    <= m_axi_awaddr;
                aw_len_q     <= m_axi_awlen;
                w_beat_count <= 8'd0;
            end

            // ---- W: apply each beat at aw_addr + beat*8 ----
            if (aw_pending && m_axi_wvalid && m_axi_wready) begin
                logic [31:0] beat_addr;
                beat_addr = aw_addr_q + w_beat_count * 8;
                if (dbg_axi) $display("  [axi WR] addr=%08x strb=%02x data=%016x",
                                      beat_addr, m_axi_wstrb, m_axi_wdata);
                for (int b = 0; b < 8; b++) begin
                    if (m_axi_wstrb[b]) begin
                        int wi;
                        wi = mem_idx(beat_addr);
                        if (wi >= 0 && wi < MEM_WORDS)
                            mem[wi][b*8 +: 8] <= m_axi_wdata[b*8 +: 8];
                        if (!have_range) begin
                            min_addr = beat_addr + b; max_addr = beat_addr + b; have_range = 1;
                        end else begin
                            if (beat_addr + b < min_addr) min_addr = beat_addr + b;
                            if (beat_addr + b > max_addr) max_addr = beat_addr + b;
                        end
                    end
                end
                nbeats = nbeats + 1;
                if (m_axi_wlast) begin
                    aw_pending    <= 1'b0;
                    w_need_bvalid <= 1'b1;
                end else begin
                    w_beat_count  <= w_beat_count + 8'd1;
                end
            end

            // ---- B: one-shot response ----
            if (w_need_bvalid) begin
                m_axi_bvalid  <= 1'b1;
                w_need_bvalid <= 1'b0;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid  <= 1'b0;
            end

            // ---- reads (single-beat; SRC_BLIT reads src + dst pixels) ----
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_rvalid <= 1; m_axi_rlast <= 1;
                m_axi_rdata  <= ar_rdata_w;
                if (dbg_axi) $display("  [axi RD] araddr=%08x arlen=%0d -> %016x",
                                      m_axi_araddr, m_axi_arlen, ar_rdata_w);
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 0; m_axi_rlast <= 0;
            end
        end
    end

    // ====================================================================
    // AXI4-Lite master write of one byte at byte offset `off` (mimics Xil_Out8
    // to XT_BLITTER_BASE + off: data in the lane, wstrb that lane).
    // ====================================================================
    task automatic axi_write8(input [11:0] off, input [7:0] v);
        bit aw_done, w_done;
        begin
            aw_done = 0; w_done = 0;
            @(posedge clk);
            s_axi_awaddr  <= {20'd0, off};
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= (32'(v) << (8*off[1:0]));
            s_axi_wstrb   <= (4'b0001 << off[1:0]);
            s_axi_wvalid  <= 1'b1;
            forever begin
                @(posedge clk);
                if (s_axi_awready) begin s_axi_awvalid <= 1'b0; aw_done = 1; end
                if (s_axi_wready)  begin s_axi_wvalid  <= 1'b0; w_done  = 1; end
                if (aw_done && w_done) break;
            end
            s_axi_bready <= 1'b1;
            forever begin @(posedge clk); if (s_axi_bvalid) break; end
            s_axi_bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Word write (all four byte lanes) at byte offset `off`.
    task automatic axi_write32(input [11:0] off, input [31:0] v);
        bit aw_done, w_done;
        begin
            aw_done = 0; w_done = 0;
            @(posedge clk);
            s_axi_awaddr  <= {20'd0, off};
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= v;
            s_axi_wstrb   <= 4'b1111;
            s_axi_wvalid  <= 1'b1;
            forever begin
                @(posedge clk);
                if (s_axi_awready) begin s_axi_awvalid <= 1'b0; aw_done = 1; end
                if (s_axi_wready)  begin s_axi_wvalid  <= 1'b0; w_done  = 1; end
                if (aw_done && w_done) break;
            end
            s_axi_bready <= 1'b1;
            forever begin @(posedge clk); if (s_axi_bvalid) break; end
            s_axi_bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Word read at byte offset `off`.
    task automatic axi_read32(input [11:0] off, output [31:0] v);
        begin
            @(posedge clk);
            s_axi_araddr  <= {20'd0, off};
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;
            forever begin
                @(posedge clk);
                if (s_axi_arready) s_axi_arvalid <= 1'b0;
                if (s_axi_rvalid)  begin v = s_axi_rdata; break; end
            end
            s_axi_arvalid <= 1'b0;
            s_axi_rready  <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic wait_idle();
        int timeout = 200000;
        int waited = 0;
        while (!bl_busy && timeout > 0) begin @(posedge clk); timeout--; end
        if (timeout == 0) $display("NOTE: blitter never asserted busy");
        timeout = 2_000_000;
        while (bl_busy && timeout > 0) begin
            @(posedge clk); timeout--; waited++;
            if (waited % 100000 == 0)
                $display("  ... busy %0d cyc, %0d beats | state=%0d awv=%b wv=%b wl=%b arv=%b bv=%b cx=%0d cy=%0d burst_len=%0d",
                         waited, nbeats, u_blit.state, m_axi_awvalid, m_axi_wvalid,
                         m_axi_wlast, m_axi_arvalid, m_axi_bvalid, u_blit.cx, u_blit.cy, u_blit.burst_len);
        end
        if (timeout == 0) begin
            $display("FATAL: blitter never went idle (%0d beats issued)", nbeats);
            $fatal(1);
        end
    endtask

    // word read of the captured DDR (little-endian over the byte store).
    // `a` is an absolute address; index the byte store by (a - FB_BASE) and
    // return 0 for anything outside the captured window.
    function automatic [31:0] ddr32(input int a);
        automatic int wi = mem_idx(a);
        automatic int byte_off = (a - FB_BASE) & 7;        // 0 or 4 (px-aligned)
        if (wi < 0 || wi >= MEM_WORDS) return 32'd0;
        return mem[wi][byte_off*8 +: 32];
    endfunction

    // ====================================================================
    int a0;
    initial begin
        repeat (8) @(posedge clk);
        rst <= 0;
        dbg_axi <= 1'b0;     // set 1 to trace every AW/wlast/B handshake
        repeat (4) @(posedge clk);

        $display("=== hwfill(400,400,300,200,0xFF8800) over the GP0 bridge ===");
        // 1x1 solid pattern (R,G,B,A=FF,88,00,FF)
        axi_write8(5'h0A, 8'd0);          // PAT_LOG_W = 0
        axi_write8(5'h0E, 8'd0);          // PAT_LOG_H = 0
        axi_write8(5'h08, 8'd0);          // PAT_PHASE_X
        axi_write8(5'h09, 8'd0);          // PAT_PHASE_Y
        axi_write8(5'h0B, 8'hFF);         // PAT_DATA R
        axi_write8(5'h0B, 8'h88);         // PAT_DATA G
        axi_write8(5'h0B, 8'h00);         // PAT_DATA B
        axi_write8(5'h0B, 8'hFF);         // PAT_DATA A
        axi_write8(5'h0F, 8'h03);         // RASTER_OP = S (copy)
        // DST (400,400) 300x200
        axi_write8(5'h00, 8'h90); axi_write8(5'h01, 8'h01);   // X = 0x0190 = 400
        axi_write8(5'h02, 8'h90); axi_write8(5'h03, 8'h01);   // Y = 0x0190 = 400
        axi_write8(5'h04, 8'h2C); axi_write8(5'h05, 8'h01);   // W = 0x012C = 300
        axi_write8(5'h06, 8'hC8); axi_write8(5'h07, 8'h00);   // H = 0x00C8 = 200
        axi_write8(5'h0C, 8'h01);         // CMD = RECT_FILL

        wait_idle();
        repeat (20) @(posedge clk);

        $display("--- results ---");
        $display("write beats observed : %0d", nbeats);
        if (have_range)
            $display("DDR write addr range : 0x%08x .. 0x%08x", min_addr, max_addr);
        else
            $display("DDR write addr range : (NO WRITES)");

        // Expected first pixel: FB_BASE + 400*8192 + 400*4 = 0x30320640
        a0 = FB_BASE + 400*8192 + 400*4;
        $display("pixel(400,400) @0x%08x = 0x%08x  (expect 0xFF8800FF)", a0, ddr32(a0));
        $display("pixel(550,500) @0x%08x = 0x%08x  (expect 0xFF8800FF)",
                 FB_BASE + 500*8192 + 550*4, ddr32(FB_BASE + 500*8192 + 550*4));

        // Sanity: did any write land OUTSIDE the 0x3000_0000..0x3080_0000 plane?
        if (have_range && (min_addr < 32'h3000_0000 || max_addr >= 32'h3080_0000))
            $display("WARN: writes outside the desktop plane (0x30000000..0x30800000)!");

        if (nbeats == 0)
            $display("RESULT: FAIL — blitter issued NO DDR writes (fill did not land)");
        else if (ddr32(FB_BASE + 400*8192 + 400*4) == 32'hFF8800FF)
            $display("RESULT: PASS — orange pixel landed at the expected address");
        else
            $display("RESULT: MISMATCH — wrote %0d beats but pixel/data is wrong (see range)", nbeats);

        // ================================================================
        // LINE_DRAW: diagonal (10,10)->(30,25), DX=20 DY=15 -> 21 pixels.
        // Mirrors gfx_a9's gfx_line register sequence.  Verifies the line
        // walks the WHOLE segment (HW symptom: only the start pixel drew).
        // ================================================================
        nbeats = 0; have_range = 0;
        $display("\n=== LINE_DRAW diagonal (10,10)->(30,25), DX=20 DY=15 ===");
        axi_write8(5'h0A, 8'd0);          // PAT_LOG_W = 0
        axi_write8(5'h0E, 8'd0);          // PAT_LOG_H = 0
        axi_write8(5'h08, 8'd0);          // PAT_PHASE_X
        axi_write8(5'h09, 8'd0);          // PAT_PHASE_Y
        axi_write8(5'h0B, 8'h00);         // PAT_DATA R
        axi_write8(5'h0B, 8'hFF);         // PAT_DATA G (green)
        axi_write8(5'h0B, 8'h00);         // PAT_DATA B
        axi_write8(5'h0B, 8'hFF);         // PAT_DATA A
        axi_write8(5'h0F, 8'h03);         // RASTER_OP = S
        axi_write8(5'h00, 8'd10); axi_write8(5'h01, 8'd0);   // DST_X = 10
        axi_write8(5'h02, 8'd10); axi_write8(5'h03, 8'd0);   // DST_Y = 10
        axi_write8(5'h04, 8'd20); axi_write8(5'h05, 8'd0);   // DST_W = DX = 20
        axi_write8(5'h06, 8'd15); axi_write8(5'h07, 8'd0);   // DST_H = DY = 15
        axi_write8(5'h0C, 8'h02);         // CMD = LINE_DRAW
        wait_idle();
        repeat (20) @(posedge clk);
        $display("line write beats : %0d  (expect 21)", nbeats);
        $display("  start (10,10)  @0x%08x = 0x%08x", FB_BASE+10*8192+10*4, ddr32(FB_BASE+10*8192+10*4));
        $display("  mid   (20,17/18)            = 0x%08x / 0x%08x",
                 ddr32(FB_BASE+17*8192+20*4), ddr32(FB_BASE+18*8192+20*4));
        $display("  end   (30,25)  @0x%08x = 0x%08x", FB_BASE+25*8192+30*4, ddr32(FB_BASE+25*8192+30*4));
        if (nbeats >= 20) $display("LINE RESULT: PASS — full segment drawn");
        else              $display("LINE RESULT: FAIL — only %0d pixels drawn (expected 21)", nbeats);

        // ================================================================
        // $D4Dx descriptor registers: load SRC/DST base+stride through the
        // expanded bridge window (offsets 0x20-0x2B) and check they latched.
        // ================================================================
        $display("\n=== $D4Dx SRC/DST descriptor load (offsets 0x20-0x2B) ===");
        axi_write8(6'h30, 8'h00); axi_write8(6'h31, 8'h00);
        axi_write8(6'h32, 8'h00); axi_write8(6'h33, 8'h31);   // SRC_BASE = 0x31000000
        axi_write8(6'h34, 8'h00); axi_write8(6'h35, 8'h08);   // SRC_STRIDE = 0x0800
        axi_write8(6'h36, 8'h00); axi_write8(6'h37, 8'h00);
        axi_write8(6'h38, 8'h00); axi_write8(6'h39, 8'h32);   // DST_BASE = 0x32000000
        axi_write8(6'h3A, 8'h00); axi_write8(6'h3B, 8'h10);   // DST_STRIDE = 0x1000
        repeat (8) @(posedge clk);
        $display("  SRC_BASE   = 0x%08x (expect 0x31000000)", u_blit.src_base_reg);
        $display("  SRC_STRIDE = 0x%04x     (expect 0x0800)", u_blit.src_stride_reg);
        $display("  DST_BASE   = 0x%08x (expect 0x32000000)", u_blit.dst_base_reg);
        $display("  DST_STRIDE = 0x%04x     (expect 0x1000)", u_blit.dst_stride_reg);
        if (u_blit.src_base_reg == 32'h31000000 && u_blit.src_stride_reg == 16'h0800 &&
            u_blit.dst_base_reg == 32'h32000000 && u_blit.dst_stride_reg == 16'h1000)
            $display("DESC RESULT: PASS — all four descriptors latched via $D4Dx");
        else
            $display("DESC RESULT: FAIL — descriptor load through the new page is wrong");

        // ================================================================
        // SRC_BLIT coverage -> plane through the FULL GP0 bridge path.
        // Coverage atlas @0x30040000 (cov 255,128,0,64), green over black.
        // ================================================================
        $display("\n=== SRC_BLIT coverage -> plane over the GP0 bridge ===");
        mem[mem_idx(32'h3004_0000)] = 64'h0000_0000_4000_80FF;   // coverage atlas
        mem[mem_idx(32'h3000_0000)] = 64'h0; mem[mem_idx(32'h3000_0008)] = 64'h0;  // plane black
        axi_write8(6'h0A, 8'd0);                                  // PAT_LOG_W = 0
        axi_write8(6'h0E, 8'd0);                                  // PAT_LOG_H = 0
        axi_write8(6'h0B, 8'h00); axi_write8(6'h0B, 8'hFF);
        axi_write8(6'h0B, 8'h00); axi_write8(6'h0B, 8'hFF);       // 1x1 green pattern
        axi_write8(6'h30, 8'h00); axi_write8(6'h31, 8'h00);
        axi_write8(6'h32, 8'h04); axi_write8(6'h33, 8'h30);       // SRC_BASE = 0x30040000
        axi_write8(6'h34, 8'd8);  axi_write8(6'h35, 8'd0);        // SRC_STRIDE = 8
        // DST_BASE (= the dest "plane" surface — an explicit DST surface since the
        // addr-gen consolidation) MUST be set here: without it the blit inherits the
        // stale 0x32000000 from the DESC test, which is outside this tb's mem window.
        axi_write8(6'h36, 8'h00); axi_write8(6'h37, 8'h00);
        axi_write8(6'h38, 8'h00); axi_write8(6'h39, 8'h30);       // DST_BASE = 0x30000000 (FB_BASE)
        axi_write8(6'h3A, 8'h00); axi_write8(6'h3B, 8'h10);       // DST_STRIDE = 0x1000
        axi_write8(6'h10, 8'd0);  axi_write8(6'h11, 8'd0);        // SRC_X = 0
        axi_write8(6'h12, 8'd0);  axi_write8(6'h13, 8'd0);        // SRC_Y = 0
        axi_write8(6'h00, 8'd0);  axi_write8(6'h01, 8'd0);        // DST_X = 0
        axi_write8(6'h02, 8'd0);  axi_write8(6'h03, 8'd0);        // DST_Y = 0
        axi_write8(6'h04, 8'd4);  axi_write8(6'h05, 8'd0);        // W = 4
        axi_write8(6'h06, 8'd1);  axi_write8(6'h07, 8'd0);        // H = 1
        axi_write8(6'h18, 8'h0C);                                 // FLAGS: SRC_DDR|SRC_COV (dest=plane)
        axi_write8(6'h0C, 8'h08);                                 // CMD = SRC_BLIT
        wait_idle();
        begin
            int errs; logic [31:0] e, a, g;
            errs = 0;
            for (int xx = 0; xx < 4; xx++) begin
                a = FB_BASE + xx*4;
                g = ddr32(a);
                case (xx)
                    0: e = 32'h00FF00FF;  1: e = 32'h008000FF;
                    2: e = 32'h00000000;  3: e = 32'h004000FF;
                endcase
                $display("  bridge cov pixel %0d = %08x (expect %08x)", xx, g, e);
                if (g !== e) errs++;
            end
            if (errs == 0) $display("SRCBLIT RESULT: PASS — coverage blit landed via the bridge");
            else           $display("SRCBLIT RESULT: FAIL — %0d mismatches", errs);
        end

        // ================================================================
        // NEW PER-BLOCK MAP — each block decodes to the right device signal /
        // read word (the point of the re-partition).  Strobe writes (sprite,
        // unlock, speed/kbd bl_we) are checked via the monitors.
        // ================================================================
        $display("\n=== new per-device block map ===");
        begin
            int errs; logic [31:0] rv; int u0, s0;
            errs = 0;

            // -- Sprite block (0x100): IDX @0x100, DATA+strobe @0x104 --------
            axi_write8(12'h100, 8'hA7);
            if (spr_addr_o !== 8'hA7)       begin errs++; $display("  FAIL spr_addr=%02x exp A7", spr_addr_o); end
            s0 = n_spr;
            axi_write8(12'h104, 8'h3C);
            if (n_spr != s0+1)              begin errs++; $display("  FAIL sprite strobe missing"); end
            if (last_spr_data !== 8'h3C)    begin errs++; $display("  FAIL spr_data=%02x exp 3C", last_spr_data); end

            // -- Compositor block (0x200): whole-word overlay regs ----------
            axi_write32(12'h204, 32'h3456_0000);
            if (ovl_base_o !== 32'h34560000) begin errs++; $display("  FAIL ovl_base=%08x", ovl_base_o); end
            axi_write32(12'h208, 32'h0000_0123);
            if (ovl_x_o !== 12'h123)         begin errs++; $display("  FAIL ovl_x=%03x", ovl_x_o); end
            axi_write32(12'h214, 32'h0000_00C8);
            if (ovl_h_o !== 12'h0C8)         begin errs++; $display("  FAIL ovl_h=%03x", ovl_h_o); end
            axi_write32(12'h200, 32'h0000_0001);
            if (ovl_en_o !== 1'b1)           begin errs++; $display("  FAIL ovl_en"); end

            // -- Control block (0x300): gp0_ctrl + dual-access speed/kbd + unlock
            axi_write8(12'h300, 8'h0A);
            if (gp0_ctrl_o !== 8'h0A)        begin errs++; $display("  FAIL gp0_ctrl=%02x", gp0_ctrl_o); end
            u0 = n_unlock;
            axi_write8(12'h308, 8'h99);                 // UNLOCK
            if (n_unlock != u0+1)            begin errs++; $display("  FAIL unlock strobe missing"); end
            if (last_unlock_data !== 8'h99)  begin errs++; $display("  FAIL unlock data=%02x", last_unlock_data); end
            axi_write8(12'h304, 8'h05);                 // SPEED -> bl_addr $D4CA(0x1A)
            if (last_bl_addr !== 6'h1A)      begin errs++; $display("  FAIL speed bl_addr=%02x exp 1A", last_bl_addr); end
            axi_write8(12'h30C, 8'h41);                 // KBD inject -> bl_addr $D4CF(0x1F)
            if (last_bl_addr !== 6'h1F)      begin errs++; $display("  FAIL kbd bl_addr=%02x exp 1F", last_bl_addr); end

            // -- Reads: control + diag, word-clean (no byte-lane replication) -
            axi_read32(12'h300, rv); if (rv[7:0] !== 8'h0A)     begin errs++; $display("  FAIL rd gp0_ctrl=%08x", rv); end
            axi_read32(12'h304, rv); if (rv[7:0] !== CLKMUL_TB) begin errs++; $display("  FAIL rd speed=%08x", rv); end
            axi_read32(12'h308, rv); if (rv[7:0] !== UNLOCK_TB) begin errs++; $display("  FAIL rd unlock=%08x", rv); end
            axi_read32(12'h400, rv); if (rv !== DIAG0)          begin errs++; $display("  FAIL rd diag0=%08x", rv); end
            axi_read32(12'h404, rv); if (rv !== DIAG2)          begin errs++; $display("  FAIL rd diag2=%08x", rv); end
            axi_read32(12'h418, rv); if (rv !== DIAG7)          begin errs++; $display("  FAIL rd diag7=%08x", rv); end
            axi_read32(12'h040, rv); $display("  blitter STATUS @0x40 = %08x", rv);
            axi_read32(12'h044, rv); $display("  blitter SEQ    @0x44 = %08x (seq=%0d)", rv, rv[15:0]);

            if (errs == 0) $display("NEWMAP RESULT: PASS — all blocks decode + read clean");
            else           $display("NEWMAP RESULT: FAIL — %0d mismatches", errs);
        end

        $finish;
    end

    initial begin
        #5_000_000;
        $display("FATAL: global timeout");
        $finish;
    end

endmodule
