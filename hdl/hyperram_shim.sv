// hyperram_shim.sv — dual-read-port + write-port wrapper around the
// Efinix HyperRAM Controller IP (modelled in sim by hyperram_mock).
//
// Presents a similar shape to byte_ram_dp but with a ready/valid
// handshake on each read port (because HyperRAM has multi-cycle
// latency, unlike BRAM which is fixed 1-cycle). The two read ports
// share a single physical HyperRAM channel, so internal arbitration
// is required.
//
// Arbitration policy (simple, deterministic):
//   1. Pending writes win first (single-deep write FIFO; bus_snoop
//      can fire writes faster than HyperRAM can absorb, but in
//      practice CPU cycles are much slower than the FPGA fabric).
//   2. Then read port A (dl_parser side).
//   3. Then read port B (compositor side).
//
// Each read port has its own one-deep request register. While a
// port has a request in flight, its `ready` output is low (caller
// must stall). When the response lands, the data is captured into
// per-port `rdata_*_q` and `rd_valid_*` pulses one cycle.
//
// Write FIFO is one-deep — reasonable for the fabric/CPU clock
// ratio. Deeper queues are an optimisation if writes ever back up.

`default_nettype none

module hyperram_shim #(
    parameter int ADDR_W  = 16,
    parameter int LATENCY = 8
) (
    input  wire                clk,
    input  wire                rst,

    // Write port (from bus_snoop). wready=0 means the write FIFO is
    // saturated and a new `we` pulse this cycle would be DROPPED — the
    // caller must hold off. Real bus_snoop writes are ~1 per CPU cycle
    // (≈ 1/12 fabric cycles at CLOCK_MULT=12) so saturation is rare,
    // but the handshake is exposed so the test can pace correctly.
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

    // ---- HyperRAM PHY-side ports (passed through to u_ip) -------------
    // These exist on the shim's port list so antic_top can wire them to
    // FPGA pins in synth. In sim the mock declares the same ports but
    // doesn't drive/use them (testbenches leave them dangling).
    input  wire                ram_clk,
    input  wire                ram_clk_cal,
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
    output wire  [4:0]         hbc_cal_SHIFT_SEL,
    output wire  [2:0]         hbc_cal_SHIFT,
    output wire                hbc_cal_SHIFT_ENA,
    output wire  [26:0]        hbc_cal_debug_info
);

    // ---- HyperRAM mock (= IP wrapper in synth) -------------------------
    logic                cmd_valid;
    logic [ADDR_W-1:0]   cmd_addr;
    logic                cmd_rw;
    logic [7:0]          cmd_wdata;
    wire                 cmd_ready;
    wire  [7:0]          rd_data;
    wire                 rd_valid;

    hyperram_phy #(.ADDR_W(ADDR_W), .LATENCY(LATENCY)) u_ip (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_rw(cmd_rw),
        .cmd_wdata(cmd_wdata),
        .rd_data(rd_data), .rd_valid(rd_valid),
        // PHY pass-through (driven only in synth; sim leaves them inert)
        .ram_clk(ram_clk), .ram_clk_cal(ram_clk_cal),
        .hbc_cal_pass(hbc_cal_pass),
        .hbc_ck_n_LO(hbc_ck_n_LO), .hbc_ck_n_HI(hbc_ck_n_HI),
        .hbc_ck_p_LO(hbc_ck_p_LO), .hbc_ck_p_HI(hbc_ck_p_HI),
        .hbc_cs_n(hbc_cs_n), .hbc_rst_n(hbc_rst_n),
        .hbc_dq_OE(hbc_dq_OE),
        .hbc_dq_IN_LO(hbc_dq_IN_LO), .hbc_dq_IN_HI(hbc_dq_IN_HI),
        .hbc_dq_OUT_LO(hbc_dq_OUT_LO), .hbc_dq_OUT_HI(hbc_dq_OUT_HI),
        .hbc_rwds_OE(hbc_rwds_OE),
        .hbc_rwds_IN_LO(hbc_rwds_IN_LO), .hbc_rwds_IN_HI(hbc_rwds_IN_HI),
        .hbc_rwds_OUT_LO(hbc_rwds_OUT_LO), .hbc_rwds_OUT_HI(hbc_rwds_OUT_HI),
        .hbc_cal_SHIFT_SEL(hbc_cal_SHIFT_SEL),
        .hbc_cal_SHIFT(hbc_cal_SHIFT),
        .hbc_cal_SHIFT_ENA(hbc_cal_SHIFT_ENA),
        .hbc_cal_debug_info(hbc_cal_debug_info));

    // ---- Per-port request state ---------------------------------------
    logic               busy_a;          // port A has a read in flight
    logic               busy_b;          // port B has a read in flight

    // ---- Write FIFO (depth 1) -----------------------------------------
    logic               wfifo_full;
    logic [ADDR_W-1:0]  wfifo_addr;
    logic [7:0]         wfifo_data;

    // ---- Outstanding-read tag ------------------------------------------
    // Track which port is owning the in-flight read so the response
    // can be routed back. The pipe is LATENCY+1 stages deep because
    // the shim's `cmd_valid` register adds one cycle of delay between
    // cmd_src=SRC_READ_* and the mock's pipe_valid injection — the
    // extra slot keeps the tag aligned with the data response.
    localparam int TAG_DEPTH = LATENCY + 1;
    logic [TAG_DEPTH-1:0]  tag_pipe_valid;
    logic [TAG_DEPTH-1:0]  tag_pipe_owner;

    // Combinational arbitration: who gets the next cmd this cycle?
    typedef enum logic [1:0] {
        SRC_NONE  = 2'd0,
        SRC_WRITE = 2'd1,
        SRC_READ_A= 2'd2,
        SRC_READ_B= 2'd3
    } src_t;
    src_t cmd_src;

    always_comb begin
        cmd_src = SRC_NONE;
        if (cmd_ready) begin
            if (we || wfifo_full)        cmd_src = SRC_WRITE;
            else if (req_a && !busy_a)   cmd_src = SRC_READ_A;
            else if (req_b && !busy_b)   cmd_src = SRC_READ_B;
        end
    end

    // ---- FSM ----------------------------------------------------------
    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            cmd_valid       <= 1'b0;
            cmd_addr        <= '0;
            cmd_rw          <= 1'b0;
            cmd_wdata       <= 8'h00;
            busy_a          <= 1'b0;
            busy_b          <= 1'b0;
            wfifo_full      <= 1'b0;
            wfifo_addr      <= '0;
            wfifo_data      <= 8'h00;
            rdata_a         <= 8'h00;
            rdata_b         <= 8'h00;
            rd_valid_a      <= 1'b0;
            rd_valid_b      <= 1'b0;
            tag_pipe_valid  <= '0;
            tag_pipe_owner  <= '0;
        end else begin
            cmd_valid  <= 1'b0;
            rd_valid_a <= 1'b0;
            rd_valid_b <= 1'b0;

            // ----- Issue a command per arbitration result -------------
            // Writes always drain FROM the FIFO (the live `we` path
            // goes through the FIFO via the capture block below, so
            // order is preserved).
            case (cmd_src)
                SRC_WRITE: begin
                    cmd_valid <= 1'b1;
                    cmd_rw    <= 1'b0;
                    cmd_addr  <= wfifo_addr;
                    cmd_wdata <= wfifo_data;
                    wfifo_full <= 1'b0;
                end
                SRC_READ_A: begin
                    cmd_valid <= 1'b1;
                    cmd_rw    <= 1'b1;
                    cmd_addr  <= raddr_a;
                    busy_a    <= 1'b1;
                end
                SRC_READ_B: begin
                    cmd_valid <= 1'b1;
                    cmd_rw    <= 1'b1;
                    cmd_addr  <= raddr_b;
                    busy_b    <= 1'b1;
                end
                default: ; // idle
            endcase

            // ----- Inject the tag into the pipeline at issue time ----
            // Write commands don't generate a response; only reads add
            // a tag to the pipeline so we can route the response back.
            for (i = 0; i < TAG_DEPTH-1; i = i + 1) begin
                tag_pipe_valid[i] <= tag_pipe_valid[i+1];
                tag_pipe_owner[i] <= tag_pipe_owner[i+1];
            end
            tag_pipe_valid[TAG_DEPTH-1] <= 1'b0;
            tag_pipe_owner[TAG_DEPTH-1] <= 1'b0;
            if (cmd_src == SRC_READ_A) begin
                tag_pipe_valid[TAG_DEPTH-1] <= 1'b1;
                tag_pipe_owner[TAG_DEPTH-1] <= 1'b0;
            end else if (cmd_src == SRC_READ_B) begin
                tag_pipe_valid[TAG_DEPTH-1] <= 1'b1;
                tag_pipe_owner[TAG_DEPTH-1] <= 1'b1;
            end

            // ----- Capture incoming write into FIFO -------------------
            // Placed AFTER the drain branch so NBA last-write-wins keeps
            // wfifo_full=1 when we're both draining the old slot AND
            // capturing a new write in the same cycle.
            if (we && (!wfifo_full || cmd_src == SRC_WRITE)) begin
                wfifo_addr <= waddr;
                wfifo_data <= wdata;
                wfifo_full <= 1'b1;
            end

            // ----- Capture rd_valid pulse, route to the right port ----
            if (rd_valid && tag_pipe_valid[0]) begin
                if (tag_pipe_owner[0] == 1'b0) begin
                    rdata_a    <= rd_data;
                    rd_valid_a <= 1'b1;
                    busy_a     <= 1'b0;
                end else begin
                    rdata_b    <= rd_data;
                    rd_valid_b <= 1'b1;
                    busy_b     <= 1'b0;
                end
            end
        end
    end

    // ---- Ready signaling ----------------------------------------------
    // A port is "ready" when it has no outstanding request — caller
    // can issue a fresh req. Note that req_a + ready_a together act
    // as the "fire" event; the shim then drops ready_a until rd_valid_a
    // pulses.
    assign ready_a = !busy_a;
    assign ready_b = !busy_b;
    assign wready  = !wfifo_full;

endmodule

`default_nettype wire
