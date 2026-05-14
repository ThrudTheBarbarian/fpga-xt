// cache_line_ram_synth_top.sv — pad-registered wrapper around
// cache_line_ram for standalone synth verification.
//
// All ports register at the I/O boundary so map.rpt's resource and
// timing numbers reflect the BRAM inference inside cache_line_ram,
// not pad-to-flop path delays.
//
// Run with:
//
//     TOP=cache_line_ram_synth_top ./efinity/run.sh map
//
// then check `efinity/build/outflow/cache_line_ram_synth_top.map.rpt`.
// At WORD_BYTES=4 / DEPTH=256, the expected resource line is:
//
//     EFX_LUT4: 16
//     EFX_FF  : 79
//     EFX_RAM10: 2
//
// = 2 BRAMs (16-bit aspect each, in parallel) + a 4:1 byte mux on the
// read path. Other WORD_BYTES configurations (1, 2, 4, 8) can be
// validated by tweaking the parameter — and the pad widths below.

`default_nettype none

module cache_line_ram_synth_top (
    input  wire        clk,
    input  wire        rst,
    input  wire [9:0]  pad_raddr,    // byte address into 1024 bytes
    input  wire        pad_re,
    input  wire [7:0]  pad_waddr,    // word address (256 × 4-byte words)
    input  wire [3:0]  pad_we_mask,  // per-lane write enable
    input  wire [31:0] pad_wdata,
    output wire [7:0]  pad_rdata
);

    logic [9:0]  raddr_q;
    logic        re_q;
    logic [7:0]  waddr_q;
    logic [3:0]  we_mask_q;
    logic [31:0] wdata_q;
    logic [7:0]  rdata_w;
    logic [7:0]  rdata_q;

    always_ff @(posedge clk) begin
        raddr_q   <= pad_raddr;
        re_q      <= pad_re;
        waddr_q   <= pad_waddr;
        we_mask_q <= pad_we_mask;
        wdata_q   <= pad_wdata;
        rdata_q   <= rdata_w;
    end

    cache_line_ram #(.WORD_BYTES(4), .DEPTH(256)) u_probe (
        .clk     (clk),
        .re      (re_q),
        .raddr   (raddr_q),
        .rdata   (rdata_w),
        .we_mask (we_mask_q),
        .waddr   (waddr_q),
        .wdata   (wdata_q)
    );

    assign pad_rdata = rdata_q;

endmodule

`default_nettype wire
