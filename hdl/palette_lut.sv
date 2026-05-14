// palette_lut.sv — 256-entry Atari hue:luma → RGB888 lookup.
//
// The colour resolver hands an 8-bit Atari colour value (hue[7:4],
// luma[3:1], reserved bit 0) to the scan-out path. palette_lut maps
// those 256 codes to RGB888 — that's the actual pixel value going to
// the TMDS encoder / DVI buffer.
//
// Write path: $D483 PAL_R / $D484 PAL_G / $D485 PAL_B latch the
// channel bytes into antic_regs; $D486 PAL_IDX writes commit the
// latched {R,G,B} into entry pal_idx via a one-cycle write strobe.
// (pal_idx itself is bus-writeable — the addr is whatever the CPU
// just wrote to $D486.)
//
// Read latency is 1 clock — registered output on a synchronous BRAM.
// The default contents come from `INIT_FILE` at elaboration time
// (24-bit hex per line, 256 lines). Pass an empty string to leave the
// table at zero (the synthesis tool then optimises the BRAM into LUT
// init or leaves it black at power-on).
//
// Single-clock module; the integration adds CDC at its instantiation
// for cross-domain palette writes (antic_regs in clk_bus,
// palette_lut + scan_out in clk_pix).

`default_nettype none

module palette_lut #(
    parameter int    ADDR_W    = 8,
    parameter string INIT_FILE = ""
) (
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_W-1:0]     waddr,
    input  wire [23:0]           wdata,         // {R[7:0], G[7:0], B[7:0]}
    input  wire [ADDR_W-1:0]     raddr,
    output logic [23:0]          rdata
);

    (* syn_ramstyle = "block_ram" *)
    logic [23:0] mem [0:(1<<ADDR_W)-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end else begin
            for (int i = 0; i < (1<<ADDR_W); i = i + 1) mem[i] = 24'h0;
        end
    end

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule

`default_nettype wire
