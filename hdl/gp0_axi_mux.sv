// gp0_axi_mux.sv — two PL masters, one S_AXI_GP0 port.
//
// screen_bank (m0) and math_cop (m1) share the 32-bit AXI3 slave port GP0.
// Both issue ONE burst at a time (8x64-bit = 16x32-bit beats) with idle gaps
// between bursts, so a transaction-granular arbiter is lossless: grant is
// taken on a valid, held while anything is in flight, and released on the
// first fully-idle cycle.  Because the grant only releases with zero
// outstanding transactions, responses can never interleave and the tied-off
// AXI IDs stay unambiguous.
//
// m1 (math_cop) outranks m0 (screen_bank): the math flush is the hot-loop
// doorbell latency, while a screen chunk copy is latency-tolerant by design
// (the CPU polls $D5C5.ready and the RGBA triple buffer hides the flip).
// Worst-case added math latency = one in-flight screen burst (~16 beats),
// not a whole 8 KB chunk copy — screen_bank re-arbitrates every burst.
//
// Same clock (clk_sys), no CDC.  An ungranted master sees all its readys/
// valids low, which both internal FSMs already tolerate (they hold VALID
// until READY per AXI).

`default_nettype none

module gp0_axi_mux (
    input  wire        clk,
    input  wire        rst,

    // ---- m0: screen_bank ---------------------------------------------------
    input  wire [31:0] m0_araddr,
    input  wire [3:0]  m0_arlen,
    input  wire [2:0]  m0_arsize,
    input  wire [1:0]  m0_arburst,
    input  wire        m0_arvalid,
    output wire        m0_arready,
    output wire [31:0] m0_rdata,
    output wire        m0_rvalid,
    output wire        m0_rlast,
    input  wire        m0_rready,
    input  wire [31:0] m0_awaddr,
    input  wire [3:0]  m0_awlen,
    input  wire [2:0]  m0_awsize,
    input  wire [1:0]  m0_awburst,
    input  wire        m0_awvalid,
    output wire        m0_awready,
    input  wire [31:0] m0_wdata,
    input  wire [3:0]  m0_wstrb,
    input  wire        m0_wlast,
    input  wire        m0_wvalid,
    output wire        m0_wready,
    output wire        m0_bvalid,
    input  wire        m0_bready,

    // ---- m1: math_cop --------------------------------------------------------
    input  wire [31:0] m1_araddr,
    input  wire [3:0]  m1_arlen,
    input  wire [2:0]  m1_arsize,
    input  wire [1:0]  m1_arburst,
    input  wire        m1_arvalid,
    output wire        m1_arready,
    output wire [31:0] m1_rdata,
    output wire        m1_rvalid,
    output wire        m1_rlast,
    input  wire        m1_rready,
    input  wire [31:0] m1_awaddr,
    input  wire [3:0]  m1_awlen,
    input  wire [2:0]  m1_awsize,
    input  wire [1:0]  m1_awburst,
    input  wire        m1_awvalid,
    output wire        m1_awready,
    input  wire [31:0] m1_wdata,
    input  wire [3:0]  m1_wstrb,
    input  wire        m1_wlast,
    input  wire        m1_wvalid,
    output wire        m1_wready,
    output wire        m1_bvalid,
    input  wire        m1_bready,

    // ---- s: the S_AXI_GP0 port (gp0m_* in fpga_xt_top) ----------------------
    output wire [31:0] s_araddr,
    output wire [3:0]  s_arlen,
    output wire [2:0]  s_arsize,
    output wire [1:0]  s_arburst,
    output wire        s_arvalid,
    input  wire        s_arready,
    input  wire [31:0] s_rdata,
    input  wire        s_rvalid,
    input  wire        s_rlast,
    output wire        s_rready,
    output wire [31:0] s_awaddr,
    output wire [3:0]  s_awlen,
    output wire [2:0]  s_awsize,
    output wire [1:0]  s_awburst,
    output wire        s_awvalid,
    input  wire        s_awready,
    output wire [31:0] s_wdata,
    output wire [3:0]  s_wstrb,
    output wire        s_wlast,
    output wire        s_wvalid,
    input  wire        s_wready,
    input  wire        s_bvalid,
    output wire        s_bready
);

    typedef enum logic [1:0] { G_IDLE, G_M0, G_M1 } grant_t;
    grant_t g;

    wire m0_req = m0_arvalid | m0_awvalid;
    wire m1_req = m1_arvalid | m1_awvalid;

    // Outstanding-transaction trackers (single outstanding by construction:
    // the grant holder issues one burst and waits for its completion).
    logic rd_busy, wr_busy;
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_busy <= 1'b0;
            wr_busy <= 1'b0;
        end else begin
            if (s_arvalid && s_arready)          rd_busy <= 1'b1;
            else if (s_rvalid && s_rready && s_rlast) rd_busy <= 1'b0;
            if (s_awvalid && s_awready)          wr_busy <= 1'b1;
            else if (s_bvalid && s_bready)       wr_busy <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) g <= G_IDLE;
        else begin
            unique case (g)
                G_IDLE: if      (m1_req) g <= G_M1;   // math outranks screen
                        else if (m0_req) g <= G_M0;
                G_M0:   if (!m0_req && !rd_busy && !wr_busy) g <= G_IDLE;
                G_M1:   if (!m1_req && !rd_busy && !wr_busy) g <= G_IDLE;
                default: g <= G_IDLE;
            endcase
        end
    end

    wire g0 = (g == G_M0);
    wire g1 = (g == G_M1);

    // ---- channel routing (combinational; ungranted master sees 0s) ---------
    assign s_araddr  = g1 ? m1_araddr  : m0_araddr;
    assign s_arlen   = g1 ? m1_arlen   : m0_arlen;
    assign s_arsize  = g1 ? m1_arsize  : m0_arsize;
    assign s_arburst = g1 ? m1_arburst : m0_arburst;
    assign s_arvalid = (g0 & m0_arvalid) | (g1 & m1_arvalid);
    assign m0_arready = g0 & s_arready;
    assign m1_arready = g1 & s_arready;

    assign m0_rdata  = s_rdata;
    assign m1_rdata  = s_rdata;
    assign m0_rvalid = g0 & s_rvalid;
    assign m1_rvalid = g1 & s_rvalid;
    assign m0_rlast  = s_rlast;
    assign m1_rlast  = s_rlast;
    assign s_rready  = (g0 & m0_rready) | (g1 & m1_rready);

    assign s_awaddr  = g1 ? m1_awaddr  : m0_awaddr;
    assign s_awlen   = g1 ? m1_awlen   : m0_awlen;
    assign s_awsize  = g1 ? m1_awsize  : m0_awsize;
    assign s_awburst = g1 ? m1_awburst : m0_awburst;
    assign s_awvalid = (g0 & m0_awvalid) | (g1 & m1_awvalid);
    assign m0_awready = g0 & s_awready;
    assign m1_awready = g1 & s_awready;

    assign s_wdata   = g1 ? m1_wdata : m0_wdata;
    assign s_wstrb   = g1 ? m1_wstrb : m0_wstrb;
    assign s_wlast   = g1 ? m1_wlast : m0_wlast;
    assign s_wvalid  = (g0 & m0_wvalid) | (g1 & m1_wvalid);
    assign m0_wready = g0 & s_wready;
    assign m1_wready = g1 & s_wready;

    assign m0_bvalid = g0 & s_bvalid;
    assign m1_bvalid = g1 & s_bvalid;
    assign s_bready  = (g0 & m0_bready) | (g1 & m1_bready);

endmodule

`default_nettype wire
