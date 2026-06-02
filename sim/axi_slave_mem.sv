// axi_slave_mem.sv — memory-backed AXI4 slave for simulation.
//
// Sim-only.  Lives in sim/ (not hdl/) and is added to per-target HDL
// lists in the Makefile.  Provides a flat byte-addressable backing store
// (MEM_BYTES) accessible via the AXI4 read/write channels, plus a small
// $readmemh / public-write API for testbench-side seeding.
//
// Design notes:
//   - Single-clock, always-accept handshakes (AWREADY / WREADY / ARREADY
//     all driven high).  No back-pressure modeling — fine for the
//     sally_mem suite where AXI is the backing store, not the DUT.
//   - 64-bit data bus matches Zynq HP3 / banked_axi_reader assumption.
//   - Bursts honour AWLEN / ARLEN (incrementing AXI4 bursts only;
//     wraps / fixed-bursts are not modelled).
//   - On read past end-of-memory, returns 64'h0 (banked_axi_reader
//     wraps at its window so OOB reads shouldn't happen in practice).
//
// Public testbench helpers:
//   write_byte(addr, data)   — direct backing-store poke
//   read_byte(addr) → byte   — direct backing-store peek

`default_nettype none

// Backing store is a sparse associative array (mem[int] → byte) — the
// SALLY address-space scheme tags sub-blocks of the bank window with bits
// [15:14] of bank_id, so legitimate accesses can land at AXI addresses up
// to ~192 MB even though only a few cache lines are actually touched.
// A flat array would need ~256 MB; an associative array allocates per
// touched byte (~kB total for realistic test programs).

module axi_slave_mem #(
    parameter int ADDR_W    = 32,
    parameter int DATA_W    = 64,
    parameter int STRB_W    = DATA_W / 8,
    // Read-latency model (sim realism).  RD_LAT = cycles from AR-accept to the
    // first RVALID; RD_LAT_JIT adds a pseudo-random 0..RD_LAT_JIT extra cycles
    // per burst (address-hashed, deterministic) to emulate DDR page/bank +
    // arbiter variance.  Defaults 0/0 keep the original zero-latency,
    // always-accept behaviour for every existing testbench.
    parameter int RD_LAT     = 0,
    parameter int RD_LAT_JIT = 0
) (
    input  wire             clk,
    input  wire             rst,

    // ---- AXI4 write channel -------------------------------------------
    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire [7:0]        s_axi_awlen,
    input  wire [2:0]        s_axi_awsize,
    input  wire [1:0]        s_axi_awburst,
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,

    input  wire [DATA_W-1:0] s_axi_wdata,
    input  wire [STRB_W-1:0] s_axi_wstrb,
    input  wire              s_axi_wlast,
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,

    output reg               s_axi_bvalid,
    input  wire              s_axi_bready,

    // ---- AXI4 read channel --------------------------------------------
    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire [7:0]        s_axi_arlen,
    input  wire [2:0]        s_axi_arsize,
    input  wire [1:0]        s_axi_arburst,
    input  wire              s_axi_arvalid,
    output wire              s_axi_arready,

    output reg  [DATA_W-1:0] s_axi_rdata,
    output reg               s_axi_rvalid,
    output reg               s_axi_rlast,
    input  wire              s_axi_rready
);

    // ---- Backing store -------------------------------------------------
    // Flat array with modular indexing — SALLY bank-window addresses are
    // composed as DDR3_BANKED_BASE | {bank_id[15:0], offset[11:0]} and
    // can land up to ~192 MB in even with BASE=0 (bank_id[15:14] is the
    // sub-block tag).  We fold the AXI address modulo MEM_BYTES so the
    // backing storage stays small; collisions between far-apart logical
    // addresses don't matter for current unit-level tests.
    localparam int MEM_BYTES = 256 * 1024;
    reg [7:0] mem [0:MEM_BYTES-1];
    initial begin
        for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;
    end

    function automatic int unsigned wrap(input [ADDR_W-1:0] a);
        return a % MEM_BYTES;
    endfunction

    // ---- Always-accept handshakes --------------------------------------
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    // ARREADY held low while a read burst is in flight (one burst at a time).
    reg ar_busy;
    assign s_axi_arready = !ar_busy;

    // ---- Write FSM -----------------------------------------------------
    // Capture AW, then accumulate W beats, asserting BVALID once WLAST seen.
    reg [ADDR_W-1:0] aw_addr_q;
    reg [7:0]        aw_beat_q;   // beats remaining = AWLEN+1 on capture
    reg              aw_seen_q;   // 1 once AW captured, before W ends

    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            aw_addr_q   <= '0;
            aw_beat_q   <= '0;
            aw_seen_q   <= 1'b0;
            s_axi_bvalid <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_addr_q <= s_axi_awaddr;
                aw_beat_q <= s_axi_awlen;        // off-by-one: -1 each W beat
                aw_seen_q <= 1'b1;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                for (i = 0; i < STRB_W; i++) begin
                    if (s_axi_wstrb[i]) begin
                        mem[wrap(aw_addr_q + i)] <= s_axi_wdata[i*8 +: 8];
                    end
                end
                // Advance to next beat (8-byte INCR bursts on a 64-bit bus).
                aw_addr_q <= aw_addr_q + STRB_W;
                if (s_axi_wlast) begin
                    aw_seen_q   <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                end
            end
        end
    end

    // ---- Read FSM ------------------------------------------------------
    reg [ADDR_W-1:0] ar_addr_q;
    reg [7:0]        ar_beats_q;  // beats remaining including the current

    function automatic [DATA_W-1:0] mem_read64(input [ADDR_W-1:0] addr);
        logic [DATA_W-1:0] v;
        v = '0;
        for (int j = 0; j < STRB_W; j++) v[j*8 +: 8] = mem[wrap(addr + j)];
        return v;
    endfunction

    // Per-burst read latency (AR-accept -> first RVALID).  Address-hashed
    // jitter is deterministic so runs are reproducible.
    reg [15:0] rd_lat_cnt;
    reg        rd_wait;
    function automatic [15:0] lat_for(input [ADDR_W-1:0] a);
        if (RD_LAT_JIT <= 0) return RD_LAT[15:0];
        else return RD_LAT[15:0] +
                    16'(((a >> 6) ^ (a >> 13)) % (RD_LAT_JIT + 1));
    endfunction

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ar_addr_q    <= '0;
            ar_beats_q   <= '0;
            ar_busy      <= 1'b0;
            rd_wait      <= 1'b0;
            rd_lat_cnt   <= 16'd0;
            s_axi_rdata  <= '0;
            s_axi_rvalid <= 1'b0;
            s_axi_rlast  <= 1'b0;
        end else begin
            // Latency wait: AR accepted, counting down to the first beat.
            if (rd_wait) begin
                if (rd_lat_cnt == 16'd0) begin
                    s_axi_rdata  <= mem_read64(ar_addr_q);
                    s_axi_rvalid <= 1'b1;
                    s_axi_rlast  <= (ar_beats_q == 8'd1);
                    rd_wait      <= 1'b0;
                end else begin
                    rd_lat_cnt <= rd_lat_cnt - 16'd1;
                end
            end

            if (s_axi_rvalid && s_axi_rready) begin
                if (s_axi_rlast) begin
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast  <= 1'b0;
                    ar_busy      <= 1'b0;
                end else begin
                    ar_addr_q   <= ar_addr_q + STRB_W;
                    ar_beats_q  <= ar_beats_q - 1'b1;
                    s_axi_rdata <= mem_read64(ar_addr_q + STRB_W);
                    s_axi_rlast <= (ar_beats_q == 8'd2);
                end
            end

            if (!ar_busy && s_axi_arvalid && s_axi_arready) begin
                ar_addr_q    <= s_axi_araddr;
                ar_beats_q   <= s_axi_arlen + 8'd1;
                ar_busy      <= 1'b1;
                if (lat_for(s_axi_araddr) == 16'd0) begin
                    s_axi_rdata  <= mem_read64(s_axi_araddr);   // zero-lat: original
                    s_axi_rvalid <= 1'b1;
                    s_axi_rlast  <= (s_axi_arlen == 8'd0);
                end else begin
                    rd_wait      <= 1'b1;
                    rd_lat_cnt   <= lat_for(s_axi_araddr) - 16'd1;
                    s_axi_rvalid <= 1'b0;
                end
            end
        end
    end

    // ---- Testbench-side helpers ----------------------------------------
    // Use these to seed program code / data before kicking the DUT.
    task automatic seed_byte(input [ADDR_W-1:0] addr, input [7:0] data);
        mem[wrap(addr)] = data;
    endtask

    function automatic [7:0] peek_byte(input [ADDR_W-1:0] addr);
        return mem[wrap(addr)];
    endfunction

endmodule

`default_nettype wire
