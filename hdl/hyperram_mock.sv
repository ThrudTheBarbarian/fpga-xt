// hyperram_mock.sv — sim-only model of the Efinix HyperRAM Controller IP.
//
// Models the command/data interface a fpga-antic build would talk to
// (both for sim and as the spec the hyperram_shim is built against).
// In synth, this module is replaced by the vendor IP wrapper at
// `hdl/hyperram_phy.sv` — the consumer (hyperram_shim) instantiates a
// module called `hyperram_phy` either way:
//   - sim build: this file (hdl/hyperram_mock.sv defines module hyperram_phy
//     with a behavioural latency model + 64 KB backing memory). The file is
//     filtered out of synth via run.sh's `_mock.sv` exclude.
//   - synth build: hdl/hyperram_phy.sv defines module hyperram_phy and
//     instantiates the actual Efinix IP under it.
//
// The PHY-side ports (ram_clk, ram_clk_cal, hbc_*) are declared but
// unused here — they exist so the port list matches the synth wrapper,
// keeping hyperram_shim's instantiation site identical in both builds.
//
// Protocol:
//   - cmd_valid pulses for one cycle when the consumer issues a
//     command. cmd_ready must be high — controller is idle / can
//     accept a new cmd. cmd_rw=1 for read, =0 for write.
//   - For writes: data is captured on the same cycle as cmd_valid.
//     cmd_ready stays high (controller can immediately take another
//     command in this simple model).
//   - For reads: LATENCY clk cycles after cmd_valid, rd_valid pulses
//     for one cycle with rd_data = mem[cmd_addr]. cmd_ready drops
//     while a read is in flight (back-to-back reads serialise).
//
// Real HyperRAM is more involved (initial vs. subsequent latency,
// burst length, refresh windows), but this model captures what
// hyperram_shim needs to test the latency-handling and arbitration
// paths.
//
// Address space: parameterised. For sim we use 16-bit addresses
// (matches Atari) so the backing memory is just 64 KB.

`default_nettype none

module hyperram_phy #(
    parameter int ADDR_W = 16,
    parameter int LATENCY = 8         // read latency in clk cycles (≥ 1)
) (
    input  wire                clk,
    input  wire                rst,

    // Command interface (single-port).
    input  wire                cmd_valid,
    output logic               cmd_ready,
    input  wire  [ADDR_W-1:0]  cmd_addr,
    input  wire                cmd_rw,    // 1 = read, 0 = write
    input  wire  [7:0]         cmd_wdata,

    // Read response. Combinational from the head of the pipeline so
    // it aligns with the consumer's tag pipe (otherwise an extra
    // register stage skews tag/data by 1 cycle).
    output wire  [7:0]         rd_data,
    output wire                rd_valid,

    // ---- PHY-side ports (unused in sim; mirror the synth wrapper) ------
    // Declared so hyperram_shim's port list and instantiation are
    // identical in sim and synth. Inputs go nowhere; outputs default-low.
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
    // PHY outputs default to 0 (sim doesn't model the device side).
    assign hbc_cal_pass       = 1'b0;
    assign hbc_ck_n_LO        = 1'b0;
    assign hbc_ck_n_HI        = 1'b0;
    assign hbc_ck_p_LO        = 1'b0;
    assign hbc_ck_p_HI        = 1'b0;
    assign hbc_cs_n           = 1'b1;
    assign hbc_rst_n          = 1'b1;
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

    // Backing memory.
    logic [7:0] mem [0:(1<<ADDR_W)-1];

    // Read pipeline. shift register that walks "in-flight" reads out
    // by LATENCY cycles. Each entry has a `valid` bit + 8-bit data.
    logic [LATENCY-1:0]            pipe_valid;
    logic [7:0]                    pipe_data [0:LATENCY-1];

    assign rd_valid = pipe_valid[0];
    assign rd_data  = pipe_data[0];

    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pipe_valid <= '0;
            cmd_ready  <= 1'b1;
            for (i = 0; i < LATENCY; i = i + 1) pipe_data[i] <= 8'h00;
        end else begin
            // Shift the pipeline down by one slot (closer to output).
            for (i = 0; i < LATENCY-1; i = i + 1) begin
                pipe_valid[i] <= pipe_valid[i+1];
                pipe_data[i]  <= pipe_data[i+1];
            end
            pipe_valid[LATENCY-1] <= 1'b0;
            pipe_data[LATENCY-1]  <= 8'h00;

            // cmd_ready is high when no read is in flight (any pipe
            // entry valid means "busy"). Writes don't take pipeline
            // slots — they complete immediately.
            cmd_ready <= ~|pipe_valid;

            if (cmd_valid && cmd_ready) begin
                if (cmd_rw) begin
                    // Read: schedule the response LATENCY cycles out.
                    pipe_valid[LATENCY-1] <= 1'b1;
                    pipe_data[LATENCY-1]  <= mem[cmd_addr];
                    cmd_ready             <= 1'b0;       // serialise
                end else begin
                    // Write: take effect now.
                    mem[cmd_addr] <= cmd_wdata;
                end
            end
        end
    end

endmodule

`default_nettype wire
