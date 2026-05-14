// sally_synth_top.sv — standalone synth wrapper for the M24 SALLY
// stack (sally_core + sally_clock + sally_mem + bank_cache + bank_xlat).
//
// Use case: per-block synth + STA in isolation, ahead of the full
// antic_top integration. Lets us answer "does sally_core close ≥100
// MHz on Topaz Tz50F256-I3?" without bringing in the rest of the
// chip's logic / BRAM / HDMI domains.
//
// All external I/O is registered at the pads (pad_*), so the timing
// report measures internal critical paths rather than I/O delays.
//
// HyperRAM port stubbed to a single-cycle done — the bank_cache stalls
// for a real refill in ASIC silicon, but for STA we want the pipeline
// to be exercised continuously.

`default_nettype none

module sally_synth_top (
    input  wire        clk,
    input  wire        rst,

    // Bus / interrupt pads — registered on entry / exit so the report
    // shows internal logic delay, not pad-to-flop combinational paths.
    input  wire [7:0]  pad_data_in,
    input  wire        pad_irq_n,
    input  wire        pad_nmi_n,
    input  wire        pad_halt_n,
    input  wire        pad_wsync_rdy_n,
    input  wire        pad_phi2_tick,
    input  wire [7:0]  pad_clock_mult,

    output wire [15:0] pad_addr,
    output wire [7:0]  pad_data_out,
    output wire        pad_rw,
    output wire        pad_busy,

    // HyperRAM pads — registered so the synth knows the cache's
    // request path is real logic, not a sea of unconstrained ties.
    // M-cache-rework Step 5: burst handshake — one pad_hr_req pulse
    // covers a full cache-line burst, with pad_hr_burst_len giving
    // N-1. Read responses arrive via pad_hr_rdata + pad_hr_rvalid;
    // pad_hr_done pulses on the last byte.
    output wire [22:0] pad_hr_addr,
    output wire [9:0]  pad_hr_burst_len,
    output wire        pad_hr_we,
    output wire [7:0]  pad_hr_wdata,
    output wire        pad_hr_req,
    input  wire [7:0]  pad_hr_rdata,
    input  wire        pad_hr_rvalid,
    input  wire        pad_hr_done,

    // ROM-load pads (chiplet-ext register loader)
    input  wire [15:0] pad_rom_addr,
    input  wire [7:0]  pad_rom_data,
    input  wire        pad_rom_we
);

    // ---- Pad-register stage --------------------------------------------
    // One-cycle register on every input; output drives directly from the
    // module's registered output.
    logic [7:0]  data_in_q;
    logic        irq_n_q, nmi_n_q;
    logic        halt_n_q, wsync_rdy_n_q, phi2_tick_q;
    logic [7:0]  clock_mult_q;
    logic [7:0]  hr_rdata_q;
    logic        hr_rvalid_q;
    logic        hr_done_q;
    logic [15:0] rom_addr_q;
    logic [7:0]  rom_data_q;
    logic        rom_we_q;

    always_ff @(posedge clk) begin
        data_in_q     <= pad_data_in;
        irq_n_q       <= pad_irq_n;
        nmi_n_q       <= pad_nmi_n;
        halt_n_q      <= pad_halt_n;
        wsync_rdy_n_q <= pad_wsync_rdy_n;
        phi2_tick_q   <= pad_phi2_tick;
        clock_mult_q  <= pad_clock_mult;
        hr_rdata_q    <= pad_hr_rdata;
        hr_rvalid_q   <= pad_hr_rvalid;
        hr_done_q     <= pad_hr_done;
        rom_addr_q    <= pad_rom_addr;
        rom_data_q    <= pad_rom_data;
        rom_we_q      <= pad_rom_we;
    end

    // ---- sally_clock — RDY gating --------------------------------------
    wire sally_rdy_w;
    wire sally_step_w;

    sally_clock u_clock (
        .clk         (clk),
        .rst         (rst),
        .phi2_tick   (phi2_tick_q),
        .clock_mult  (clock_mult_q),
        .halt_n      (halt_n_q),
        .wsync_rdy_n (wsync_rdy_n_q),
        .busy_n      (~mem_busy_w),
        .sally_rdy   (sally_rdy_w),
        .sally_step  (sally_step_w)
    );

    // ---- sally_core ----------------------------------------------------
    wire [15:0] cpu_addr_w;
    wire [7:0]  cpu_dout_w;
    wire        cpu_rw_w;
    wire [7:0]  mem_dout_w;
    wire        mem_busy_w;

    sally_core u_cpu (
        .clk      (clk),
        .rst      (rst),
        .addr     (cpu_addr_w),
        .data_in  (mem_dout_w),
        .data_out (cpu_dout_w),
        .rw       (cpu_rw_w),
        .rdy      (sally_rdy_w),
        .irq_n    (irq_n_q),
        .nmi_n    (nmi_n_q)
    );

    // ---- sally_mem -----------------------------------------------------
    wire [15:0] hwreg_addr_w;
    wire        hwreg_we_w;
    wire [7:0]  hwreg_din_w;

    wire [22:0] hr_addr_w;
    wire [9:0]  hr_burst_len_w;
    wire        hr_we_w;
    wire [7:0]  hr_wdata_w;
    wire        hr_req_w;

    wire [7:0]  cpu_code_bank_q_w, cpu_data_bank_q_w;
    wire [7:0]  cpu_regc_bank_lo_q_w, cpu_regc_bank_hi_q_w;

    sally_mem u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (cpu_addr_w),
        .data_in    (cpu_dout_w),
        .rw         (cpu_rw_w),
        .data_out   (mem_dout_w),
        .rdy        (sally_rdy_w),
        .busy       (mem_busy_w),
        .hwreg_addr (hwreg_addr_w),
        .hwreg_we   (hwreg_we_w),
        .hwreg_din  (hwreg_din_w),
        .hwreg_dout (8'hFF),                  // unassigned-addr default (Altirra §4.1)
        .cpu_code_bank_q    (cpu_code_bank_q_w),
        .cpu_data_bank_q    (cpu_data_bank_q_w),
        .cpu_regc_bank_lo_q (cpu_regc_bank_lo_q_w),
        .cpu_regc_bank_hi_q (cpu_regc_bank_hi_q_w),
        .antic_code_bank    (8'h00),
        .antic_data_bank    (8'h00),
        .antic_regc_bank_lo (8'h00),
        .antic_regc_bank_hi (8'h00),
        .view_is_antic      (1'b0),
        .hr_addr      (hr_addr_w),
        .hr_burst_len (hr_burst_len_w),
        .hr_we        (hr_we_w),
        .hr_wdata     (hr_wdata_w),
        .hr_req       (hr_req_w),
        .hr_rdata     (hr_rdata_q),
        .hr_rvalid    (hr_rvalid_q),
        .hr_done      (hr_done_q),
        .rom_addr    (rom_addr_q),
        .rom_data    (rom_data_q),
        .rom_we      (rom_we_q)
    );

    // ---- Pad-register stage (outputs) ----------------------------------
    logic [15:0] pad_addr_q;
    logic [7:0]  pad_dout_q;
    logic        pad_rw_q;
    logic        pad_busy_q;
    logic [22:0] pad_hr_addr_q;
    logic [9:0]  pad_hr_burst_len_q;
    logic        pad_hr_we_q;
    logic [7:0]  pad_hr_wdata_q;
    logic        pad_hr_req_q;

    always_ff @(posedge clk) begin
        pad_addr_q         <= cpu_addr_w;
        pad_dout_q         <= cpu_dout_w;
        pad_rw_q           <= cpu_rw_w;
        pad_busy_q         <= mem_busy_w;
        pad_hr_addr_q      <= hr_addr_w;
        pad_hr_burst_len_q <= hr_burst_len_w;
        pad_hr_we_q        <= hr_we_w;
        pad_hr_wdata_q     <= hr_wdata_w;
        pad_hr_req_q       <= hr_req_w;
    end

    assign pad_addr         = pad_addr_q;
    assign pad_data_out     = pad_dout_q;
    assign pad_rw           = pad_rw_q;
    assign pad_busy         = pad_busy_q;
    assign pad_hr_addr      = pad_hr_addr_q;
    assign pad_hr_burst_len = pad_hr_burst_len_q;
    assign pad_hr_we        = pad_hr_we_q;
    assign pad_hr_wdata     = pad_hr_wdata_q;
    assign pad_hr_req       = pad_hr_req_q;

endmodule

`default_nettype wire
