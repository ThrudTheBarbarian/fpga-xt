// bus_snoop.sv — production snoop pipeline.
//
// Samples {A, D, R/W, /D0xx, /D4xx} on every rising bus_clk and
// produces registered write-enables to the appropriate downstream
// consumer. There are no SALLY-driven /ANTIC_* tag CS lines —
// fpga-antic does its own region classification in fabric using the
// ANTIC register state it already holds. See docs/wire-protocol.md
// § "No /ANTIC_* tag CS lines".
//
// snoop_we_screen fires on every CPU write to system RAM (i.e. any
// write outside the $D000-$D7FF hardware page, with /D0xx and /D4xx
// both high). Whether that write is "interesting" (DL, charset, PM,
// screen RAM) is decided downstream by the compositor, which reads
// cpu_shadow at the offsets it needs.

`default_nettype none

module bus_snoop (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] bus_addr,
    input  wire [7:0]  bus_data_in,
    input  wire        bus_rw,            // 1 = read, 0 = write

    input  wire        d0xx_n,
    input  wire        d4xx_n,

    // Registered cycle capture (1-cycle latency from bus sample).
    output logic [15:0] snoop_addr,
    output logic [7:0]  snoop_data,

    // Write-side enables — set on the cycle bus_clk rises after the
    // matching cycle was sampled.
    output logic        snoop_we_gtia,     // /D0xx low + R/W=0
    output logic        snoop_we_antic,    // /D4xx low + R/W=0
    output logic        snoop_we_pokey_l,  // $D2xx with addr[4]=0 + R/W=0 (left/POKEY1)
    output logic        snoop_we_pokey_r,  // $D2xx with addr[4]=1 + R/W=0 (right/POKEY2 — stereo)
    output logic        snoop_we_cache,    // $D380-$D3FF (PIA-mirror window) + R/W=0
    output logic        snoop_we_pia,      // $D300-$D37F (real PIA window) + R/W=0
    output logic        snoop_we_screen,   // generic system-RAM write

    // Read-side enables — for diagnostic counters / tracing.
    output logic        snoop_re_gtia,     // /D0xx low + R/W=1
    output logic        snoop_re_antic,    // /D4xx low + R/W=1
    output logic        snoop_re_pokey_l,  // $D2xx with addr[4]=0 + R/W=1
    output logic        snoop_re_pokey_r,  // $D2xx with addr[4]=1 + R/W=1
    output logic        snoop_re_cache     // $D380-$D3FF + R/W=1
);

    // Combinational classification of the live bus sample.
    wire d0xx_active = ~d0xx_n;
    wire d4xx_active = ~d4xx_n;
    wire is_write    = ~bus_rw;
    wire is_read     =  bus_rw;

    // POKEY at $D2xx and PIA at $D3xx have no dedicated page-select
    // pins (those existed only for the original GTIA / ANTIC chips).
    // We decode internally from the address. POKEY moves into the
    // FPGA at M23.
    //
    // Stereo POKEY: the 130XE-style mod places a second POKEY at
    // $D21x. POKEY mirrors every 16 bytes within $D200-$D2FF, so the
    // stereo decoding is by bit 4 of the address — even mirrors
    // ($D200, $D220, $D240, ...) hit the left chip and odd mirrors
    // ($D210, $D230, $D250, ...) hit the right chip.
    wire d2xx_active   = (bus_addr[15:8] == 8'hD2);
    wire pokey_l_active = d2xx_active & ~bus_addr[4];   // $D20x, $D22x, ...
    wire pokey_r_active = d2xx_active &  bus_addr[4];   // $D21x, $D23x, ...

    // PIA itself ($D300-$D37F) and the cache-control mirror window
    // ($D380-$D3FF) both live in the $D3 page. We split them by
    // address bit 7 — xtc software hits cache_regs at $D380+, the
    // real PIA registers ($D300-$D303 + mirrors every 4 bytes through
    // $D37F) hit pia_regs.
    wire d3xx_active  = (bus_addr[15:8] == 8'hD3);
    wire pia_active   = d3xx_active & ~bus_addr[7];
    wire cache_active = d3xx_active &  bus_addr[7];

    // System-RAM write filter: not /D0xx, not /D4xx, and address not
    // in $D000-$D7FF. The address-range check excludes the rest of
    // the hardware page ($D2xx POKEY, $D3xx PIA, $D5xx-$D7xx
    // syscontroller) without needing dedicated page-select pins.
    wire in_hw_page = (bus_addr[15:11] == 5'b11010);  // $D000-$D7FF
    wire is_sys_ram_write = is_write
                          & ~d0xx_active
                          & ~d4xx_active
                          & ~in_hw_page;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            snoop_addr        <= 16'h0;
            snoop_data        <= 8'h0;
            snoop_we_gtia     <= 1'b0;
            snoop_we_antic    <= 1'b0;
            snoop_we_pokey_l  <= 1'b0;
            snoop_we_pokey_r  <= 1'b0;
            snoop_we_cache    <= 1'b0;
            snoop_we_pia      <= 1'b0;
            snoop_we_screen   <= 1'b0;
            snoop_re_gtia     <= 1'b0;
            snoop_re_antic    <= 1'b0;
            snoop_re_pokey_l  <= 1'b0;
            snoop_re_pokey_r  <= 1'b0;
            snoop_re_cache    <= 1'b0;
        end else begin
            snoop_addr <= bus_addr;
            snoop_data <= bus_data_in;

            snoop_we_gtia    <= d0xx_active    & is_write;
            snoop_we_antic   <= d4xx_active    & is_write;
            snoop_we_pokey_l <= pokey_l_active & is_write;
            snoop_we_pokey_r <= pokey_r_active & is_write;
            snoop_we_cache   <= cache_active   & is_write;
            snoop_we_pia     <= pia_active     & is_write;
            snoop_we_screen  <= is_sys_ram_write;

            snoop_re_gtia    <= d0xx_active    & is_read;
            snoop_re_antic   <= d4xx_active    & is_read;
            snoop_re_pokey_l <= pokey_l_active & is_read;
            snoop_re_pokey_r <= pokey_r_active & is_read;
            snoop_re_cache   <= cache_active   & is_read;
        end
    end

endmodule

`default_nettype wire
