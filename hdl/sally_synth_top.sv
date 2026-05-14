// sally_synth_top.sv — standalone synth wrapper for the SALLY stack
// (sally_core + sally_clock + sally_mem + bank_xlat + banked_axi_reader).
//
// Use case: per-block synth + STA in isolation, ahead of the full
// antic_top integration. Lets us answer "does sally_core close on
// Zynq-7020 -2 at the target clock?" without bringing in the rest of
// the system's logic / BRAM / HDMI domains.
//
// All external I/O is registered at the pads (pad_*), so the timing
// report measures internal critical paths rather than I/O delays.
//
// v2a (sally-mem-v2.md): the HyperRAM port + bank_cache are gone.
// Banked-window accesses route to an AXI4-Lite-class read master
// (banked_axi_reader) targeting PS DDR3 via AXI HP. For the standalone
// synth probe the AXI master ports are registered at the pads so the
// synth knows the request path is real logic, not a sea of
// unconstrained ties. In the real system this connects to an AXI HP
// slave port on the Zynq PS.

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

    // AXI4 burst read + write master to PS DDR3 (banked-window port; v2c).
    output wire [31:0] pad_m_axi_araddr,
    output wire [7:0]  pad_m_axi_arlen,
    output wire [2:0]  pad_m_axi_arsize,
    output wire [1:0]  pad_m_axi_arburst,
    output wire        pad_m_axi_arvalid,
    input  wire        pad_m_axi_arready,
    input  wire [63:0] pad_m_axi_rdata,
    input  wire        pad_m_axi_rvalid,
    input  wire        pad_m_axi_rlast,
    output wire        pad_m_axi_rready,
    output wire [31:0] pad_m_axi_awaddr,
    output wire [7:0]  pad_m_axi_awlen,
    output wire [2:0]  pad_m_axi_awsize,
    output wire [1:0]  pad_m_axi_awburst,
    output wire        pad_m_axi_awvalid,
    input  wire        pad_m_axi_awready,
    output wire [63:0] pad_m_axi_wdata,
    output wire [7:0]  pad_m_axi_wstrb,
    output wire        pad_m_axi_wlast,
    output wire        pad_m_axi_wvalid,
    input  wire        pad_m_axi_wready,
    input  wire        pad_m_axi_bvalid,
    output wire        pad_m_axi_bready,

    // ROM-load pads (chiplet-ext register loader)
    input  wire [15:0] pad_rom_addr,
    input  wire [7:0]  pad_rom_data,
    input  wire        pad_rom_we
);

    // ---- Pad-register stage (inputs) -----------------------------------
    logic [7:0]  data_in_q;
    logic        irq_n_q, nmi_n_q;
    logic        halt_n_q, wsync_rdy_n_q, phi2_tick_q;
    logic [7:0]  clock_mult_q;
    logic        m_axi_arready_q;
    logic [63:0] m_axi_rdata_q;
    logic        m_axi_rvalid_q;
    logic        m_axi_rlast_q;
    logic        m_axi_awready_q;
    logic        m_axi_wready_q;
    logic        m_axi_bvalid_q;
    logic [15:0] rom_addr_q;
    logic [7:0]  rom_data_q;
    logic        rom_we_q;

    always_ff @(posedge clk) begin
        data_in_q       <= pad_data_in;
        irq_n_q         <= pad_irq_n;
        nmi_n_q         <= pad_nmi_n;
        halt_n_q        <= pad_halt_n;
        wsync_rdy_n_q   <= pad_wsync_rdy_n;
        phi2_tick_q     <= pad_phi2_tick;
        clock_mult_q    <= pad_clock_mult;
        m_axi_arready_q <= pad_m_axi_arready;
        m_axi_rdata_q   <= pad_m_axi_rdata;
        m_axi_rvalid_q  <= pad_m_axi_rvalid;
        m_axi_rlast_q   <= pad_m_axi_rlast;
        m_axi_awready_q <= pad_m_axi_awready;
        m_axi_wready_q  <= pad_m_axi_wready;
        m_axi_bvalid_q  <= pad_m_axi_bvalid;
        rom_addr_q      <= pad_rom_addr;
        rom_data_q      <= pad_rom_data;
        rom_we_q        <= pad_rom_we;
    end

    // ---- sally_clock — RDY gating --------------------------------------
    wire sally_rdy_w;
    wire sally_step_w;
    wire mem_busy_w;

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

    wire [31:0] m_axi_araddr_w;
    wire [7:0]  m_axi_arlen_w;
    wire [2:0]  m_axi_arsize_w;
    wire [1:0]  m_axi_arburst_w;
    wire        m_axi_arvalid_w;
    wire        m_axi_rready_w;
    wire [31:0] m_axi_awaddr_w;
    wire [7:0]  m_axi_awlen_w;
    wire [2:0]  m_axi_awsize_w;
    wire [1:0]  m_axi_awburst_w;
    wire        m_axi_awvalid_w;
    wire [63:0] m_axi_wdata_w;
    wire [7:0]  m_axi_wstrb_w;
    wire        m_axi_wlast_w;
    wire        m_axi_wvalid_w;
    wire        m_axi_bready_w;

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
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'h00),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
        .m_axi_araddr       (m_axi_araddr_w),
        .m_axi_arlen        (m_axi_arlen_w),
        .m_axi_arsize       (m_axi_arsize_w),
        .m_axi_arburst      (m_axi_arburst_w),
        .m_axi_arvalid      (m_axi_arvalid_w),
        .m_axi_arready      (m_axi_arready_q),
        .m_axi_rdata        (m_axi_rdata_q),
        .m_axi_rvalid       (m_axi_rvalid_q),
        .m_axi_rlast        (m_axi_rlast_q),
        .m_axi_rready       (m_axi_rready_w),
        .m_axi_awaddr       (m_axi_awaddr_w),
        .m_axi_awlen        (m_axi_awlen_w),
        .m_axi_awsize       (m_axi_awsize_w),
        .m_axi_awburst      (m_axi_awburst_w),
        .m_axi_awvalid      (m_axi_awvalid_w),
        .m_axi_awready      (m_axi_awready_q),
        .m_axi_wdata        (m_axi_wdata_w),
        .m_axi_wstrb        (m_axi_wstrb_w),
        .m_axi_wlast        (m_axi_wlast_w),
        .m_axi_wvalid       (m_axi_wvalid_w),
        .m_axi_wready       (m_axi_wready_q),
        .m_axi_bvalid       (m_axi_bvalid_q),
        .m_axi_bready       (m_axi_bready_w),
        .rom_addr    (rom_addr_q),
        .rom_data    (rom_data_q),
        .rom_we      (rom_we_q)
    );

    // ---- Pad-register stage (outputs) ----------------------------------
    logic [15:0] pad_addr_q;
    logic [7:0]  pad_dout_q;
    logic        pad_rw_q;
    logic        pad_busy_q;
    logic [31:0] pad_m_axi_araddr_q;
    logic [7:0]  pad_m_axi_arlen_q;
    logic [2:0]  pad_m_axi_arsize_q;
    logic [1:0]  pad_m_axi_arburst_q;
    logic        pad_m_axi_arvalid_q;
    logic        pad_m_axi_rready_q;
    logic [31:0] pad_m_axi_awaddr_q;
    logic [7:0]  pad_m_axi_awlen_q;
    logic [2:0]  pad_m_axi_awsize_q;
    logic [1:0]  pad_m_axi_awburst_q;
    logic        pad_m_axi_awvalid_q;
    logic [63:0] pad_m_axi_wdata_q;
    logic [7:0]  pad_m_axi_wstrb_q;
    logic        pad_m_axi_wlast_q;
    logic        pad_m_axi_wvalid_q;
    logic        pad_m_axi_bready_q;

    always_ff @(posedge clk) begin
        pad_addr_q          <= cpu_addr_w;
        pad_dout_q          <= cpu_dout_w;
        pad_rw_q            <= cpu_rw_w;
        pad_busy_q          <= mem_busy_w;
        pad_m_axi_araddr_q  <= m_axi_araddr_w;
        pad_m_axi_arlen_q   <= m_axi_arlen_w;
        pad_m_axi_arsize_q  <= m_axi_arsize_w;
        pad_m_axi_arburst_q <= m_axi_arburst_w;
        pad_m_axi_arvalid_q <= m_axi_arvalid_w;
        pad_m_axi_rready_q  <= m_axi_rready_w;
        pad_m_axi_awaddr_q  <= m_axi_awaddr_w;
        pad_m_axi_awlen_q   <= m_axi_awlen_w;
        pad_m_axi_awsize_q  <= m_axi_awsize_w;
        pad_m_axi_awburst_q <= m_axi_awburst_w;
        pad_m_axi_awvalid_q <= m_axi_awvalid_w;
        pad_m_axi_wdata_q   <= m_axi_wdata_w;
        pad_m_axi_wstrb_q   <= m_axi_wstrb_w;
        pad_m_axi_wlast_q   <= m_axi_wlast_w;
        pad_m_axi_wvalid_q  <= m_axi_wvalid_w;
        pad_m_axi_bready_q  <= m_axi_bready_w;
    end

    assign pad_addr          = pad_addr_q;
    assign pad_data_out      = pad_dout_q;
    assign pad_rw            = pad_rw_q;
    assign pad_busy          = pad_busy_q;
    assign pad_m_axi_araddr  = pad_m_axi_araddr_q;
    assign pad_m_axi_arlen   = pad_m_axi_arlen_q;
    assign pad_m_axi_arsize  = pad_m_axi_arsize_q;
    assign pad_m_axi_arburst = pad_m_axi_arburst_q;
    assign pad_m_axi_arvalid = pad_m_axi_arvalid_q;
    assign pad_m_axi_rready  = pad_m_axi_rready_q;
    assign pad_m_axi_awaddr  = pad_m_axi_awaddr_q;
    assign pad_m_axi_awlen   = pad_m_axi_awlen_q;
    assign pad_m_axi_awsize  = pad_m_axi_awsize_q;
    assign pad_m_axi_awburst = pad_m_axi_awburst_q;
    assign pad_m_axi_awvalid = pad_m_axi_awvalid_q;
    assign pad_m_axi_wdata   = pad_m_axi_wdata_q;
    assign pad_m_axi_wstrb   = pad_m_axi_wstrb_q;
    assign pad_m_axi_wlast   = pad_m_axi_wlast_q;
    assign pad_m_axi_wvalid  = pad_m_axi_wvalid_q;
    assign pad_m_axi_bready  = pad_m_axi_bready_q;

endmodule

`default_nettype wire
