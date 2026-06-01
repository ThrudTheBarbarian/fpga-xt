// hp_read_probe.sv — dual-mode auto-running AXI read master for HW bring-up.
//
// Isolated PL->DDR read test on its own HP port (HP2).  Built to localize why
// plane_fetch's reads hang (AR accepted, no rvalid) on HP0/HP3 while the
// writeback's WRITES to the same address work, and while an earlier
// SINGLE-beat probe read here succeeds.
//
// HP0 (plane_fetch0, read-only) and HP2 (this probe, read-only) are configured
// identically, yet HP0 hangs and HP2 (single-beat) works — so the difference is
// the master logic, and the only AR-parameter that differs is the BURST LENGTH
// (plane_fetch uses 8-beat bursts; the probe used 1).  This version alternates
// 1-beat and 8-beat reads of a fixed address with SEPARATE counters to settle
// it in one build:
//   succ1 climbs, succ8 frozen / to8 climbs  => MULTI-BEAT reads are the bug
//                                               (single-beat works) -> fix is
//                                               in plane_fetch's burst handling
//   both succ1 and succ8 climb                => burst length is NOT it; the
//                                               bug is elsewhere in plane_fetch
//                                               (line_start CDC / ping-pong /
//                                               continuous re-arm)
// Counters are 8-bit (watch moving-vs-frozen, like prod/rdp).  last_rdata/rresp
// capture the most recent response for validation.

`default_nettype none

module hp_read_probe #(
    parameter [31:0] TEST_ADDR = 32'h3100_0000,
    parameter int    TIMEOUT   = 4096            // cycles to wait per phase
) (
    input  wire        clk,                       // clk_sys
    input  wire        rst,

    // ---- AXI4 read master -> HP2 --------------------------------------
    output reg  [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready,

    // ---- Result (clk domain) — surfaced over GP0 ----------------------
    output reg  [7:0]  succ1,    // single-beat (arlen=0) successes
    output reg  [7:0]  to1,      // single-beat timeouts
    output reg  [7:0]  succ8,    // 8-beat (arlen=7) successes
    output reg  [7:0]  to8,      // 8-beat timeouts
    output reg  [1:0]  last_rresp,
    output reg  [31:0] last_rdata
);
    // mode 0 = single beat (arlen 0), mode 1 = 8-beat burst (arlen 7).
    reg          mode;
    assign m_axi_arlen   = mode ? 8'd7 : 8'd0;
    assign m_axi_arsize  = 3'b011;     // 8 bytes / 64-bit
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_rready  = 1'b1;       // always ready to take data

    typedef enum logic [1:0] { S_IDLE, S_AR, S_R } st_t;
    st_t state;
    logic [15:0] wait_cnt;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= S_IDLE;
            mode          <= 1'b0;
            m_axi_araddr  <= 32'd0;
            m_axi_arvalid <= 1'b0;
            wait_cnt      <= 16'd0;
            succ1         <= 8'd0;  to1 <= 8'd0;
            succ8         <= 8'd0;  to8 <= 8'd0;
            last_rresp    <= 2'd0;
            last_rdata    <= 32'd0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    m_axi_araddr  <= TEST_ADDR;
                    m_axi_arvalid <= 1'b1;
                    wait_cnt      <= 16'd0;
                    state         <= S_AR;
                end
                S_AR: begin
                    wait_cnt <= wait_cnt + 16'd1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        wait_cnt      <= 16'd0;
                        state         <= S_R;
                    end else if (wait_cnt >= TIMEOUT[15:0]) begin
                        m_axi_arvalid <= 1'b0;
                        if (mode) to8 <= to8 + 8'd1; else to1 <= to1 + 8'd1;
                        mode  <= ~mode;
                        state <= S_IDLE;
                    end
                end
                S_R: begin
                    wait_cnt <= wait_cnt + 16'd1;
                    if (m_axi_rvalid) begin
                        last_rresp <= m_axi_rresp;
                        last_rdata <= m_axi_rdata[31:0];
                        wait_cnt   <= 16'd0;            // progress: reset watchdog
                        if (m_axi_rlast) begin          // burst complete
                            if (mode) succ8 <= succ8 + 8'd1; else succ1 <= succ1 + 8'd1;
                            mode  <= ~mode;
                            state <= S_IDLE;
                        end
                    end else if (wait_cnt >= TIMEOUT[15:0]) begin
                        if (mode) to8 <= to8 + 8'd1; else to1 <= to1 + 8'd1;
                        mode  <= ~mode;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
