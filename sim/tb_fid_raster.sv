// tb_boot.sv — full-system Atari XL OS cold-start boot testbench.
//
// Proves the emulated 6502 (xt6502) boots the real Atari XL OS ROM through
// cold-start, WITHOUT any hardware / JTAG.  This is the sim-only visibility
// gate before the design goes on the Z-Turn board (~2 weeks out).
//
// It instantiates the boot-relevant core of fpga_xt_top.sv, mirroring its
// wiring exactly (fpga_xt_top lines ~510-857) for:
//   - the CPU (xt6502)
//   - sally_clock (halt bypassed; see the SIM-SPEED NOTE at the instance —
//     fpga_xt_top uses BASE_DIV=68/clock_mult=68 = authentic 1.79 MHz; this tb
//     runs a clean every-cycle grade so the functional boot finishes sooner)
//   - sally_mem (64K BRAM, OS ROM baked in via rsrc/sally-boot.hex)
//   - the hwreg write-path CDC (cdc_fifo_1w1r) + the antic_we_q glue
//   - the hwreg read-back CDC (hwreg_rd_cdc)
//   - the status CDC (cdc_sync_bit) for {nmi_n,irq_n} and halt_n
//   - antic_top (VBLANK NMI + hwreg bus + DMA-read of screen RAM only;
//     display / compositor / writeback / AXI ports tied off as in
//     tb_antic_display).
//
// The DDR3/AXI banked-window master on sally_mem (m_axi_*) is connected to
// the sim axi_slave_mem (always-ready, returns 0) so a stray banked read
// completes instead of hanging.  The OS boots entirely from the 64K BRAM
// image, so it should never fire — but we don't let it hang if it does.
//
// Clocks: clk_sally and clk_sys are both generated here.  clk_sys is run a
// little faster than clk_sally (ANTIC needs to drain the hwreg write FIFO and
// service read-back round-trips faster than SALLY issues them).  phi2_tick is
// tied LOW: sally_clock uses its own sub-phi2 counter to generate the CPU step
// pulses, so phi2_tick is unused (matches fpga_xt_top, which also ties
// phi2_tick = 1'b0).
//
// Boot milestones asserted (the point of this tb):
//   1. PC reaches the $C2xx OS cold-start region after reset.
//   2. RAMTOP ($6A) becomes non-zero (RAM sizing ran; expect ~$A0-$C0).
//   3. RTCLOK ($12/$13/$14) advances over time (ANTIC VBLANK NMI fires +
//      the OS VBLANK service runs — the strongest single liveness signal).
//   4. ANTIC DMACTL ($D400) + DLISTL/DLISTH ($D402/$D403) get programmed
//      non-zero (the OS set up the display).

`default_nettype none
`timescale 1ns / 1ps

module tb_fid_raster;

    // ====================================================================
    // Clocks + reset
    // ====================================================================
    // clk_sally ~100 MHz (10 ns), clk_sys ~150 MHz (6.667 ns) — clk_sys
    // faster so the hwreg CDC FIFO drains and read-back round-trips finish
    // well within a SALLY memory cycle (mirrors the production 100/150 ratio).
    logic clk_sally = 1'b0;  always #5.000 clk_sally = ~clk_sally;   // 100 MHz
    logic clk_sys   = 1'b0;  always #3.750 clk_sys   = ~clk_sys;     // 133.3 MHz (real 3:4 vs clk_sally)

    // Start LOW so the reset-release sequence below produces a clean 0->1->0
    // pulse.  cpu.v resets its FSM `state` on `always @(posedge clk or posedge
    // reset)` — an ASYNC, edge-triggered reset — so a rising edge on rst_sally
    // is REQUIRED to initialise the core (otherwise `state` stays X and the
    // CPU wedges presenting a constant address).  sally_mem / the CDCs use
    // synchronous reset and don't need the edge, but the pulse is harmless.
    logic rst_sally = 1'b0;
    logic rst_sys   = 1'b0;
    wire  rst_sys_n = ~rst_sys;

    // phi2_tick: tied low (sally_clock uses its sub-phi2 counter for steps).
    wire        phi2_tick = 1'b0;

    // ====================================================================
    // CPU <-> memory nets (mirror fpga_xt_top)
    // ====================================================================
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_din, cpu_dout;
    wire        cpu_rw;
    wire        sally_rdy;

    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    wire        mem_busy_n;          // sally_mem busy (1 = ready)
    wire        wsync_rdy_n;         // from ANTIC WSYNC
    wire        halt_n_sally;        // /HALT after CDC (unused at clock_mult>=2)

    // hwreg passthrough (sally_mem <-> hwreg muxing)
    wire [15:0] hwreg_addr;
    wire [7:0]  hwreg_din;
    wire        hwreg_we;
    wire [7:0]  hwreg_dout;

    wire [7:0]  cpu_code_bank, cpu_data_bank;

    // read-back CDC nets
    wire        cdc_bus_read;
    wire [15:0] cdc_bus_addr;
    wire [7:0]  cdc_rd_data;
    wire        hwreg_rd_busy;

    // ANTIC DMA read port into sally_mem's BRAM
    wire [15:0] antic_bram_addr;
    wire [7:0]  antic_bram_rdata;

    // PORTB from PIA (inside antic_top) → sally_mem ROM/RAM control
    wire [7:0]  portb_q;

    // Peripheral-RP SPI link (antic_top peri_bridge ↔ idle-RP model below).
    wire        peri_spi_clk, peri_spi_mosi, peri_spi_cs_n;
    wire        peri_spi_miso;

    // Status CDC outputs (ANTIC → SALLY), declared early so the CPU can bind.
    wire        nmi_n_antic, irq_n_antic, halt_n_antic;
    wire        nmi_n_sync, irq_n_sync;

    // ANTIC combinational read-mux output (read-back CDC bus_rdata).
    wire [7:0]  antic_bus_data_out;
    wire        antic_bus_data_oe;

    // ---- DDR3/AXI banked-window master nets (sally_mem m_axi_*) ----------
    // Declared before sally_mem so iverilog can bind the output ports.
    wire [31:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    wire        axi_arvalid, axi_arready;
    wire [63:0] axi_rdata;
    wire        axi_rvalid, axi_rlast, axi_rready;
    wire [31:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_awvalid, axi_awready;
    wire [63:0] axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast, axi_wvalid, axi_wready;
    wire        axi_bvalid, axi_bready;

    // ====================================================================
    // sally_clock (fpga_xt_top lines ~522-534)
    // ====================================================================
    // SIM-SPEED NOTE.  fpga_xt_top runs BASE_DIV=56; clock_mult resets to 1
    // (1× = real Atari ~1.786 MHz at clk_sally=100 MHz) and software dials it to
    // 56 for full turbo (100 MHz).  At 1× the CPU steps once every 56 clk_sally
    // cycles, which for a *functional* boot sim only makes iverilog slower; the
    // CPU executes the identical instruction stream either way (clock_mult is
    // purely a RDY clock-enable divisor; it does not change CPU semantics,
    // ANTIC's frame cadence, or the CDC handshakes — ANTIC's VBLANK NMI is
    // paced by clk_sys/antic_raster, not by this divisor).
    //
    // So for sim throughput we run the CPU one step per clk_sally cycle using
    // a clean every-cycle grade (BASE_DIV=2, clock_mult=2 → threshold 0).  The
    // halt-bypass condition (clock_mult>=2) is unchanged, so /HALT stays
    // bypassed exactly as in production.  Everything else mirrors fpga_xt_top.
    // Runtime knobs (mirror the HW cfg register): +rel_adj=<signed>
    logic [28:0] tb_cfg = 29'd0;
    initial begin
        int adj;
        if ($value$plusargs("rel_adj=%d", adj))
            tb_cfg[23:20] = adj[3:0];
    end

    // ====================================================================
    // FID core pacing — mirrors fpga_xt_top's fid glue exactly:
    // machine-cycle tick sourced from ANTIC's phi2 (2-FF sync + edge),
    // fid_rdy = mem_ok & ~steal & wsync (write-immune), sally_mem stepped
    // once per window at fid_sub==2.
    // ====================================================================
    wire antic_phi2_level;
    wire antic_dma_steal;
    (* ASYNC_REG="true" *) reg phi2f_s0=0, phi2f_s1=0, phi2f_s2=0;
    always_ff @(posedge clk_sally) begin
        phi2f_s0 <= antic_phi2_level; phi2f_s1 <= phi2f_s0; phi2f_s2 <= phi2f_s1;
    end
    wire       phi2_tick_fid = phi2f_s1 & ~phi2f_s2;
    (* ASYNC_REG="true" *) reg steal_s1=0, steal_s2=0;
    always_ff @(posedge clk_sally) begin
        steal_s1 <= antic_dma_steal; steal_s2 <= steal_s1;
    end
    wire       dma_steal_sally = steal_s2;
    wire [7:0] fid_sub;
    wire       fid_busy = mem_busy_n | hwreg_rd_busy;
    reg        fid_mem_ok = 1'b1;
    always_ff @(posedge clk_sally) if (fid_sub == 8'd49) fid_mem_ok <= ~fid_busy;
    wire       fid_wsync_rdy = wsync_rdy_n | ~cpu_rw;   // production shape (delay slot occurs naturally)
    wire       fid_rdy = fid_mem_ok & ~dma_steal_sally & fid_wsync_rdy;
    assign     sally_rdy  = fid_rdy;          // legacy net name used below
    wire       fid_mem_step = (fid_sub == 8'd2);
    wire [15:0] fdbg_pc; wire [7:0] fdbg_ir;

    xt6502f #(.CLK_SALLY_HZ(100_000_000), .PHI2_HZ(1_785_714)) u_fid_core (
        .clk       (clk_sally),
        .rst       (rst_sally),
        .phi2_tick (phi2_tick_fid),
        .addr      (cpu_addr),
        .data_in   (cpu_din),
        .data_out  (cpu_dout),
        .rw        (cpu_rw),
        .rdy       (fid_rdy),
        .irq_n     (irq_n_sync),
        .nmi_n     (nmi_n_sync),
        .sync      (),
        .dbg_pc    (fdbg_pc), .dbg_a (), .dbg_x (), .dbg_y (), .dbg_s (), .dbg_p (),
        .dbg_sub   (fid_sub), .dbg_ir (fdbg_ir),
        .dbg_load  (1'b0), .dbg_pc_in (16'h0), .dbg_a_in (8'h0), .dbg_x_in (8'h0),
        .dbg_y_in  (8'h0), .dbg_s_in (8'h0), .dbg_p_in (8'h0),
        .dbg_cyc_addr (), .dbg_cyc_val (), .dbg_cyc_rw (), .dbg_cyc_valid ()
    );
    assign cpu_stack_op = 1'b0;                 // fid uses plain $01xx stack accesses
    assign cpu_s_high   = 4'h0;
    wire sally_step = 1'b0;                     // unused in fid pacing

    // ROM-init port (tied off — OS image baked in via OS_ROM_HEX_PATH).
    wire [15:0] rom_load_addr = 16'h0000;
    wire  [7:0] rom_load_data = 8'h00;
    wire        rom_load_we   = 1'b0;

    // ====================================================================
    // sally_mem (fpga_xt_top lines ~576-631) — OS ROM path overridden.
    // ====================================================================
    // Display-shadow mirror + compositor-port nets (declared ahead of both
    // instances that use them).
    wire        mirror_we_w;
    wire [15:0] mirror_addr_w;
    wire [7:0]  mirror_din_w;
    wire [15:0] antic_cmpram_addr;
    wire [7:0]  antic_cmpram_rdata;

    sally_mem #(
        .OS_ROM_HEX_PATH ("../rsrc/sally-boot.hex"),
        .SELFTEST_HEX_PATH ("../rsrc/selftest.hex"),
        .DDR3_BANKED_BASE (32'h2000_0000),
        .DDR3_DATA_BASE   (32'h2040_0000)
    ) u_sally_mem (
        .clk        (clk_sally),
        .rst        (rst_sally),
        .addr       (cpu_addr),
        .data_in    (cpu_dout),
        .rw         (cpu_rw),
        .data_out   (cpu_din),
        .rdy        (fid_mem_step),
        .stack_op   (cpu_stack_op),
        .s_high     (cpu_s_high),
        .busy       (mem_busy_n),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank),
        .cpu_data_bank_q    (cpu_data_bank),
        .unlock_bank        (1'b1),
        .portb              (portb_q),
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'hFF),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
        .m_axi_araddr       (axi_araddr),
        .m_axi_arlen        (axi_arlen),
        .m_axi_arsize       (axi_arsize),
        .m_axi_arburst      (axi_arburst),
        .m_axi_arvalid      (axi_arvalid),
        .m_axi_arready      (axi_arready),
        .m_axi_rdata        (axi_rdata),
        .m_axi_rvalid       (axi_rvalid),
        .m_axi_rlast        (axi_rlast),
        .m_axi_rready       (axi_rready),
        .m_axi_awaddr       (axi_awaddr),
        .m_axi_awlen        (axi_awlen),
        .m_axi_awsize       (axi_awsize),
        .m_axi_awburst      (axi_awburst),
        .m_axi_awvalid      (axi_awvalid),
        .m_axi_awready      (axi_awready),
        .m_axi_wdata        (axi_wdata),
        .m_axi_wstrb        (axi_wstrb),
        .m_axi_wlast        (axi_wlast),
        .m_axi_wvalid       (axi_wvalid),
        .m_axi_wready       (axi_wready),
        .m_axi_bvalid       (axi_bvalid),
        .m_axi_bready       (axi_bready),
        .rom_addr    (rom_load_addr),
        .rom_data    (rom_load_data),
        .rom_we      (rom_load_we),
        .mirror_we_q   (mirror_we_w),
        .mirror_addr_q (mirror_addr_w),
        .mirror_din_q  (mirror_din_w),
        .dma_clk     (clk_sys),
        .dma_addr    (antic_bram_addr),
        .dma_rdata   (antic_bram_rdata)
    );

    // Display-shadow copy — wired exactly like fpga_xt_top (write-mirrored
    // from sally_mem's single write site; compositor reads it).
    display_shadow u_display_shadow (
        .clk_cpu  (clk_sally),
        .mir_we   (mirror_we_w),
        .mir_addr (mirror_addr_w),
        .mir_din  (mirror_din_w),
        .clk_disp (clk_sys),
        .rd_addr  (antic_cmpram_addr),
        .rd_data  (antic_cmpram_rdata)
    );

    // ====================================================================
    // DDR3/AXI banked-window slave stub (always-ready, returns 0).
    // The OS boots from BRAM; this only exists so a stray $6000-$9FFF
    // banked read completes instead of hanging the sim.
    // ====================================================================
    axi_slave_mem #(.ADDR_W(32), .DATA_W(64)) u_axi_stub (
        .clk           (clk_sally),
        .rst           (rst_sally),
        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awlen   (axi_awlen),
        .s_axi_awsize  (axi_awsize),
        .s_axi_awburst (axi_awburst),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wlast   (axi_wlast),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),
        .s_axi_araddr  (axi_araddr),
        .s_axi_arlen   (axi_arlen),
        .s_axi_arsize  (axi_arsize),
        .s_axi_arburst (axi_arburst),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rlast   (axi_rlast),
        .s_axi_rready  (axi_rready)
    );

    // ====================================================================
    // BISECTION PROBE: does the 6502 boot ever WRITE $D1xx (which would fire the
    // real fpga_xt_top $D1DF unlock decode and corrupt xt_unlock)?
    // ALSO: does it touch the BLITTER range $D4Bx/$D4Cx/$D4Ex?  If the OS writes
    // there, locking BLITTER (range -> ANTIC mirror) would hit a real ANTIC reg
    // and corrupt it — the FB-breaks-PRINT bug.  Log writes AND reads.
    logic [15:0] last_d4b_rd = 16'hFFFF;
    always_ff @(posedge clk_sally) begin
        if (hwreg_we && hwreg_addr[15:8] == 8'hD1)
            $display("[D1xx-WRITE] addr=%04h data=%02h @%0t%s", hwreg_addr,
                     hwreg_din, $time, (hwreg_addr==16'hD1DF) ? "  <-- $D1DF!!" : "");
        if (hwreg_we && hwreg_addr[15:8]==8'hD4 &&
            (hwreg_addr[7:4]==4'hB || hwreg_addr[7:4]==4'hC || hwreg_addr[7:4]==4'hE))
            $display("[D4-BLIT-WR] addr=%04h data=%02h @%0t  <-- 6502 writes blitter range!",
                     hwreg_addr, hwreg_din, $time);
        if ((cpu_addr[15:11]==5'b11010) && cpu_rw && cpu_addr[15:8]==8'hD4 &&
            (cpu_addr[7:4]==4'hB || cpu_addr[7:4]==4'hC || cpu_addr[7:4]==4'hE) &&
            cpu_addr != last_d4b_rd) begin
            last_d4b_rd <= cpu_addr;
            $display("[D4-BLIT-RD] addr=%04h @%0t  <-- 6502 reads blitter range!",
                     cpu_addr, $time);
        end
    end

    // CDC: hwreg writes SALLY (clk_sally) → ANTIC (clk_sys)
    // (fpga_xt_top lines ~645-699)
    // ====================================================================
    wire        hwreg_page_rd  = (cpu_addr[15:11] == 5'b11010) & cpu_rw;
    wire        is_blitter_reg = (cpu_addr[15:8] == 8'hD4)
                               & (cpu_addr[7:4] == 4'hB || cpu_addr[7:4] == 4'hC);
    // xtc bank-control regs $D5C0/$D5C1 served locally by sally_mem (off the CDC).
    wire        is_xtc_ctl     = (cpu_addr[15:1] == 15'h6AE0);   // $D5C0-$D5C1
    wire        hwreg_cdc_rd   = hwreg_page_rd & ~is_blitter_reg & ~is_xtc_ctl;

    // Deterministic mesochronous SALLY->ANTIC register-write handoff — mirrors
    // fpga_xt_top exactly (replaced the old cdc_fifo_1w1r).  See fpga_xt_top for
    // the rationale (phase-locked 3:4 clocks, single write in flight).
    logic [23:0] hwreg_wr_payload_q;
    logic        hwreg_wr_tog_q;
    always_ff @(posedge clk_sally or posedge rst_sally) begin
        if (rst_sally) begin
            hwreg_wr_payload_q <= 24'h0;
            hwreg_wr_tog_q     <= 1'b0;
        end else if (hwreg_we) begin
            hwreg_wr_payload_q <= {hwreg_addr, hwreg_din};
            hwreg_wr_tog_q     <= ~hwreg_wr_tog_q;
        end
    end

    logic        hwreg_wr_tog_s0, hwreg_wr_tog_s1, hwreg_wr_tog_s2;
    logic        hwreg_wr_pending;
    logic        antic_we_q;
    logic [15:0] bus_addr_antic_q;
    logic [7:0]  bus_data_in_antic_q;
    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            hwreg_wr_tog_s0     <= 1'b0;
            hwreg_wr_tog_s1     <= 1'b0;
            hwreg_wr_tog_s2     <= 1'b0;
            hwreg_wr_pending    <= 1'b0;
            antic_we_q          <= 1'b0;
            bus_addr_antic_q    <= 16'h0000;
            bus_data_in_antic_q <= 8'h00;
        end else begin
            hwreg_wr_tog_s0 <= hwreg_wr_tog_q;
            hwreg_wr_tog_s1 <= hwreg_wr_tog_s0;
            hwreg_wr_tog_s2 <= hwreg_wr_tog_s1;
            if (hwreg_wr_tog_s1 ^ hwreg_wr_tog_s2) begin
                if (!cdc_bus_read) begin
                    antic_we_q          <= 1'b1;
                    bus_addr_antic_q    <= hwreg_wr_payload_q[23:8];
                    bus_data_in_antic_q <= hwreg_wr_payload_q[7:0];
                    hwreg_wr_pending    <= 1'b0;
                end else begin
                    hwreg_wr_pending    <= 1'b1;
                    antic_we_q          <= 1'b0;
                end
            end else if (hwreg_wr_pending && !cdc_bus_read) begin
                antic_we_q          <= 1'b1;
                bus_addr_antic_q    <= hwreg_wr_payload_q[23:8];
                bus_data_in_antic_q <= hwreg_wr_payload_q[7:0];
                hwreg_wr_pending    <= 1'b0;
            end else begin
                antic_we_q          <= 1'b0;
            end
        end
    end

    wire [15:0] bus_addr_antic    = cdc_bus_read ? cdc_bus_addr : bus_addr_antic_q;
    wire [7:0]  bus_data_in_antic = bus_data_in_antic_q;
    wire        bus_rw_antic      = cdc_bus_read ? 1'b1 : ~antic_we_q;
    wire        d0xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD0)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD0));
    wire        d4xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD4)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD4));

    // ---- Register read-back CDC bridge (fpga_xt_top lines ~705-719) -----
    wire        hwreg_bus_idle = ~hwreg_wr_pending & ~antic_we_q;
    wire [7:0]  antic_rd_ungated;   // antic_top.bus_rdata_int — ungated internal read mux (driven below)
    hwreg_rd_cdc u_hwreg_rd_cdc (
        .clk_sally (clk_sally),
        .rst_sally (rst_sally),
        .rd_req    (hwreg_cdc_rd),
        .rd_addr   (cpu_addr),
        .rd_busy   (hwreg_rd_busy),
        .rd_data   (cdc_rd_data),
        .clk_sys   (clk_sys),
        .rst_sys   (rst_sys),
        .bus_idle  (hwreg_bus_idle),
        .bus_addr  (cdc_bus_addr),
        .bus_read  (cdc_bus_read),
        // DIAGNOSIS: tap antic_top's UNGATED combinational read mux, not the
        // pad output bus_data_out — that one is gated by ext_bus_active
        // (=0 for internal CPU at turbo), so register reads returned $00.
        .bus_rdata (antic_rd_ungated)
    );

    // hwreg_dout feeds sally_mem's read pipeline.  fpga_xt_top routes the
    // blitter regs locally and everything else (ANTIC/GTIA/POKEY/PIA) via the
    // read-back CDC.  No blitter here, so unmapped/blitter regs read $FF and
    // the rest come from cdc_rd_data.  (fpga_xt_top lines ~1303-1313.)
    assign hwreg_dout = is_blitter_reg ? 8'hFF : cdc_rd_data;

    // ====================================================================
    // CDC: status ANTIC → SALLY (fpga_xt_top lines ~724-740)
    // ====================================================================
    cdc_sync_bit #(.WIDTH(2)) u_sync_irq_nmi (
        .dst_clk (clk_sally),
        .src_sig ({nmi_n_antic, irq_n_antic}),
        .dst_sig ({nmi_n_sync,   irq_n_sync})
    );

    cdc_sync_bit #(.WIDTH(1)) u_sync_halt (
        .dst_clk (clk_sally),
        .src_sig (halt_n_antic),
        .dst_sig (halt_n_sally)
    );

    // ====================================================================
    // antic_top (fpga_xt_top lines ~778-851).  Display/compositor/writeback/
    // AXI ports tied off (same pattern as tb_antic_display) — ANTIC here only
    // needs to: generate the VBLANK NMI, serve the hwreg bus, and DMA-read the
    // screen RAM from sally_mem's dma port.
    // ====================================================================
    wire        antic_nmi_n, antic_halt_n, antic_rdy_n, antic_irq_n;

    // ANTIC render-tap nets + READY flag (declared before the instance that
    // drives wb_*; captured/decoded in the "ANTIC render-tap capture" block).
    wire        wb_pix_valid, wb_frame_done, wb_pal_we;
    wire [7:0]  wb_pix_pair, wb_color_lo, wb_color_hi, wb_atari_row, wb_pal_idx;
    wire [23:0] wb_pal_rgb;
    bit         ready_seen = 1'b0;

    antic_top #(
        .POKEY_CLK_BUS_HZ (150_000_000)
    ) u_antic_top (
        .clk_bus            (clk_sys),
        .rst_n              (rst_sys_n),
        .joy_ovr            (32'd0),   // keypad->joystick override off (default)
        // Must be driven, not floating: the WSYNC release cycle is tuned from
        // this register, and an X there stops /RDY ever releasing.
        .dbg_tb_cfg         (tb_cfg),
        .bus_addr           (bus_addr_antic),
        .bus_data_in        (bus_data_in_antic),
        .bus_rw             (bus_rw_antic),
        .d0xx_n             (d0xx_n_antic),
        .d4xx_n             (d4xx_n_antic),
        .bus_data_out       (antic_bus_data_out),
        .bus_data_oe        (antic_bus_data_oe),
        .bus_rdata_int      (antic_rd_ungated),
        .nmi_n              (antic_nmi_n),
        .halt_n             (antic_halt_n),
        .rdy_n              (antic_rdy_n),
        .dma_steal          (antic_dma_steal),
        .phi2_level_o       (antic_phi2_level),
        .dmactl_honor       (1'b0),        // legacy render (no DMACTL screen-blank) for the boot tb
        .irq_n              (antic_irq_n),
        .bus_pbi_in_status_o(),
        .audio_l0(), .audio_l1(), .audio_l2(), .audio_l3(),
        .audio_r0(), .audio_r1(), .audio_r2(), .audio_r3(),
        .audio_present(), .audio_flat(), .audio_block_start(),
        .audio_frame_ready(),
        .dma_addr_o         (),
        .dma_rw_o           (),
        .dma_oe             (),
        .diag_wsync_overdue_count(),
        .kbd_event_valid    (1'b0),
        .kbd_event_code     (8'h00),
        .sally_cold         (1'b0),
        // joy SPI MISO idles HIGH: an open PCAL9722's inputs pull high ($FF =
        // no buttons, switches released, PORTB MMU pull-up).  With it tied 0 the
        // joy_bridge poll read all-zeros and overwrote joy_portb_in's $FF reset →
        // the XL OS read PORTB as $00, did ORA #$02 → OS ROM off → crash.
        //
        // The PERI (SIO/POT) SPI is driven by a behavioral idle-RP model
        // (peri_rp_idle below): with no peripheral attached every register reads
        // $00, so there is no spurious BREAK or ser-in to churn POKEY's IRQ and
        // starve the deferred VBLANK.  The boot's SIO device-probes are stubbed
        // in the OS ROM (see the ROM patch), so no command frame is ever sent.
        .spi_clk            (peri_spi_clk),
        .spi_mosi           (peri_spi_mosi),
        .spi_miso           (peri_spi_miso),
        .spi_cs_n           (peri_spi_cs_n),
        .spi_irq            (1'b1),
        .joy_spi_clk        (),
        .joy_spi_mosi       (),
        .joy_spi_miso       (1'b1),
        .joy_spi_cs_n       (),
        .joy_spi_int_n      (1'b1),
        .bram_addr          (antic_bram_addr),
        .bram_rdata         (antic_bram_rdata),
        .cmp_bram_addr      (antic_cmpram_addr),
        .cmp_bram_rdata     (antic_cmpram_rdata),
        .portb_q            (portb_q),
        .wb_pix_valid       (wb_pix_valid),
        .wb_pix_pair        (wb_pix_pair),
        .wb_color_lo        (wb_color_lo),
        .wb_color_hi        (wb_color_hi),
        .wb_atari_row       (wb_atari_row),
        .wb_row_flush       (),
        .wb_frame_done      (wb_frame_done),
        .wb_pal_we          (wb_pal_we),
        .wb_pal_idx         (wb_pal_idx),
        .wb_pal_rgb         (wb_pal_rgb),
        .adc_bclk_o         (),
        .adc_lrck_o         (),
        .adc_sdata_i        (1'b0),
        .bus_addr_o         (),
        .bus_rw_o           (),
        .bus_d0xx_n_o       (),
        .bus_d4xx_n_o       (),
        .bus_d1xx_n_o       (),
        .bus_s4_n_o         (),
        .bus_s5_n_o         (),
        .bus_cctl_n_o       (),
        .bus_extenb_n_o     (),
        .phi2_o             (),
        .bus_mpd_n_in       (1'b1),
        .bus_extirq_n_in    (1'b1),
        .bus_rd4_in         (1'b1),
        .bus_rd5_in         (1'b1),
        .unlock_antic       (1'b1), .unlock_sprite(1'b1), .unlock_blit(1'b1)
    );

    assign nmi_n_antic  = antic_nmi_n;
    assign irq_n_antic  = antic_irq_n;
    assign halt_n_antic = antic_halt_n;
    assign wsync_rdy_n  = antic_rdy_n;

    // Idle peripheral-RP model on the peri SPI link (no joysticks/POTs/SIO
    // device): every register reads $00, so no spurious POKEY serial IRQs.
    // See peri_rp_idle.sv.
    peri_rp_idle u_peri_rp_idle (
        .rst       (rst_sys),
        .spi_clk   (peri_spi_clk),
        .spi_cs_n  (peri_spi_cs_n),
        .spi_mosi  (peri_spi_mosi),
        .spi_miso  (peri_spi_miso)
    );

    // ====================================================================
    // ANTIC render-tap capture — decode ANTIC's ACTUAL rendered pixels
    // ====================================================================
    // The wb_* render tap (clk_bus = clk_sys in this build) streams ANTIC's
    // output per pixel-pair: 8-bit Atari colour codes (even/odd column) plus the
    // code->RGB palette.  We store raw codes into a flat framebuffer and, on the
    // 2nd frame_done after READY appears (a frame rendered entirely after the
    // prompt is in screen RAM, so it's a complete render), dump fb + palette for
    // Python to resolve into a PNG.  This exercises the real ANTIC pipeline
    // (DLIST fetch -> char gen -> playfield colours), not a font re-model.
    // unwritten mem at X.  The reset BRK sequence pushes to the (uninitialised)
    // hidden stack, so seed it to 0 at t=0 to match the hardware power-up.
    // This is sim modelling only — no RTL is touched.  (xt6502 self-initialises
    // its own register file, so no CPU-reg seeding is needed.)
    integer si;
    initial begin
        for (si = 0; si < 4096; si = si + 1) u_sally_mem.stack_mem[si] = 8'h00;
    end

    // ====================================================================
    // Reset release
    // ====================================================================
    initial begin
        // Both start at 0 (declaration).  Drive a clean rising edge after a
        // few cycles so cpu.v's async `posedge reset` initialises `state`.
        repeat (4) @(posedge clk_sally);   // (also lets sally_mem's t=0 $readmemh settle)
        rst_sally = 1'b1;
        rst_sys   = 1'b1;

        // --- Inject the ACID800 antic_nmist cycle-exact chain at $2000 ---
        // (replaces the OS boot: reset vector -> $2000; DL at $2C00.)
        begin
            static logic [7:0] prog [0:64] = '{
                8'hA9,8'h20,            // LDA #$20
                8'h8D,8'h00,8'hD4,      // STA DMACTL
                8'hA9,8'h00,            // LDA #$00
                8'h8D,8'h0E,8'hD4,      // STA NMIEN
                8'hA9,8'h00,            // LDA #$00
                8'h8D,8'h02,8'hD4,      // STA DLISTL
                8'hA9,8'h2C,            // LDA #$2C
                8'h8D,8'h03,8'hD4,      // STA DLISTH
                8'hA9,8'h13,            // w0: LDA #$13 (vcount 19)
                8'hCD,8'h0B,8'hD4,      // w1: CMP VCOUNT
                8'hF0,8'hFB,            //     BEQ w1  (spin while ==19)
                8'hCD,8'h0B,8'hD4,      // w2: CMP VCOUNT
                8'hD0,8'hFB,            //     BNE w2  (fresh entry into 19)
                8'h8D,8'h0F,8'hD4,      // STA NMIRES
                8'h8D,8'h0A,8'hD4,      // STA WSYNC   (-> end scanline 38)
                8'h48,                  // PHA
                8'h68,                  // PLA
                8'hAD,8'h00,8'h01,      // LDA $0100
                8'hEA,                  // NOP
                8'hAD,8'h0F,8'hD4,      // LDA NMIST   (Avery: data at 39/5)
                8'h8D,8'h00,8'h06,      // STA $0600
                8'h8D,8'h0A,8'hD4,      // STA WSYNC   ($2032) — Avery vcount frag
                8'h8D,8'h0A,8'hD4,      // STA WSYNC
                8'hAD,8'h0B,8'hD4,      // LDA VCOUNT  (his note: runs 107-110)
                8'h8D,8'h01,8'h06,      // STA $0601
                8'h4C,8'h14,8'h20 };    // JMP w0      ($203E)
            for (int k = 0; k < 65; k++) u_sally_mem.mem[16'h2000+k] = prog[k];
            // +prog=1: dlitiming delayed-odd replica (Avery origin_test6
            // shape against our probe DL's DLI at scanline 39).  NMI
            // handler at $2100 records the interrupted PC low byte.
            begin
                int psel;
                if ($value$plusargs("prog=%d", psel) && psel >= 1) begin
                    static logic [7:0] progb [0:56] = '{
                        8'hA9,8'h20, 8'h8D,8'h00,8'hD4,   // LDA #$20 / STA DMACTL
                        8'hA9,8'h00, 8'h8D,8'h0E,8'hD4,   // LDA #0   / STA NMIEN
                        8'hA9,8'h00, 8'h8D,8'h02,8'hD4,   // LDA #0   / STA DLISTL
                        8'hA9,8'h2C, 8'h8D,8'h03,8'hD4,   // LDA #$2C / STA DLISTH
                        8'hA9,8'h13,                       // w0: LDA #$13   ($2014)
                        8'hCD,8'h0B,8'hD4, 8'hF0,8'hFB,    // w1: CMP VCOUNT / BEQ w1
                        8'hCD,8'h0B,8'hD4, 8'hD0,8'hFB,    // w2: CMP VCOUNT / BNE w2
                        8'hEE,8'h0A,8'hD4,                 // INC WSYNC (-> end 38)
                        8'hA9,8'h00, 8'h8D,8'h0E,8'hD4,    // t6=$2023: LDA #0 / STA NMIEN
                        8'hA5,8'h80,                       // LDA $80
                        8'hEA,                             // NOP
                        8'hA9,8'h80, 8'h8D,8'h0E,8'hD4,    // LDA #$80 / STA NMIEN (arm)
                        8'hEA,8'hEA,8'hEA,8'hEA,8'hEA,8'hEA, // NOP sled $2030-2035
                        8'h4C,8'h14,8'h20 };               // JMP w0 ($2036)
                    for (int k = 0; k < 57; k++) u_sally_mem.mem[16'h2000+k] = progb[k];
                    if (psel == 3) begin
                        // PLAIN-odd shape: NMIEN=$80 from the start (before
                        // the sync), INC WSYNC, then the sled.  Expected per
                        // real NMOS: edge@8 lands on the first cycle of the
                        // NOP at (8,9) -> penultimate poll sees it -> hijack
                        // after -> pushed PC = $2032... (offsets differ from
                        // the delayed shape: sled starts right at t6).
                        // Rewrite $2023.. to: NOP sled directly (NMIEN was
                        // already on from init).
                        u_sally_mem.mem[16'h2006]=8'h80;   // LDA #$80 -> STA NMIEN (init on)
                        for (int k=0;k<13;k++) u_sally_mem.mem[16'h2023+k]=8'hEA;
                    end
                    if (psel == 2) begin
                        // delayed-EVEN shape: LDA $80 spans cycles 7-9 so the
                        // cycle-8 edge lands mid-instruction; real NMOS's
                        // penultimate poll (cycle 8) SEES it -> hijack right
                        // after: pushed PC = $2032 (the first NOP after).
                        u_sally_mem.mem[16'h2030]=8'hA5;  // LDA $80
                        u_sally_mem.mem[16'h2031]=8'h80;
                    end
                    if (psel == 6) begin
                        // ACID800 antic_blockednmi test #1 replica: VBI edge
                        // lands during the BRK vector fetch -> must be LOST.
                        // $0600 = IRQ/BRK-handler marker (expected 1),
                        // $0601 = NMI/VBI-handler marker (expected 0),
                        // $0602 = fell-past-BRK marker (expected 0).
                        static logic [7:0] progn [0:55] = '{
                            8'hA9,8'h20, 8'h8D,8'h00,8'hD4,   // LDA #$20 / STA DMACTL
                            8'hA9,8'h00, 8'h8D,8'h0E,8'hD4,   // LDA #0   / STA NMIEN
                            8'hA9,8'h00, 8'h8D,8'h02,8'hD4,   // LDA #0   / STA DLISTL
                            8'hA9,8'h2C, 8'h8D,8'h03,8'hD4,   // LDA #$2C / STA DLISTH
                            8'hA9,8'h7B,                       // LDA #123 (vcount: scan 246/247)
                            8'hCD,8'h0B,8'hD4, 8'hF0,8'hFB,    // CMP VCOUNT / BEQ
                            8'hCD,8'h0B,8'hD4, 8'hD0,8'hFB,    // CMP VCOUNT / BNE
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 246)
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 247)
                            8'hA9,8'h40, 8'h8D,8'h0E,8'hD4,    // LDA #$40 / STA NMIEN  *,104-108
                            8'hAD,8'h00,8'h01,                 // LDA $0100  109-112
                            8'hEA,                             // NOP 113,0
                            8'hEA,                             // NOP 1,2
                            8'h00,                             // BRK 3..9 ($2030)
                            8'hEA,                             // pad
                            8'hEE,8'h02,8'h06,                 // INC $0602 (must not run)
                            8'h4C,8'h35,8'h20 };               // JMP $2035
                        for (int k = 0; k < 56; k++) u_sally_mem.mem[16'h2000+k] = progn[k];
                        // IRQ/BRK handler: INC $0600, spin at $2103
                        u_sally_mem.mem[16'h2100]=8'hEE; u_sally_mem.mem[16'h2101]=8'h00;
                        u_sally_mem.mem[16'h2102]=8'h06; u_sally_mem.mem[16'h2103]=8'h4C;
                        u_sally_mem.mem[16'h2104]=8'h03; u_sally_mem.mem[16'h2105]=8'h21;
                        // NMI handler: INC $0601, spin at $2113
                        u_sally_mem.mem[16'h2110]=8'hEE; u_sally_mem.mem[16'h2111]=8'h01;
                        u_sally_mem.mem[16'h2112]=8'h06; u_sally_mem.mem[16'h2113]=8'h4C;
                        u_sally_mem.mem[16'h2114]=8'h13; u_sally_mem.mem[16'h2115]=8'h21;
                        u_sally_mem.mem[16'hFFFE]=8'h00; u_sally_mem.mem[16'hFFFF]=8'h21;
                        // (FFFA/B set to $2110 below overrides the common $2100)
                    end
                    if (psel == 4) begin
                        // ACID800 antic_vscroldli replica (Avery's two-probe
                        // bracket).  DL = the real test's: VS mode-8 block +
                        // 1-line VS-exit blank+DLI rows at scanlines 40 & 57.
                        // Probe 1: STX VSCROL write lands ~cycle 3 of line 40
                        //   -> MUST take effect (DLI suppressed): $0600 b7=0.
                        // Probe 2: INC zp pushes the write to ~cycle 4 of
                        //   line 57 -> must NOT take effect (DLI fires):
                        //   $0601 b7=1.  NMIEN=0: NMIST records regardless.
                        static logic [7:0] progv [0:108] = '{
                            8'hA9,8'h20, 8'h8D,8'h00,8'hD4,   // LDA #$20 / STA DMACTL
                            8'hA9,8'h00, 8'h8D,8'h0E,8'hD4,   // LDA #0   / STA NMIEN
                            8'hA9,8'h00, 8'h8D,8'h02,8'hD4,   // LDA #0   / STA DLISTL
                            8'hA9,8'h2C, 8'h8D,8'h03,8'hD4,   // LDA #$2C / STA DLISTH
                            8'hA2,8'h01,                       // LDX #1
                            8'hA0,8'h00,                       // LDY #0
                            8'hA9,8'h13,                       // p1=$2018: LDA #19
                            8'hCD,8'h0B,8'hD4, 8'hF0,8'hFB,    // CMP VCOUNT / BEQ
                            8'hCD,8'h0B,8'hD4, 8'hD0,8'hFB,    // CMP VCOUNT / BNE
                            8'h8D,8'h0F,8'hD4,                 // STA NMIRES
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 38)
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 39)
                            8'h48,8'h68,                       // PHA/PLA  *,104..109
                            8'hAD,8'h00,8'h01,                 // LDA $0100  110..113
                            8'h8E,8'h05,8'hD4,                 // STX VSCROL 0,1,2,3 (line 40)
                            8'h48,8'h68,                       // PHA/PLA
                            8'hAD,8'h0F,8'hD4,                 // LDA NMIST
                            8'h8D,8'h00,8'h06,                 // STA $0600
                            8'h8C,8'h05,8'hD4,                 // STY VSCROL (restore 0)
                            8'hA9,8'h1B,                       // p2=$2040: LDA #27
                            8'hCD,8'h0B,8'hD4, 8'hF0,8'hFB,    // CMP VCOUNT / BEQ
                            8'hCD,8'h0B,8'hD4, 8'hD0,8'hFB,    // CMP VCOUNT / BNE
                            8'h8D,8'h0F,8'hD4,                 // STA NMIRES
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 54)
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 55)
                            8'h8D,8'h0A,8'hD4,                 // STA WSYNC (end 56)
                            8'h48,8'h68,                       // PHA/PLA  *,104..109
                            8'hE6,8'hC8,                       // INC $C8   110..113,0
                            8'h8E,8'h05,8'hD4,                 // STX VSCROL 1,2,3,4 (line 57)
                            8'h48,8'h68,                       // PHA/PLA
                            8'hAD,8'h0F,8'hD4,                 // LDA NMIST
                            8'h8D,8'h01,8'h06,                 // STA $0601
                            8'h8C,8'h05,8'hD4,                 // STY VSCROL
                            8'h4C,8'h18,8'h20 };               // JMP p1 ($206A)
                        for (int k = 0; k < 109; k++) u_sally_mem.mem[16'h2000+k] = progv[k];
                        // real test's DL: 3x blank8, VS mode8, exit blank+DLI, blank8, VS mode8, exit blank+DLI, JVB
                        u_sally_mem.mem[16'h2C00]=8'h70; u_sally_mem.mem[16'h2C01]=8'h70;
                        u_sally_mem.mem[16'h2C02]=8'h70; u_sally_mem.mem[16'h2C03]=8'h28;
                        u_sally_mem.mem[16'h2C04]=8'hF0; u_sally_mem.mem[16'h2C05]=8'h70;
                        u_sally_mem.mem[16'h2C06]=8'h28; u_sally_mem.mem[16'h2C07]=8'hF0;
                        u_sally_mem.mem[16'h2C08]=8'h41; u_sally_mem.mem[16'h2C09]=8'h00;
                        u_sally_mem.mem[16'h2C0A]=8'h2C;
                    end
                    // handler: PHA TSX LDA $0103,X STA $0600 PLA RTI
                    u_sally_mem.mem[16'h2100]=8'h48; u_sally_mem.mem[16'h2101]=8'hBA;
                    u_sally_mem.mem[16'h2102]=8'hBD; u_sally_mem.mem[16'h2103]=8'h03;
                    u_sally_mem.mem[16'h2104]=8'h01; u_sally_mem.mem[16'h2105]=8'h8D;
                    u_sally_mem.mem[16'h2106]=8'h00; u_sally_mem.mem[16'h2107]=8'h06;
                    u_sally_mem.mem[16'h2108]=8'h68; u_sally_mem.mem[16'h2109]=8'h40;
                    u_sally_mem.mem[16'hFFFA]=8'h00; u_sally_mem.mem[16'hFFFB]=8'h21;
                    if (psel == 6) begin
                        u_sally_mem.mem[16'hFFFA]=8'h10; u_sally_mem.mem[16'hFFFB]=8'h21;
                    end
                end
            end
            // probe DL (nmist's): 3x blank-8, 2x blank-8+DLI, JVB self
            u_sally_mem.mem[16'h2C00]=8'h70; u_sally_mem.mem[16'h2C01]=8'h70;
            u_sally_mem.mem[16'h2C02]=8'h70; u_sally_mem.mem[16'h2C03]=8'hF0;
            u_sally_mem.mem[16'h2C04]=8'hF0; u_sally_mem.mem[16'h2C05]=8'h41;
            u_sally_mem.mem[16'h2C06]=8'h00; u_sally_mem.mem[16'h2C07]=8'h2C;
            begin
                int psel2;
                // prog=4 (vscroldli) uses the REAL test's DL — re-apply it
                // over the common nmist DL written just above.
                if ($value$plusargs("prog=%d", psel2) && psel2 == 4) begin
                    u_sally_mem.mem[16'h2C00]=8'h70; u_sally_mem.mem[16'h2C01]=8'h70;
                    u_sally_mem.mem[16'h2C02]=8'h70; u_sally_mem.mem[16'h2C03]=8'h28;
                    u_sally_mem.mem[16'h2C04]=8'hF0; u_sally_mem.mem[16'h2C05]=8'h70;
                    u_sally_mem.mem[16'h2C06]=8'h28; u_sally_mem.mem[16'h2C07]=8'hF0;
                    u_sally_mem.mem[16'h2C08]=8'h41; u_sally_mem.mem[16'h2C09]=8'h00;
                    u_sally_mem.mem[16'h2C0A]=8'h2C;
                end
            end
            u_sally_mem.mem[16'hFFFC]=8'h00; u_sally_mem.mem[16'hFFFD]=8'h20;
            $display("[inject] mem[2000..3]=%02h %02h %02h %02h  vec=%02h%02h",
                     u_sally_mem.mem[16'h2000], u_sally_mem.mem[16'h2001],
                     u_sally_mem.mem[16'h2002], u_sally_mem.mem[16'h2003],
                     u_sally_mem.mem[16'hFFFD], u_sally_mem.mem[16'hFFFC]);
            $fflush;
        end
        // Hold reset asserted well past both clock domains' pipe depth.
        repeat (64) @(posedge clk_sys);
        rst_sys = 1'b0;
        repeat (64) @(posedge clk_sally);
        // Hold the CPU until ANTIC's free-running raster has performed at
        // least one DL parse (kick at scanline 260) — otherwise a short
        // test completes before the parser ever runs and the walker serves
        // blank-fill (measured: whole 2-run test = 259k clk, kick never
        // fired).  ANTIC (rst_sys) is already released above.
        wait (u_antic_top.u_dl_parser.parse_count != 0);
        rst_sally = 1'b0;
        $display("[%0t] reset released after parse #%0d; vector = $%02h%02h",
                 $time, u_antic_top.u_dl_parser.parse_count,
                 u_sally_mem.mem[16'hFFFD], u_sally_mem.mem[16'hFFFC]);
    end

    // Absolute sim-time watchdog (in case the clk_sally cycle counter never
    // advances, e.g. RDY stuck low → no steps, so the cyc-based budget never
    // trips).  One ANTIC frame is ~18 ms sim time (clk_sys/90 phi2, 262×114
    // machine cycles); full cold-start spans several frames.  CYCLE_BUDGET
    // (60 M clk_sally = 0.6 s sim) is the primary stop; this watchdog sits a
    // little above it so a stalled-clock hang still terminates with a dump.
    initial begin
        #750_000_000;   // 0.75 s sim time (> 60 M clk_sally @ 10 ns = 0.6 s)
        $display("");
        $display("*** WATCHDOG TIMEOUT — sim time elapsed ***");
        $finish;
    end

    // ====================================================================
    // Per-cycle tracer: every fid commit inside the measured chain prints
    // (PC, IR, raster scanline, phi2-in-line).  The LDA NMIST data cycle is
    // the last commit of the $202C instruction.
    // ====================================================================
    int chain_runs = 0;
    reg watch_q = 0;
    always @(posedge clk_sally) if (u_fid_core.slot_commit && u_fid_core.rdy)
        watch_q <= (fdbg_pc == 16'h203E || fdbg_pc == 16'h2036 || fdbg_pc == 16'h206A || fdbg_pc == 16'h2103 || fdbg_pc == 16'h2113 || fdbg_pc == 16'h2035);
    // walker-state tracer: cycle-6 snapshot of the DLI decision inputs.
    always @(posedge clk_sys) begin
        if (u_antic_top.phi2_tick && u_antic_top.ar_phi2_in_line == 8'd6
            && u_antic_top.ar_scanline >= 30 && u_antic_top.ar_scanline <= 60
            && u_antic_top.u_dl_parser.parse_count != 0)
            $display("[walk] scan=%0d arow=%0d idx=%0d dctr=%0d curdli=%b mode=%h fill=%b prevvs=%b curvs=%b islast=%b isldli=%b dliat=%b",
                     u_antic_top.ar_scanline,
                     u_antic_top.ar_atari_row,
                     u_antic_top.u_dl_parser.w_idx,
                     u_antic_top.u_dl_parser.w_dctr,
                     u_antic_top.u_dl_parser.cur_dli,
                     u_antic_top.u_dl_parser.cur_mode,
                     u_antic_top.u_dl_parser.cur_fill,
                     u_antic_top.u_dl_parser.w_prev_vs,
                     u_antic_top.u_dl_parser.cur_vs,
                     u_antic_top.u_dl_parser.w_is_last,
                     u_antic_top.u_dl_parser.w_is_last_dli,
                     u_antic_top.u_dl_parser.dli_at);
    end
    // vscroldli probe tracer: raster position of every landmark commit.
    always @(posedge clk_sally) begin
        if (!rst_sally && u_fid_core.slot_commit && u_fid_core.rdy)
            case (fdbg_pc)
                16'h2032, 16'h2037, 16'h205C, 16'h2061:
                    $display("[vsc] PC=%04h IR=%02h scan=%0d cyc=%0d vscrol_q=%0d dliq=%0d stopq=%0d",
                             fdbg_pc, fdbg_ir,
                             u_antic_top.ar_scanline, u_antic_top.ar_phi2_in_line,
                             u_antic_top.u_dl_parser.vscrol,
                             u_antic_top.u_dl_parser.vscrol_dli_q,
                             u_antic_top.u_dl_parser.vscrol_stop_q);
                default: ;
            endcase
    end
    // /NMI arrival tracer: wall position of every nmi_pend rise + the
    // commit slots bracketing it (only near the DLI scanlines).
    reg pend_q0 = 0;
    always @(posedge clk_sally) begin
        pend_q0 <= u_fid_core.nmi_pend;
        if (u_fid_core.nmi_pend && !pend_q0)
            $display("[nmi] pend RISE at scan=%0d cyc=%0d (sub=%0d)",
                     u_antic_top.ar_scanline, u_antic_top.ar_phi2_in_line,
                     u_fid_core.sub);
        if (u_fid_core.slot_commit && fid_rdy
            && ((u_antic_top.ar_scanline == 9'd39 && u_antic_top.ar_phi2_in_line <= 8'd14)
                || (u_antic_top.ar_scanline == 9'd248 && u_antic_top.ar_phi2_in_line <= 8'd14)
                || (u_antic_top.ar_scanline == 9'd247 && u_antic_top.ar_phi2_in_line >= 8'd98)))
            $display("[nmi] commit @ scan=%0d cyc=%0d PC=%04h IR=%02h st=%0d pend=%b d1=%b p1=%b p2=%b svc=%b intr=%b",
                     u_antic_top.ar_scanline,
                     u_antic_top.ar_phi2_in_line, fdbg_pc, fdbg_ir,
                     u_fid_core.state,
                     u_fid_core.nmi_pend, u_fid_core.nmi_d1,
                     u_fid_core.nmi_polled, u_fid_core.nmi_polled2,
                     u_fid_core.nmi_svc, u_fid_core.intr);
    end
    // Parse-path probe: count start_parse pulses + dl_start kicks, and dump
    // the parser's state transitions for the first few.
    int sp_cnt = 0;
    int kick_cnt = 0, dls_cnt = 0;
    always @(posedge clk_sys) begin
        if (u_antic_top.parse_kick_pulse) kick_cnt++;
        if (u_antic_top.dl_start_pulse)   dls_cnt++;
        if (u_antic_top.u_dl_parser.start_parse) begin
            sp_cnt++;
            if (sp_cnt <= 3)
                $display("[parse] start_parse #%0d at scan=%0d (dirty=%b dl_pos=%04h)",
                         sp_cnt, u_antic_top.ar_scanline,
                         u_antic_top.u_dl_parser.dlist_dirty,
                         u_antic_top.u_dl_parser.dl_pos);
        end
        // Per-opcode dump: every DL byte the parser decodes, with position.
        if (u_antic_top.u_dl_parser.state == 3 /*S_DECODE_OP*/)
            $display("[dlop] p#%0d op=%02h at dl_pos=%04h ops=%0d ec=%0d lead=%0d st=%0d",
                     u_antic_top.u_dl_parser.parse_count,
                     u_antic_top.u_dl_parser.mem_rdata,
                     u_antic_top.u_dl_parser.dl_pos,
                     u_antic_top.u_dl_parser.ops,
                     u_antic_top.u_dl_parser.ecount,
                     u_antic_top.u_dl_parser.lead_skipped,
                     u_antic_top.u_dl_parser.scan_total);
    end
    int boot_trace = 0;
    bit  post_arm = 0;
    always @(posedge clk_sally) begin
        if (u_fid_core.slot_commit && fid_rdy && fdbg_pc == 16'h2033) begin
            post_arm <= 1; boot_trace <= 0;
        end
        if (!rst_sally && u_fid_core.slot_commit && post_arm && boot_trace < 45) begin
            boot_trace++;
            $display("[boot] #%0d PC=%04h IR=%02h addr=%04h rw=%b din=%02h rdy=%b scan=%0d cyc=%0d",
                     boot_trace, fdbg_pc, fdbg_ir, cpu_addr, cpu_rw, cpu_din, fid_rdy,
                     u_antic_top.ar_scanline, u_antic_top.ar_phi2_in_line);
            $fflush;
        end
    end
    // Flushed heartbeat: proves sim-time advance + shows where the CPU is.
    longint hb = 0;
    always @(posedge clk_sally) begin
        hb++;
        if (hb % 200_000 == 0) begin
            $display("[hb] clk=%0d scan=%0d PC=%04h parse=%0d act=%0d ph=%0d pstate=%0d praddr=%04h prdy=%b dmamode=%b",
                     hb, u_antic_top.ar_scanline, fdbg_pc,
                     u_antic_top.u_dl_parser.parse_count,
                     u_antic_top.u_dl_parser.act_count,
                     u_antic_top.u_dl_parser.ph_act_cnt,
                     u_antic_top.u_dl_parser.state,
                     u_antic_top.u_dl_parser.mem_raddr,
                     u_antic_top.u_dl_parser.mem_ready,
                     u_antic_top.dma_mode_q);
            $fflush;
        end
    end
    always @(posedge clk_sally) begin
        if (!rst_sally && u_fid_core.slot_commit && u_fid_core.rdy
            && fdbg_pc >= 16'h2020 && fdbg_pc <= 16'h2040) begin
            $display("[chain] PC=%04h IR=%02h  scan=%0d cyc=%0d",
                     fdbg_pc, fdbg_ir,
                     u_antic_top.ar_scanline, u_antic_top.ar_phi2_in_line);
        end
        if (!rst_sally && u_fid_core.slot_commit && u_fid_core.rdy
            && (fdbg_pc == 16'h203E || fdbg_pc == 16'h2036 || fdbg_pc == 16'h206A || fdbg_pc == 16'h2103 || fdbg_pc == 16'h2113 || fdbg_pc == 16'h2035)
            && !watch_q) begin // JMP w0 (prog A/B) or JMP p1 (prog 4) — once per hit
            chain_runs++;
            $display("[probe] kicks=%0d dl_starts=%0d sp=%0d scan_now=%0d", kick_cnt, dls_cnt, sp_cnt, u_antic_top.ar_scanline);
            $display("[chain] ---- run %0d @PC=%04h: NMIST=$%02h VCOUNT=$%02h PCL=$%02h m602=$%02h parse=%0d act=%0d ph=%0d ----",
                     chain_runs, fdbg_pc, u_sally_mem.mem[16'h0600], u_sally_mem.mem[16'h0601],
                     u_sally_mem.mem[16'h0600], u_sally_mem.mem[16'h0602],
                     u_antic_top.u_dl_parser.parse_count,
                     u_antic_top.u_dl_parser.act_count,
                     u_antic_top.u_dl_parser.ph_act_cnt);
            if (chain_runs == 3) begin
                $display("*** FID_RASTER done: chain runs traced ***");
                $finish;
            end
        end
    end

endmodule

`default_nettype wire
