// hyperram_shim.sv — Zynq-compatible stub replacing the Efinix HyperRAM
// Controller IP wrapper.
//
// Provides the same dual-read-port + write-port interface as the original
// but backs it with on-chip BRAM instead of off-chip HyperRAM.  This is
// the dma_mode=0 (snoop/BRAM) path for ANTIC reads.
//
// On the original N6 path, this module wrapped the Efinix HyperRAM
// Controller IP and had multi-cycle latency.  On Zynq, reads are 1-cycle
// (BRAM) — no handshake delay.  The ready/valid protocol is preserved
// so antic_top's mem_read_mux consumers work unchanged.
//
// BRAM allocation: 64 KB (16 × RAMB36E1).  That's a full copy of the
// Atari main memory.  Writes arrive via bus_snoop.we_screen (the chiplet-
// extension register write path that mirrors CPU writes to the backing
// store).  Reads go to dl_parser and compositor.
//
// HyperRAM PHY ports are tied off — they dangle from antic_top's port
// list but drive nothing on Zynq.

`default_nettype none

module hyperram_shim #(
    parameter int ADDR_W  = 16,
    parameter int LATENCY = 1          // 1-cycle BRAM latency (ignored on Zynq)
) (
    input  wire                clk,
    input  wire                rst,

    // Write port (from bus_snoop.we_screen).
    input  wire                we,
    input  wire  [ADDR_W-1:0]  waddr,
    input  wire  [7:0]         wdata,
    output wire                wready,

    // Read port A (dl_parser side).
    input  wire                req_a,
    input  wire  [ADDR_W-1:0]  raddr_a,
    output logic [7:0]         rdata_a,
    output logic               rd_valid_a,
    output logic               ready_a,

    // Read port B (compositor side).
    input  wire                req_b,
    input  wire  [ADDR_W-1:0]  raddr_b,
    output logic [7:0]         rdata_b,
    output logic               rd_valid_b,
    output logic               ready_b,

    // ---- HyperRAM PHY-side ports (tied off on Zynq) -------------------
    // Connected by antic_top to top-level pads.  On Zynq these are
    // unconnected (no HyperRAM on the Z-Turn SOM).  Vivado will
    // optimise away any logic driven only by these dangling wires.
    input  wire                ram_clk,
    input  wire                ram_clk_cal,
    output wire                hbc_cal_pass,
    output wire                hbc_ck_n_LO,
    output wire                hbc_ck_n_HI,
    output wire                hbc_ck_p_LO,
    output wire                hbc_ck_p_HI,
    output wire                hbc_cs_n,
    output wire                hbc_rst_n,
    output wire [7:0]          hbc_dq_OE,
    input  wire  [7:0]         hbc_dq_IN_LO,
    input  wire  [7:0]         hbc_dq_IN_HI,
    output wire [7:0]          hbc_dq_OUT_LO,
    output wire [7:0]          hbc_dq_OUT_HI,
    output wire                hbc_rwds_OE,
    input  wire                hbc_rwds_IN_LO,
    input  wire                hbc_rwds_IN_HI,
    output wire                hbc_rwds_OUT_LO,
    output wire                hbc_rwds_OUT_HI,
    output wire [4:0]          hbc_cal_SHIFT_SEL,
    output wire [2:0]          hbc_cal_SHIFT,
    output wire                hbc_cal_SHIFT_ENA,
    output wire [26:0]         hbc_cal_debug_info
);

    // ---- Tie off HyperRAM PHY outputs ---------------------------------
    assign hbc_cal_pass       = 1'b0;
    assign hbc_ck_n_LO        = 1'b0;
    assign hbc_ck_n_HI        = 1'b0;
    assign hbc_ck_p_LO        = 1'b0;
    assign hbc_ck_p_HI        = 1'b0;
    assign hbc_cs_n           = 1'b1;
    assign hbc_rst_n          = 1'b0;
    assign hbc_dq_OE          = 8'h00;
    assign hbc_dq_OUT_LO      = 8'h00;
    assign hbc_dq_OUT_HI      = 8'h00;
    assign hbc_rwds_OE        = 1'b0;
    assign hbc_rwds_OUT_LO    = 1'b0;
    assign hbc_rwds_OUT_HI    = 1'b0;
    assign hbc_cal_SHIFT_SEL  = 5'h00;
    assign hbc_cal_SHIFT      = 3'h0;
    assign hbc_cal_SHIFT_ENA  = 1'b0;
    assign hbc_cal_debug_info = 27'h0;

    // ---- Backing BRAM (64 KB) ------------------------------------------
    logic [7:0] mem [0:(1 << ADDR_W) - 1];

    // Always ready for writes.
    assign wready = 1'b1;

    // Write port.
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    // Read port A — registered, 1-cycle latency.
    logic [7:0] rdata_a_q;
    logic       rd_valid_a_q;
    logic       a_served_q;        // tracks whether we handled req_a last cycle

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdata_a_q   <= 8'h00;
            rd_valid_a_q <= 1'b0;
            a_served_q  <= 1'b0;
        end else begin
            rd_valid_a_q <= 1'b0;
            if (req_a) begin
                rdata_a_q   <= mem[raddr_a];
                rd_valid_a_q <= 1'b1;
                a_served_q  <= 1'b1;
            end else begin
                a_served_q  <= 1'b0;
            end
        end
    end

    assign rdata_a   = rdata_a_q;
    assign rd_valid_a = rd_valid_a_q;
    assign ready_a   = 1'b1;        // always ready (1-cycle latency)

    // Read port B — registered, 1-cycle latency.
    logic [7:0] rdata_b_q;
    logic       rd_valid_b_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdata_b_q   <= 8'h00;
            rd_valid_b_q <= 1'b0;
        end else begin
            rd_valid_b_q <= 1'b0;
            if (req_b) begin
                rdata_b_q   <= mem[raddr_b];
                rd_valid_b_q <= 1'b1;
            end
        end
    end

    assign rdata_b   = rdata_b_q;
    assign rd_valid_b = rd_valid_b_q;
    assign ready_b   = 1'b1;        // always ready

endmodule

`default_nettype wire
