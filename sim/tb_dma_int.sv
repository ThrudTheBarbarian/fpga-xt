// tb_dma_int.sv — M16-int verification.
//
// Wires dl_parser + compositor + 2 × mem_read_mux + dma_arbiter +
// dma_master + cpu_shadow + a DMA-side memory mock, then runs the
// same small DL (1 mode-F line) through both cpu_shadow (snoop
// mode) and dma_master (DMA mode) back-to-back. Captures
// rp_bus_mock.fb after each, asserts identical byte-for-byte
// output — proving dl_parser + compositor are source-agnostic.
//
// Bypasses antic_top's periodic kick to keep sim time short and
// dl_start / cmp_start under the testbench's control.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_dma_int;

    // ---- Clocks --------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;             // 100 MHz fabric

    logic rst = 1'b1;

    // phi2 generator for dma_master.
    localparam int CLOCK_DIV = 6;
    logic [3:0] phi2_div = 4'd0;
    logic       phi2     = 1'b0;
    always @(posedge clk) begin
        if (phi2_div == (CLOCK_DIV - 1)) begin
            phi2_div <= 4'd0;
            phi2     <= ~phi2;
        end else begin
            phi2_div <= phi2_div + 4'd1;
        end
    end

    // ---- Memory: cpu_shadow (BRAM) + atari_mem mock --------------------
    // Both pre-loaded with identical contents, so snoop and DMA paths
    // produce the same rp_tx output stream.
    logic        bram_we    = 1'b0;
    logic [15:0] bram_waddr = 16'h0;
    logic [7:0]  bram_wdata = 8'h0;

    wire  [15:0] sh_a_raddr, sh_b_raddr;
    wire  [7:0]  sh_a_rdata, sh_b_rdata;

    byte_ram_dp #(.ADDR_W(16), .DEPTH(65536)) u_cpu_shadow (
        .clk     (clk),
        .we      (bram_we),
        .waddr   (bram_waddr),
        .wdata   (bram_wdata),
        .raddr_a (sh_a_raddr),
        .rdata_a (sh_a_rdata),
        .raddr_b (sh_b_raddr),
        .rdata_b (sh_b_rdata));

    // Atari-bus memory mock — a flat array combinationally driven onto
    // bus_data_in when dma_oe is asserted.
    logic [7:0] atari_mem [0:65535];
    wire  [15:0] dma_addr_o;
    wire         dma_rw_o;
    wire         dma_oe;
    wire         halt_n;
    wire  [7:0]  bus_data_i = dma_oe ? atari_mem[dma_addr_o] : 8'h00;

    // ---- dma_master + dma_arbiter --------------------------------------
    wire        arb_dma_req;
    wire [15:0] arb_dma_addr;
    wire        arb_dma_ack;
    wire        arb_dma_dvalid;
    wire  [7:0] arb_dma_rdata;
    wire        dma_busy_w;

    dma_master u_dma (
        .clk(clk), .rst(rst), .phi2(phi2),
        .req(arb_dma_req), .req_addr(arb_dma_addr),
        .ack(arb_dma_ack), .data_valid(arb_dma_dvalid),
        .req_data(arb_dma_rdata), .busy(dma_busy_w),
        .halt_n(halt_n), .addr_o(dma_addr_o),
        .rw_o(dma_rw_o), .bus_oe(dma_oe),
        .data_i(bus_data_i));

    // ---- Per-consumer mem_read_mux + arbiter ---------------------------
    logic        dma_mode = 1'b0;

    wire [15:0] dl_raddr,  cmp_raddr;
    wire [7:0]  dl_rdata,  cmp_rdata;
    wire        dl_req,    cmp_req;
    wire        dl_ready,  cmp_ready;

    wire        dl_dma_req,    cmp_dma_req;
    wire [15:0] dl_dma_addr,   cmp_dma_addr;
    wire        dl_dma_ack,    cmp_dma_ack;
    wire        dl_dma_dvalid, cmp_dma_dvalid;
    wire  [7:0] dl_dma_rdata,  cmp_dma_rdata;

    dma_arbiter u_dma_arb (
        .clk(clk), .rst(rst),
        .p0_req(dl_dma_req),   .p0_addr(dl_dma_addr),
        .p0_ack(dl_dma_ack),   .p0_data_valid(dl_dma_dvalid),
        .p0_rdata(dl_dma_rdata),
        .p1_req(cmp_dma_req),  .p1_addr(cmp_dma_addr),
        .p1_ack(cmp_dma_ack),  .p1_data_valid(cmp_dma_dvalid),
        .p1_rdata(cmp_dma_rdata),
        .dma_req(arb_dma_req), .dma_addr(arb_dma_addr),
        .dma_ack(arb_dma_ack), .dma_data_valid(arb_dma_dvalid),
        .dma_rdata(arb_dma_rdata), .dma_busy(dma_busy_w));

    // BRAM-backed shadow has no handshake — sh_ready=1, sh_req discarded.
    wire dl_sh_req_w, cmp_sh_req_w;

    mem_read_mux #(.ADDR_W(16)) u_mux_dl (
        .clk(clk), .rst(rst), .dma_mode(dma_mode),
        .caller_raddr(dl_raddr), .caller_req(dl_req),
        .caller_rdata(dl_rdata), .caller_ready(dl_ready),
        .sh_raddr(sh_a_raddr), .sh_req(dl_sh_req_w),
        .sh_rdata(sh_a_rdata), .sh_ready(1'b1),
        .dma_req(dl_dma_req), .dma_addr(dl_dma_addr),
        .dma_ack(dl_dma_ack), .dma_data_valid(dl_dma_dvalid),
        .dma_rdata(dl_dma_rdata), .dma_busy(dma_busy_w));

    mem_read_mux #(.ADDR_W(16)) u_mux_cmp (
        .clk(clk), .rst(rst), .dma_mode(dma_mode),
        .caller_raddr(cmp_raddr), .caller_req(cmp_req),
        .caller_rdata(cmp_rdata), .caller_ready(cmp_ready),
        .sh_raddr(sh_b_raddr), .sh_req(cmp_sh_req_w),
        .sh_rdata(sh_b_rdata), .sh_ready(1'b1),
        .dma_req(cmp_dma_req), .dma_addr(cmp_dma_addr),
        .dma_ack(cmp_dma_ack), .dma_data_valid(cmp_dma_dvalid),
        .dma_rdata(cmp_dma_rdata), .dma_busy(dma_busy_w));

    // ---- dl_parser ------------------------------------------------------
    logic        dl_start = 1'b0;
    logic [7:0]  dlistl   = 8'h00;
    logic [7:0]  dlisth   = 8'hD0;
    wire  [7:0]  meta_row_w;
    wire  [3:0]  dl_meta_mode;
    wire         dl_meta_dli;
    wire  [15:0] dl_meta_lms;
    wire  [3:0]  dl_meta_sub;
    wire         dl_meta_hscrol_en, dl_meta_vscrol_en;
    wire         dl_done;
    wire  [31:0] dl_count;

    dl_parser u_dl (
        .clk(clk), .rst(rst), .start_parse(dl_start),
        .dlistl(dlistl), .dlisth(dlisth),
        .vscrol(4'h0),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata),
        .mem_req(dl_req), .mem_ready(dl_ready),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_dli(dl_meta_dli),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .meta_lms_addr(dl_meta_lms), .meta_sub_row(dl_meta_sub),
        .dli_row(8'h00), .dli_at(),
        .parse_done(dl_done), .parse_count(dl_count));

    // ---- compositor + rp_tx + rp_bus_mock ------------------------------
    logic        cmp_start = 1'b0;
    wire  [1:0]  cmp_cmd_tag;
    wire  [23:0] cmp_cmd_addr;
    wire  [23:0] cmp_cmd_data;
    wire         cmp_cmd_valid;
    wire         cmp_cmd_ready;
    wire         cmp_done;
    wire  [31:0] cmp_count;

    compositor u_cmp (
        .clk(clk), .rst(rst), .start_compose(cmp_start),
        .meta_row(meta_row_w),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .chbase(8'h00), .chactl(8'h00),
        .pmbase(8'h00), .dmactl(8'h00), .gractl(8'h00),
        .hposp0(8'h0), .hposp1(8'h0), .hposp2(8'h0), .hposp3(8'h0),
        .hposm0(8'h0), .hposm1(8'h0), .hposm2(8'h0), .hposm3(8'h0),
        .sizep0(2'h0), .sizep1(2'h0), .sizep2(2'h0), .sizep3(2'h0),
        .sizem(8'h0), .vdelay(8'h0),
        .hscrol(4'h0), .vscrol(4'h0),
        .prior(8'h00),
        .mpf_q(), .ppf_q(), .mpl_q(), .ppl_q(), .hitclr(1'b0),
        .mem_raddr(cmp_raddr), .mem_rdata(cmp_rdata),
        .mem_req(cmp_req), .mem_ready(cmp_ready),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .compose_done(cmp_done), .compose_count(cmp_count));

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [31:0] tx_set_misalign_count;

    rp_tx u_tx (
        .clk(clk), .rst(rst),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .tx_set_misalign_count(tx_set_misalign_count));

    localparam int FB_BYTES = 4 * 1024;
    wire  [15:0] mock_rsp;
    wire         mock_rsp_valid;
    wire  [31:0] mock_fetch_count, mock_set_count, mock_draw_count;
    wire  [31:0] mock_bad_tag_count, mock_set_misalign_count;

    rp_bus_mock #(.FB_BYTES(FB_BYTES), .FETCH_LATENCY(4)) u_mock (
        .clk(clk), .rst(rst),
        .bus_tag(bus_tag), .bus_payload(bus_payload),
        .rsp_payload(mock_rsp), .rsp_valid(mock_rsp_valid),
        .mock_fetch_count(mock_fetch_count), .mock_set_count(mock_set_count),
        .mock_draw_count(mock_draw_count),
        .mock_bad_tag_count(mock_bad_tag_count),
        .mock_set_misalign_count(mock_set_misalign_count));

    // ---- Helpers --------------------------------------------------------
    task automatic load_byte(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk);
        bram_waddr <= addr;
        bram_wdata <= data;
        bram_we    <= 1'b1;
        atari_mem[addr] = data;
        @(posedge clk);
        @(negedge clk);
        bram_we <= 1'b0;
    endtask

    task automatic clear_fb;
        integer i;
        for (i = 0; i < FB_BYTES; i = i + 1) u_mock.fb[i] = 8'h00;
    endtask

    task automatic run_frame;
        @(posedge clk);
        dl_start <= 1'b1;
        @(posedge clk);
        dl_start <= 1'b0;
        wait (dl_done);
        @(posedge clk);
        cmp_start <= 1'b1;
        @(posedge clk);
        cmp_start <= 1'b0;
        wait (cmp_done);
        repeat (32) @(posedge clk);
    endtask

    // ---- Capture buffers ------------------------------------------------
    logic [7:0] fb_snoop [0:FB_BYTES-1];
    logic [7:0] fb_dma   [0:FB_BYTES-1];

    int fail_count = 0;

    initial begin
        $display("[dma_int] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- Build a small DL: 1 mode-F line, JVB ----------------------
        // PF source: alternating bytes so the compositor produces a
        // recognisable pattern.
        begin : load_pf
            integer i;
            for (i = 0; i < 40; i = i + 1)
                load_byte(16'h3000 + 16'(i), (i & 1) ? 8'hAA : 8'h55);
        end
        load_byte(16'hD000, 8'h4F);     // mode F + LMS
        load_byte(16'hD001, 8'h00);
        load_byte(16'hD002, 8'h30);
        load_byte(16'hD003, 8'h41);     // JVB
        load_byte(16'hD004, 8'h00);
        load_byte(16'hD005, 8'hD0);

        // ---- Run snoop mode --------------------------------------------
        dma_mode = 1'b0;
        clear_fb;
        run_frame;
        $display("[dma_int/snoop] sets=%0d done; capturing fb",
                 mock_set_count);
        begin : capture_snoop
            integer i;
            for (i = 0; i < FB_BYTES; i = i + 1)
                fb_snoop[i] = u_mock.fb[i];
        end

        // ---- Run DMA mode ---------------------------------------------
        dma_mode = 1'b1;
        clear_fb;
        run_frame;
        $display("[dma_int/dma]   sets=%0d done; capturing fb",
                 mock_set_count);
        begin : capture_dma
            integer i;
            for (i = 0; i < FB_BYTES; i = i + 1)
                fb_dma[i] = u_mock.fb[i];
        end

        // ---- Compare ---------------------------------------------------
        begin : compare
            integer i, mismatches, first_mismatch;
            mismatches = 0;
            first_mismatch = -1;
            for (i = 0; i < FB_BYTES; i = i + 1) begin
                if (fb_snoop[i] !== fb_dma[i]) begin
                    if (first_mismatch < 0) first_mismatch = i;
                    if (mismatches < 8)
                        $display("[diff] FAIL i=%0d snoop=$%02h dma=$%02h",
                                 i, fb_snoop[i], fb_dma[i]);
                    mismatches++;
                end
            end
            if (mismatches != 0) begin
                $display("[dma_int] %0d mismatches; first at i=%0d",
                         mismatches, first_mismatch);
                fail_count++;
            end else begin
                $display("[dma_int] FB byte-for-byte identical across both modes");
            end
        end

        if (fail_count == 0) begin
            $display("*** DMA_INT OK *** snoop and DMA modes produce identical output");
            $finish;
        end else begin
            $display("*** DMA_INT FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;       // 50 ms watchdog
        $display("FAIL: tb_dma_int watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
