// hyperram_phy.sv — synth wrapper around the Efinix HyperRAM Controller IP.
//
// Bridges the byte-level cmd/rd_valid protocol that hyperram_shim was built
// against (and that hyperram_mock implements for sim) to the IP's 64-bit
// native interface.
//
// One IP transaction per byte access — no prefetch / coalescing yet.
// Burst length is fixed at 4 (= 4 × 16 bits = 64 bits = 1 user word for
// x8 HyperRAM + 64-bit native data width). That gives 8 bytes per
// transaction; we mux the requested byte for reads, and drive
// native_wr_datamask to write only the requested byte (HyperRAM honours
// the mask via RWDS during writes — no read-modify-write needed).
//
// At ~150 MHz fabric clock, ~14 cycles per byte transaction → ~10 MB/s
// raw throughput. The 6502 requires ~1.79 MB/s peak, so ~5× headroom
// even with no coalescing. Coalescing sequential bytes (cart-bank loads,
// scanline prefetch) is a future optimisation for M17.
//
// PHY-side ports (hbc_*, ram_clk, ram_clk_cal) are exposed to top —
// antic_top wires them to the FPGA's HyperRAM I/O pins via the
// generated `.peri.xml` constraints.
//
// dyn_pll_phase_* are tied off (no runtime PLL phase tweaking; we rely
// on PLL Auto Calibration to find the right tap at power-up).

`default_nettype none

module hyperram_phy #(
    // Byte-address width on the user side. Default 24 = 16 MB = 128 Mb,
    // matching the configured S70KS1283 part.
    parameter int ADDR_W = 24,
    // LATENCY is meaningful only in the sim mock (hyperram_mock.sv);
    // the real IP has fixed internal latency (7 clocks) configured at
    // IP-gen time. Accepted here so hyperram_shim can pass the same
    // #(.LATENCY(...)) override unchanged in both builds.
    parameter int LATENCY = 8
) (
    // ---- User clock domain (= IP native_clk) ---------------------------
    input  wire                clk,
    input  wire                rst,

    // ---- Byte-level command/response (matches hyperram_mock shape) -----
    input  wire                cmd_valid,
    output wire                cmd_ready,
    input  wire  [ADDR_W-1:0]  cmd_addr,
    input  wire                cmd_rw,        // 1 = read, 0 = write
    input  wire  [7:0]         cmd_wdata,
    output logic [7:0]         rd_data,
    output logic               rd_valid,

    // ---- HyperRAM PHY clocks (driven from PLL by top) ------------------
    input  wire                ram_clk,
    input  wire                ram_clk_cal,

    // ---- HyperRAM device pins (passed through to top, then to GPIO) ----
    output wire                hbc_cal_pass,
    output wire                hbc_ck_n_LO,
    output wire                hbc_ck_n_HI,
    output wire                hbc_ck_p_LO,
    output wire                hbc_ck_p_HI,
    output wire                hbc_cs_n,
    output wire                hbc_rst_n,
    output wire  [7:0]         hbc_dq_OE,
    input  wire  [7:0]         hbc_dq_IN_LO,
    input  wire  [7:0]         hbc_dq_IN_HI,
    output wire  [7:0]         hbc_dq_OUT_LO,
    output wire  [7:0]         hbc_dq_OUT_HI,
    output wire                hbc_rwds_OE,
    input  wire                hbc_rwds_IN_LO,
    input  wire                hbc_rwds_IN_HI,
    output wire                hbc_rwds_OUT_LO,
    output wire                hbc_rwds_OUT_HI,

    // ---- Calibration shift / debug (top can route to LEDs / VIO) -------
    output wire  [4:0]         hbc_cal_SHIFT_SEL,
    output wire  [2:0]         hbc_cal_SHIFT,
    output wire                hbc_cal_SHIFT_ENA,
    output wire  [26:0]        hbc_cal_debug_info
);

    // ---- IP-side native interface signals ------------------------------
    logic        ip_ram_en;
    logic [31:0] ip_ram_addr;
    logic [10:0] ip_burst_len;
    logic        ip_ram_rdwr;
    logic        ip_wr_en;
    logic [63:0] ip_wr_data;
    logic [7:0]  ip_wr_datamask;
    wire         ip_ctrl_idle;
    wire         ip_rd_valid;
    wire [63:0]  ip_rd_data;
    wire         ip_wr_buf_ready;

    // ---- IP instance ---------------------------------------------------
    hyperram u_hyperram (
        .ram_clk_cal         (ram_clk_cal),
        .ram_clk             (ram_clk),
        .rst                 (rst),
        .hbc_cal_pass        (hbc_cal_pass),
        .hbc_ck_n_LO         (hbc_ck_n_LO),
        .hbc_ck_n_HI         (hbc_ck_n_HI),
        .hbc_ck_p_LO         (hbc_ck_p_LO),
        .hbc_ck_p_HI         (hbc_ck_p_HI),
        .hbc_cs_n            (hbc_cs_n),
        .hbc_rst_n           (hbc_rst_n),
        .hbc_cal_SHIFT_SEL   (hbc_cal_SHIFT_SEL),
        .hbc_cal_SHIFT       (hbc_cal_SHIFT),
        .hbc_cal_SHIFT_ENA   (hbc_cal_SHIFT_ENA),
        .native_clk          (clk),
        .native_ram_en       (ip_ram_en),
        .native_ram_address  (ip_ram_addr),
        .native_ctrl_idle    (ip_ctrl_idle),
        .native_rd_valid     (ip_rd_valid),
        .native_wr_buf_ready (ip_wr_buf_ready),
        .native_ram_burst_len(ip_burst_len),
        .native_wr_en        (ip_wr_en),
        .native_ram_rdwr     (ip_ram_rdwr),
        .hbc_dq_OE           (hbc_dq_OE),
        .hbc_dq_IN_LO        (hbc_dq_IN_LO),
        .hbc_dq_IN_HI        (hbc_dq_IN_HI),
        .hbc_dq_OUT_LO       (hbc_dq_OUT_LO),
        .hbc_dq_OUT_HI       (hbc_dq_OUT_HI),
        .hbc_rwds_OE         (hbc_rwds_OE),
        .hbc_rwds_IN_LO      (hbc_rwds_IN_LO),
        .hbc_rwds_IN_HI      (hbc_rwds_IN_HI),
        .hbc_rwds_OUT_LO     (hbc_rwds_OUT_LO),
        .hbc_rwds_OUT_HI     (hbc_rwds_OUT_HI),
        .native_wr_data      (ip_wr_data),
        .native_wr_datamask  (ip_wr_datamask),
        .native_rd_data      (ip_rd_data),
        .hbc_cal_debug_info  (hbc_cal_debug_info),
        .dyn_pll_phase_sel   (3'd0),
        .dyn_pll_phase_en    (1'b0)
    );

    // ---- Byte-to-word adapter FSM --------------------------------------
    // Each byte cmd → one IP transaction (1 user-word = 8 bytes on wire).
    //
    // S_IDLE       : ready to accept a new cmd.
    // S_RD_ISSUE   : pulse native_ram_en for the read; record byte offset.
    // S_RD_WAIT    : wait for native_rd_valid; mux the byte.
    // S_WR_PUSH    : pulse native_wr_en to push 1 user-word into wbuf.
    // S_WR_ISSUE   : pulse native_ram_en for the write.
    // S_WR_WAIT    : wait for ctrl_idle to drop and re-rise (write done).
    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_RD_ISSUE = 3'd1,
        S_RD_WAIT  = 3'd2,
        S_WR_PUSH  = 3'd3,
        S_WR_ISSUE = 3'd4,
        S_WR_WAIT  = 3'd5
    } state_t;
    state_t state, state_n;

    logic [2:0]        byte_off_q;     // captured cmd_addr[2:0] for in-flight read
    logic [ADDR_W-1:0] addr_q;         // captured cmd_addr (held across multi-cycle write FSM)
    logic [7:0]        wdata_q;        // captured cmd_wdata
    logic              wr_seen_busy_q; // saw ctrl_idle drop yet?

    // Aligned 8-byte block address as a halfword address (x8 HyperRAM
    // addresses 16-bit halfwords). cmd_addr[2:0] picks the byte within
    // the 8-byte block. Halfword address bits = cmd_addr[ADDR_W-1:1] with
    // the bottom 2 zeroed (so we land on an 8-byte boundary).
    function automatic logic [30:0] addr_to_halfword(input logic [ADDR_W-1:0] a);
        logic [30:0] hw;
        hw = '0;
        hw[ADDR_W-2:2] = a[ADDR_W-1:3];   // shift right by 1 (byte→halfword), then zero bottom 2 bits
        return hw;
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= S_IDLE;
            byte_off_q     <= 3'd0;
            addr_q         <= '0;
            wdata_q        <= 8'h00;
            wr_seen_busy_q <= 1'b0;
            rd_data        <= 8'h00;
            rd_valid       <= 1'b0;
        end else begin
            rd_valid <= 1'b0;

            // Latch cmd fields when we accept a new transaction.
            if (state == S_IDLE && cmd_valid) begin
                addr_q     <= cmd_addr;
                wdata_q    <= cmd_wdata;
                byte_off_q <= cmd_addr[2:0];
            end

            // Capture the read response when it lands.
            if (state == S_RD_WAIT && ip_rd_valid) begin
                rd_data  <= ip_rd_data[byte_off_q*8 +: 8];
                rd_valid <= 1'b1;
            end

            // Track ctrl_idle going low after a write trigger.
            if (state == S_WR_WAIT && !ip_ctrl_idle)
                wr_seen_busy_q <= 1'b1;
            if (state == S_IDLE)
                wr_seen_busy_q <= 1'b0;

            state <= state_n;
        end
    end

    always_comb begin
        state_n = state;
        case (state)
            S_IDLE:
                if (cmd_valid)
                    state_n = cmd_rw ? S_RD_ISSUE : S_WR_PUSH;
            S_RD_ISSUE:
                state_n = S_RD_WAIT;
            S_RD_WAIT:
                if (ip_rd_valid) state_n = S_IDLE;
            S_WR_PUSH:
                if (ip_wr_buf_ready) state_n = S_WR_ISSUE;
            S_WR_ISSUE:
                state_n = S_WR_WAIT;
            S_WR_WAIT:
                // wait for ctrl_idle to drop (busy seen) and rise again
                if (wr_seen_busy_q && ip_ctrl_idle) state_n = S_IDLE;
            default:
                state_n = S_IDLE;
        endcase
    end

    // ---- IP control signal drivers -------------------------------------
    // native_ram_address[31] must always be high in native mode (per IP doc).
    assign cmd_ready      = (state == S_IDLE);
    assign ip_ram_en      = (state == S_RD_ISSUE) || (state == S_WR_ISSUE);
    assign ip_ram_rdwr    = (state == S_RD_ISSUE);   // 1 = read, 0 = write
    assign ip_burst_len   = 11'd4;                   // 4 × 16 bits = 64 bits = 1 user word
    assign ip_ram_addr    = {1'b1, addr_to_halfword(addr_q)};
    assign ip_wr_en       = (state == S_WR_PUSH) && ip_wr_buf_ready;
    assign ip_wr_data     = {8{wdata_q}};            // replicate byte across all 8 lanes
    // Mask polarity: 1 = byte masked off (don't write), 0 = byte enabled.
    // Single-byte write: enable only the byte at byte_off_q.
    assign ip_wr_datamask = ~(8'h01 << byte_off_q);

endmodule

`default_nettype wire
