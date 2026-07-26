// display_shadow.sv — display-side shadow copy of the CPU's flat 64 KB.
//
// Write port (clk_cpu = clk_sally): mirrors sally_mem's single BRAM write
// site (CPU stores + the A9 ROM-load port both funnel through
// mem_we/mem_addr_w/mem_din_w there — tapping that one site is complete
// writer coverage by construction).  The mirror inputs arrive REGISTERED
// one clk_cpu behind the main array, which decouples the two BRAMs'
// placement; a one-cycle shadow lag is invisible at scanline granularity.
//
// Read port (clk_disp = clk_sys): dedicated to the COMPOSITOR.  Registered
// 1-cycle read, no handshake — mem_read_mux consumes it in plain-BRAM
// snoop mode (sh_ready tied 1).  dl_parser keeps sally_mem's original
// dma port (vacated by the compositor), so bram_shim's read arbitration
// — and its whole cross-port staleness bug class — is gone.
//
// The RAMB's two independent port clocks are the only CDC, exactly like
// sally_mem's dma port: no FIFOs, no backpressure, no divergence risk.

`default_nettype none

module display_shadow (
    // Mirror-write side (clk_sally).
    input  wire        clk_cpu,
    input  wire        mir_we,
    input  wire [15:0] mir_addr,
    input  wire [7:0]  mir_din,

    // Timing-machine DL-fetch read, SAME PORT (clk_sally): the port reads
    // whenever it is not mirror-writing.  The consumer (antic_timing) holds
    // its address for a whole 56-clk machine cycle and samples at the end;
    // mirror writes occupy at most one clk per cycle, so the read always
    // lands.  This turns the inferred SDP into a TDP RAMB — same fabric.
    input  wire [15:0] tm_addr,
    output wire [7:0]  tm_data,

    // Display read side (clk_sys).
    input  wire        clk_disp,
    input  wire [15:0] rd_addr,
    output wire [7:0]  rd_data
);

    logic [7:0] mem [0:65535];

    logic [7:0] tm_q;
    always_ff @(posedge clk_cpu) begin
        if (mir_we) mem[mir_addr] <= mir_din;
        else        tm_q <= mem[tm_addr];
    end
    assign tm_data = tm_q;

    logic [7:0] rd_q;
    always_ff @(posedge clk_disp) begin
        rd_q <= mem[rd_addr];
    end
    assign rd_data = rd_q;

endmodule

`default_nettype wire
