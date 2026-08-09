// tb_cmp_fetch.sv — INTEGRATION test of the compositor's per-scanline memory
// FETCH path, wired EXACTLY as antic_top wires it:
//
//   compositor  ──cmp_raddr/cmp_req/cmp_rdata/cmp_ready──►  mem_read_mux (u_mux_cmp)
//        snoop side ──► bram_shim (port B) ──► sally_mem-style registered dual-port RAM
//        dma   side ──► dma_arbiter (port p1) ──► dma_master ──► data_i RAM model
//
// The existing coverage cannot see the HW bug:
//   * tb_antic_modes ties mem_ready=1 with a *combinational* RAM (zero latency,
//     no bram_shim, no arbiter) — the compositor never actually stalls.
//   * tb_mem_read_mux ties sh_ready=1 (plain BRAM, no bram_shim) and uses a
//     *combinational* data_i — the bram_shim ready/rdata timing against a REAL
//     consumer is never co-simulated.
//
// This TB drives the acid800 antic_pmdma scenario (1-line P/M DMA, PMBASE=$37,
// player-0 shape byte $80 planted at $3400) through the real chain and asserts
// the compositor LATCHES $80 (not $00).  Run in both snoop (HW default —
// mode_snoop is reset-locked to 1 so dma_mode_q is always 0) and DMA modes.
//
// A second port-0 (dl_parser-style) requester can be pointed at the shared
// arbiter to reproduce p0/p1 contention on the DMA path.

`default_nettype none
`timescale 1ns / 1ps

module tb_cmp_fetch;

    localparam logic [15:0] LMS = 16'h1000;
    localparam logic [7:0]  CHB = 8'h20;
    localparam int          UNITS = 40;

    logic clk = 1'b0;  always #5 clk = ~clk;    // 100 MHz fabric
    logic rst = 1'b1;

    // Mode select: 0 = snoop (bram_shim), 1 = DMA (arbiter + dma_master).
    logic dma_mode = 1'b0;

    // ---- synthetic phi2 for dma_master (fabric/DIV) ----------------------
    localparam int CLOCK_DIV = 6;
    logic [3:0] phi2_div = 4'd0;
    logic       phi2     = 1'b0;
    always @(posedge clk) begin
        if (phi2_div == (CLOCK_DIV-1)) begin phi2_div <= 4'd0; phi2 <= ~phi2; end
        else phi2_div <= phi2_div + 4'd1;
    end

    // ---- backing 64 KB RAM (single array, shared by both paths) ----------
    logic [7:0] mem [0:65535];

    // ---- compositor register/meta inputs ---------------------------------
    logic [3:0]  m_mode;
    logic [15:0] m_lms;
    logic [3:0]  m_sub;
    logic [7:0]  chbase_r;
    logic        start;
    logic [7:0]  pmbase_r, dmactl_r, gractl_r, sizem_r, vdelay_r;
    logic [7:0]  hposp_r [0:3], hposm_r [0:3];
    logic [1:0]  sizep_r [0:3];
    logic [7:0]  grafp_r [0:3];
    logic [7:0]  grafm_r;
    logic        hitclr_r;

    // ---- compositor <-> mem_read_mux -------------------------------------
    wire [7:0]  meta_row;
    wire [15:0] cmp_raddr;
    wire        cmp_req;
    wire [7:0]  cmp_rdata;
    wire        cmp_ready;
    wire [1:0]  cmd_tag;
    wire [23:0] cmd_addr, cmd_data;
    wire        cmd_valid;
    wire [15:0] mpf, ppf, mpl, ppl;
    wire        compose_done;
    wire [31:0] compose_count;

    compositor dut (
        .clk(clk), .rst(rst),
        .start_compose(start), .row_in(8'd0),
        .meta_row(meta_row), .meta_mode(m_mode), .meta_lms_addr(m_lms),
        .meta_sub_row(m_sub), .meta_hscrol_en(1'b0), .meta_vscrol_en(1'b0),
        .chbase(chbase_r), .chactl(8'h0), .pmbase(pmbase_r), .dmactl(dmactl_r), .gractl(gractl_r),
        .hposp0(hposp_r[0]), .hposp1(hposp_r[1]), .hposp2(hposp_r[2]), .hposp3(hposp_r[3]),
        .hposm0(hposm_r[0]), .hposm1(hposm_r[1]), .hposm2(hposm_r[2]), .hposm3(hposm_r[3]),
        .sizep0(sizep_r[0]), .sizep1(sizep_r[1]), .sizep2(sizep_r[2]), .sizep3(sizep_r[3]),
        .sizem(sizem_r), .vdelay(vdelay_r), .hscrol(4'h0), .vscrol(4'h0), .prior(8'h0),
        .grafp0(grafp_r[0]), .grafp1(grafp_r[1]), .grafp2(grafp_r[2]), .grafp3(grafp_r[3]),
        .grafm(grafm_r),
        .mem_raddr(cmp_raddr), .mem_rdata(cmp_rdata), .mem_req(cmp_req), .mem_ready(cmp_ready),
        .cmd_tag(cmd_tag), .cmd_addr(cmd_addr), .cmd_data(cmd_data),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1),
        .mpf_q(mpf), .ppf_q(ppf), .mpl_q(mpl), .ppl_q(ppl), .hitclr(hitclr_r),
        .compose_done(compose_done), .compose_count(compose_count)
    );

    // ---- snoop side: bram_shim (port B) + sally_mem-style RAM ------------
    // Port A (dl_parser) is driven by the optional contention generator.
    wire [15:0] sh_raddr;      // cmp side  -> bram_shim.raddr_b
    wire        sh_req;
    wire [7:0]  sh_rdata;
    wire        sh_ready;

    logic [15:0] a_raddr = 16'h0;   // port A driver (dl_parser-like)
    logic        a_req   = 1'b0;
    wire [7:0]  a_rdata;
    wire        a_ready;

    wire [15:0] bram_addr;
    // sally_mem DMA read port model: registered read, dma_rdata_q <= mem[addr].
    logic [7:0] bram_rdata_q;
    always_ff @(posedge clk) bram_rdata_q <= mem[bram_addr];
    wire [7:0]  bram_rdata = bram_rdata_q;

    bram_shim #(.ADDR_W(16)) u_bram_shim (
        .clk(clk), .rst(rst),
        .bram_addr(bram_addr), .bram_rdata(bram_rdata),
        .req_a(a_req),   .raddr_a(a_raddr), .rdata_a(a_rdata), .ready_a(a_ready),
        .req_b(sh_req),  .raddr_b(sh_raddr), .rdata_b(sh_rdata), .ready_b(sh_ready)
    );

    // ---- dma side: arbiter (p1) + dma_master + data_i RAM ----------------
    wire        cmp_dma_req;
    wire [15:0] cmp_dma_addr;
    wire        cmp_dma_ack, cmp_dma_dvalid;
    wire [7:0]  cmp_dma_rdata;
    wire        dma_busy_w;

    // Optional p0 (dl_parser-style) DMA requester onto the shared arbiter.
    logic        p0_req_r   = 1'b0;
    logic [15:0] p0_addr_r  = 16'h0;
    wire         p0_ack, p0_dvalid;
    wire [7:0]   p0_rdata;

    wire        arb_dma_req;
    wire [15:0] arb_dma_addr;
    wire        arb_dma_ack, arb_dma_dvalid;
    wire [7:0]  arb_dma_rdata;

    dma_arbiter u_arb (
        .clk(clk), .rst(rst),
        .p0_req(p0_req_r), .p0_addr(p0_addr_r),
        .p0_ack(p0_ack), .p0_data_valid(p0_dvalid), .p0_rdata(p0_rdata),
        .p1_req(cmp_dma_req), .p1_addr(cmp_dma_addr),
        .p1_ack(cmp_dma_ack), .p1_data_valid(cmp_dma_dvalid), .p1_rdata(cmp_dma_rdata),
        .dma_req(arb_dma_req), .dma_addr(arb_dma_addr),
        .dma_ack(arb_dma_ack), .dma_data_valid(arb_dma_dvalid),
        .dma_rdata(arb_dma_rdata), .dma_busy(dma_busy_w));

    wire        halt_n;
    wire [15:0] addr_o;
    wire        rw_o, bus_oe;
    wire [7:0]  data_i = bus_oe ? mem[addr_o] : 8'hFF;

    dma_master u_dma_master (
        .clk(clk), .rst(rst), .phi2(phi2),
        .req(arb_dma_req), .req_addr(arb_dma_addr),
        .ack(arb_dma_ack), .data_valid(arb_dma_dvalid),
        .req_data(arb_dma_rdata), .busy(dma_busy_w),
        .halt_n(halt_n), .addr_o(addr_o), .rw_o(rw_o), .bus_oe(bus_oe),
        .data_i(data_i));

    // ---- mem_read_mux (u_mux_cmp) ----------------------------------------
    mem_read_mux #(.ADDR_W(16)) u_mux_cmp (
        .clk(clk), .rst(rst), .dma_mode(dma_mode),
        .caller_raddr(cmp_raddr), .caller_req(cmp_req),
        .caller_rdata(cmp_rdata), .caller_ready(cmp_ready),
        .sh_raddr(sh_raddr), .sh_req(sh_req),
        .sh_rdata(sh_rdata), .sh_ready(sh_ready),
        .dma_req(cmp_dma_req), .dma_addr(cmp_dma_addr),
        .dma_ack(cmp_dma_ack), .dma_data_valid(cmp_dma_dvalid),
        .dma_rdata(cmp_dma_rdata), .dma_busy(dma_busy_w));

    int fail = 0;

    // ---- Contention generator (dl_parser-style port-A / p0 requester) ----
    // When contend_en=1, fire a one-cycle request pulse on the higher-
    // priority port every few cycles, so it occasionally lands on the same
    // cycle as the compositor's own one-cycle pulse.
    logic contend_en = 1'b0;
    logic [3:0] contend_div = 4'd0;
    always_ff @(posedge clk) begin
        a_req    <= 1'b0;
        p0_req_r <= 1'b0;
        if (contend_en) begin
            contend_div <= contend_div + 4'd1;
            if (contend_div == 4'd6) begin
                contend_div <= 4'd0;
                a_raddr   <= 16'h2000;
                p0_addr_r <= 16'h2000;
                if (!dma_mode) a_req    <= 1'b1;   // snoop: bram_shim port A
                else           p0_req_r <= 1'b1;   // dma:   arbiter p0
            end
        end else begin
            contend_div <= 4'd0;
        end
    end

    // ---- SET-stream capture ----------------------------------------------
    logic [7:0] cap_lo [0:255];
    int         cap_n;
    logic       cap_reset;
    always_ff @(posedge clk) begin
        if (cap_reset) cap_n <= 0;
        else if (cmd_valid) begin
            cap_lo[cap_n] <= cmd_data[7:0];
            cap_n         <= cap_n + 1;
        end
    end

    // ---- helpers ---------------------------------------------------------
    integer i;
    task automatic clear_mem;
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    endtask

    task automatic compose_row_lms(input logic [3:0] mode, input logic [3:0] sub,
                                   input logic [7:0] chb, input logic [15:0] lms);
        int g;
        @(negedge clk);
        m_mode = mode;  m_sub = sub;  m_lms = lms;  chbase_r = chb;
        start = 1'b1;    @(negedge clk);  start = 1'b0;
        g = 0;
        do begin @(posedge clk); g++; end while (!compose_done && g < 200000);
        if (g >= 200000) begin
            $display("FAIL: compose(%01h) never completed (compositor STALLED in fetch)", mode);
            fail++;
        end
        repeat (4) @(posedge clk);
    endtask

    // ---- P/M DMA fetch scenario (acid800 antic_pmdma) --------------------
    task automatic run_pmdma(input string label);
        hitclr_r = 1'b1; @(negedge clk); hitclr_r = 1'b0;
        clear_mem;
        for (i = 0; i < UNITS+1; i = i + 1) mem[LMS+i] = 8'hFF;   // PF all set
        gractl_r = 8'h02;                 // player presence + DMA
        dmactl_r = 8'h18;                 // bit3 player DMA, bit4 1-line res
        pmbase_r = 8'h37;                 // 1-line: region = ($37 & $F8)<<8 = $3000
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        // P0 shape supplied ONLY by DMA. Player-memory offset = physical scanline
        // (acid800 antic_pmdma: sta $3400,x; at scanline 8 read $3400+8). The
        // compositor fetches phys_row = row(0) + PM_ROW_OFFSET(8) = $3408, so the
        // shape byte MUST be planted at $3408, not $3400 (matches tb_antic_modes).
        mem[16'h3408] = 8'h80;
        hposp_r[0] = 8'd80;  sizep_r[0] = 2'd0;
        compose_row_lms(4'hF, 4'd0, CHB, LMS);
        $display("  [%s] p0_shape=%02h (exp 80)  ppf=%04h", label, dut.p0_shape, ppf);
        if (dut.p0_shape !== 8'h80) begin
            $display("FAIL [%s] p0_shape=%02h expected $80 (compositor fetched WRONG/$00)",
                     label, dut.p0_shape);
            fail++;
        end else
            $display("  [%s] OK (P0 shape $80 fetched via the real chain)", label);
    endtask

    // ---- 4K screen wrap scenario (acid800 antic_addresswrap) -------------
    task automatic run_wrap(input string label);
        logic [23:0] cap_lo15, cap_lo16;
        hitclr_r = 1'b1; @(negedge clk); hitclr_r = 1'b0;
        clear_mem;
        gractl_r = 8'h00; dmactl_r = 8'h00; pmbase_r = 8'h00;
        vdelay_r = 8'h00; sizem_r = 8'h00; grafm_r = 8'h00;
        for (i = 0; i < 4; i = i + 1) begin
            sizep_r[i] = 2'd0; hposp_r[i] = 8'h0; grafp_r[i] = 8'h00;
        end
        for (i = 0; i < 16; i = i + 1)  mem[16'h0FF0 + i] = 8'hFF;   // pre-wrap lit
        for (i = 0; i < 24; i = i + 1)  mem[16'h0000 + i] = 8'h00;   // wrap target unlit
        for (i = 0; i < 24; i = i + 1)  mem[16'h1000 + i] = 8'hFF;   // decoy
        cap_reset = 1'b1; @(negedge clk); cap_reset = 1'b0;
        compose_row_lms(4'hF, 4'd0, CHB, 16'h0FF0);
        // unit15 pre-wrap ($FF->$02); unit16 wrapped $0000 ($00->$04, NOT $02).
        $display("  [%s] unit15=%02h (exp 02)  unit16=%02h (exp 04)",
                 label, cap_lo[15*4], cap_lo[16*4]);
        if (cap_lo[15*4] !== 8'h02) begin
            $display("FAIL [%s] unit15 pre-wrap cap=%02h expected $02", label, cap_lo[15*4]);
            fail++;
        end
        if (cap_lo[16*4] !== 8'h04) begin
            $display("FAIL [%s] unit16 wrapped-fetch cap=%02h expected $04 (read decoy/$00?)",
                     label, cap_lo[16*4]);
            fail++;
        end
        if (cap_lo[15*4] === 8'h02 && cap_lo[16*4] === 8'h04)
            $display("  [%s] OK (4K wrap fetch correct via real chain)", label);
    endtask

    initial begin
        $display("=== CMP_FETCH INTEGRATION TEST ===");
        m_mode = 4'h0; m_sub = 4'h0; m_lms = LMS; chbase_r = CHB;
        start = 1'b0; cap_reset = 1'b0;
        pmbase_r = 8'h0; dmactl_r = 8'h0; gractl_r = 8'h0; sizem_r = 8'h0; vdelay_r = 8'h0;
        grafm_r = 8'h0; hitclr_r = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            hposp_r[i] = 8'h0; hposm_r[i] = 8'h0; sizep_r[i] = 2'h0; grafp_r[i] = 8'h0;
        end
        clear_mem;
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== SNOOP mode (HW default: mode_snoop locked -> dma_mode_q=0) ==
        dma_mode = 1'b0;
        $display("--- SNOOP path (bram_shim) ---");
        run_pmdma("snoop/pmdma");
        run_wrap ("snoop/wrap");

        // ===== DMA mode (arbiter + dma_master) ============================
        dma_mode = 1'b1;
        @(posedge clk);
        $display("--- DMA path (arbiter + dma_master) ---");
        run_pmdma("dma/pmdma");
        run_wrap ("dma/wrap");

        // ===== CONTENTION: port-A / p0 active during the compose ==========
        // If the higher-priority requester (bram_shim port A / arbiter p0)
        // collides with the compositor's one-cycle request pulse, the pulse
        // is silently dropped and the compositor STALLS (→ stale $00).
        $display("--- CONTENTION: port-A / p0 hammered during compose ---");
        contend_en = 1'b1;
        dma_mode   = 1'b0;
        @(posedge clk);
        run_pmdma("snoop/contend");
        dma_mode   = 1'b1;
        @(posedge clk);
        run_pmdma("dma/contend");
        contend_en = 1'b0;

        if (fail == 0) begin
            $display("*** CMP_FETCH OK ***");
            $finish;
        end else begin
            $display("*** CMP_FETCH FAIL *** %0d failures", fail);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_cmp_fetch watchdog (a fetch STALLED — compositor never completed)");
        $fatal(1);
    end

endmodule

`default_nettype wire
