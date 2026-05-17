// zynq_ps_hp_stub.sv — AXI3 slave responder stub for Zynq PS HP ports.
//
// Drop-in internal target for fb_scanout (HP0) and xt_blitter (HP1) during
// OOC synthesis.  Implements simple always-ready AXI3 responders so the
// PL-side AXI master logic is preserved (not optimised away).
//
// For bitstream builds, the real ps_bd_wrapper (from BD generation) replaces
// this module as the top-level — the PL masters connect through SmartConnect
// IPs to the PS HP slaves directly.
//
// AXI3 protocol:
//   - arlen/awlen are 4-bit (max 16 beats per burst), vs AXI4's 8-bit
//   - wid is present (separate from awid), vs AXI4 where wid is optional
//   - lock is 2-bit, vs AXI4's 1-bit
//   - cache, prot, qos widths match AXI4
//
// This stub ignores all these extra signals and simply accepts every
// transaction with zero-latency handshake + 1-cycle pipeline delay on
// responses.

`default_nettype none

module zynq_ps_hp_stub (
    input  wire        clk,

    // ---- HP0 (full duplex read/write) -------------------------------------
    // Read address
    input  wire [31:0] s_axi_hp0_araddr,
    input  wire [1:0]  s_axi_hp0_arburst,
    input  wire [3:0]  s_axi_hp0_arcache,
    input  wire [5:0]  s_axi_hp0_arid,
    input  wire [3:0]  s_axi_hp0_arlen,
    input  wire [1:0]  s_axi_hp0_arlock,
    input  wire [2:0]  s_axi_hp0_arprot,
    input  wire [3:0]  s_axi_hp0_arqos,
    output reg         s_axi_hp0_arready,
    input  wire [2:0]  s_axi_hp0_arsize,
    input  wire        s_axi_hp0_arvalid,
    // Write address
    input  wire [31:0] s_axi_hp0_awaddr,
    input  wire [1:0]  s_axi_hp0_awburst,
    input  wire [3:0]  s_axi_hp0_awcache,
    input  wire [5:0]  s_axi_hp0_awid,
    input  wire [3:0]  s_axi_hp0_awlen,
    input  wire [1:0]  s_axi_hp0_awlock,
    input  wire [2:0]  s_axi_hp0_awprot,
    input  wire [3:0]  s_axi_hp0_awqos,
    output reg         s_axi_hp0_awready,
    input  wire [2:0]  s_axi_hp0_awsize,
    input  wire        s_axi_hp0_awvalid,
    // Write response
    output reg  [5:0]  s_axi_hp0_bid,
    input  wire        s_axi_hp0_bready,
    output reg  [1:0]  s_axi_hp0_bresp,
    output reg         s_axi_hp0_bvalid,
    // Read data
    output reg  [63:0] s_axi_hp0_rdata,
    output reg  [5:0]  s_axi_hp0_rid,
    output reg         s_axi_hp0_rlast,
    input  wire        s_axi_hp0_rready,
    output reg  [1:0]  s_axi_hp0_rresp,
    output reg         s_axi_hp0_rvalid,
    // Write data
    input  wire [63:0] s_axi_hp0_wdata,
    input  wire [5:0]  s_axi_hp0_wid,
    input  wire        s_axi_hp0_wlast,
    output reg         s_axi_hp0_wready,
    input  wire [7:0]  s_axi_hp0_wstrb,
    input  wire        s_axi_hp0_wvalid,

    // ---- HP1 (full duplex read/write) -------------------------------------
    input  wire [31:0] s_axi_hp1_araddr,
    input  wire [1:0]  s_axi_hp1_arburst,
    input  wire [3:0]  s_axi_hp1_arcache,
    input  wire [5:0]  s_axi_hp1_arid,
    input  wire [3:0]  s_axi_hp1_arlen,
    input  wire [1:0]  s_axi_hp1_arlock,
    input  wire [2:0]  s_axi_hp1_arprot,
    input  wire [3:0]  s_axi_hp1_arqos,
    output reg         s_axi_hp1_arready,
    input  wire [2:0]  s_axi_hp1_arsize,
    input  wire        s_axi_hp1_arvalid,
    // Write address
    input  wire [31:0] s_axi_hp1_awaddr,
    input  wire [1:0]  s_axi_hp1_awburst,
    input  wire [3:0]  s_axi_hp1_awcache,
    input  wire [5:0]  s_axi_hp1_awid,
    input  wire [3:0]  s_axi_hp1_awlen,
    input  wire [1:0]  s_axi_hp1_awlock,
    input  wire [2:0]  s_axi_hp1_awprot,
    input  wire [3:0]  s_axi_hp1_awqos,
    output reg         s_axi_hp1_awready,
    input  wire [2:0]  s_axi_hp1_awsize,
    input  wire        s_axi_hp1_awvalid,
    // Write response
    output reg  [5:0]  s_axi_hp1_bid,
    input  wire        s_axi_hp1_bready,
    output reg  [1:0]  s_axi_hp1_bresp,
    output reg         s_axi_hp1_bvalid,
    // Read data
    output reg  [63:0] s_axi_hp1_rdata,
    output reg  [5:0]  s_axi_hp1_rid,
    output reg         s_axi_hp1_rlast,
    input  wire        s_axi_hp1_rready,
    output reg  [1:0]  s_axi_hp1_rresp,
    output reg         s_axi_hp1_rvalid,
    // Write data
    input  wire [63:0] s_axi_hp1_wdata,
    input  wire [5:0]  s_axi_hp1_wid,
    input  wire        s_axi_hp1_wlast,
    output reg         s_axi_hp1_wready,
    input  wire [7:0]  s_axi_hp1_wstrb,
    input  wire        s_axi_hp1_wvalid
);

    // ====================================================================
    // Read channel responder — HP0
    // ====================================================================
    // Accept AR immediately when idle; assert rvalid/rlast on next cycle.
    // Single-beat response (ignores arlen burst count for stub purposes).
    // The real PS HP port handles full bursts; for OOC timing we just need
    // the handshake to complete.

    logic        hp0_rd_pending;

    always_ff @(posedge clk) begin
        if (~hp0_rd_pending && s_axi_hp0_arvalid) begin
            hp0_rd_pending <= 1'b1;
        end else if (hp0_rd_pending && s_axi_hp0_rready) begin
            hp0_rd_pending <= 1'b0;
        end
    end

    assign s_axi_hp0_arready = ~hp0_rd_pending;
    assign s_axi_hp0_rvalid  =  hp0_rd_pending;
    assign s_axi_hp0_rlast   =  hp0_rd_pending;
    // Return address-as-data so the tool cannot constant-propagate
    assign s_axi_hp0_rdata   = {32'd0, s_axi_hp0_araddr};
    assign s_axi_hp0_rid     = 6'd0;
    assign s_axi_hp0_rresp   = 2'b00;  // OKAY

    // ====================================================================
    // Read channel responder — HP1
    // ====================================================================

    logic        hp1_rd_pending;

    always_ff @(posedge clk) begin
        if (~hp1_rd_pending && s_axi_hp1_arvalid) begin
            hp1_rd_pending <= 1'b1;
        end else if (hp1_rd_pending && s_axi_hp1_rready) begin
            hp1_rd_pending <= 1'b0;
        end
    end

    assign s_axi_hp1_arready = ~hp1_rd_pending;
    assign s_axi_hp1_rvalid  =  hp1_rd_pending;
    assign s_axi_hp1_rlast   =  hp1_rd_pending;
    assign s_axi_hp1_rdata   = 64'd0;
    assign s_axi_hp1_rid     = 6'd0;
    assign s_axi_hp1_rresp   = 2'b00;  // OKAY

    // ====================================================================
    // Write channel responder — HP0
    // ====================================================================
    // Track AW/W arrival.  AXI allows AW and W in any order; assert bvalid
    // once both have been received and the previous B has been consumed.
    //
    // State encoding:
    //   00 — idle
    //   01 — AW seen, waiting for W
    //   10 — W seen, waiting for AW
    //   11 — both seen, bvalid asserted

    // INIT-value reset (Xilinx GSR at config sets FFs to declared INIT).
    // The stub has no async reset; the INIT keeps the state out of X on
    // power-up.  fsm_encoding="none" tells Vivado not to treat this as
    // an FSM (it's 2 bits of plain sequential logic) — clears Synth
    // 8-13157 ("FSM state register has no reset") which would otherwise
    // fire because Vivado's FSM analyser ignores the INIT value.
    (* fsm_encoding = "none" *) logic [1:0] hp0_wr_state = 2'b00;

    always_ff @(posedge clk) begin
        case (hp0_wr_state)
            2'b00: begin
                if (s_axi_hp0_awvalid) begin
                    hp0_wr_state <= s_axi_hp0_wvalid ? 2'b11 : 2'b01;
                end else if (s_axi_hp0_wvalid) begin
                    hp0_wr_state <= 2'b10;
                end
            end
            2'b01: begin
                if (s_axi_hp0_wvalid) hp0_wr_state <= 2'b11;
            end
            2'b10: begin
                if (s_axi_hp0_awvalid) hp0_wr_state <= 2'b11;
            end
            2'b11: begin
                if (s_axi_hp0_bready) hp0_wr_state <= 2'b00;
            end
        endcase
    end

    assign s_axi_hp0_awready = (hp0_wr_state == 2'b00) || (hp0_wr_state == 2'b10);
    assign s_axi_hp0_wready  = (hp0_wr_state == 2'b00) || (hp0_wr_state == 2'b01);
    assign s_axi_hp0_bvalid  = (hp0_wr_state == 2'b11);
    assign s_axi_hp0_bresp   = 2'b00;
    assign s_axi_hp0_bid     = 6'd0;

    // ====================================================================
    // Write channel responder — HP1
    // ====================================================================

    (* fsm_encoding = "none" *) logic [1:0] hp1_wr_state = 2'b00;

    always_ff @(posedge clk) begin
        case (hp1_wr_state)
            2'b00: begin
                if (s_axi_hp1_awvalid) begin
                    hp1_wr_state <= s_axi_hp1_wvalid ? 2'b11 : 2'b01;
                end else if (s_axi_hp1_wvalid) begin
                    hp1_wr_state <= 2'b10;
                end
            end
            2'b01: begin
                if (s_axi_hp1_wvalid) hp1_wr_state <= 2'b11;
            end
            2'b10: begin
                if (s_axi_hp1_awvalid) hp1_wr_state <= 2'b11;
            end
            2'b11: begin
                if (s_axi_hp1_bready) hp1_wr_state <= 2'b00;
            end
        endcase
    end

    assign s_axi_hp1_awready = (hp1_wr_state == 2'b00) || (hp1_wr_state == 2'b10);
    assign s_axi_hp1_wready  = (hp1_wr_state == 2'b00) || (hp1_wr_state == 2'b01);
    assign s_axi_hp1_bvalid  = (hp1_wr_state == 2'b11);
    assign s_axi_hp1_bresp   = 2'b00;
    assign s_axi_hp1_bid     = 6'd0;

endmodule

`default_nettype wire