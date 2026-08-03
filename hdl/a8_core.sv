`default_nettype none
//
// a8_core — the CPU and the display chips, joined.
//
// docs/ANTIC-rewrite.md.  xt6502f plus antic_gtia, with the two things that
// actually connect them: the register decode and the cycle stealing.
//
// TWO MEMORY PORTS, NOT AN ARBITER — AND THAT IS WRONG.  The reasoning below is
// kept because it is nearly right, and because knowing WHY it fails is the
// point:
//
//   "ANTIC and the CPU each get their own read path, because on the FPGA the
//    memory is dual-ported and there is no bus to contend for.  The CPU still
//    loses the cycles — `dma_steal` gates its clock enable — so the TIMING is
//    the real machine's even though the physical conflict the real machine has
//    does not exist here.  That is the right trade: the timing is what software
//    can observe, and the contention is not."
//
// The last clause is false, and the software model names the counter-example.
// GTIA's phantom P/M latch captures WHATEVER VALUE IS ON THE DATA BUS at fixed
// scanline slots, whether or not ANTIC fetched anything there.  gtia_phantomdma
// sets DMACTL=$21 so ANTIC does no P/M DMA at all, and the byte it requires in
// GRAFP0 is $AD — the opcode fetch of the test's own `lda $0100`.  Nothing ANTIC
// touches on that line ends in $D.
//
// So the bus VALUE is a third-party observable, not an internal detail, and two
// independent read ports cannot reproduce it: ANTIC never sees the CPU's fetch.
// The bus must be SINGLE and ARBITRATED with ANTIC as master, and the value on
// it exported to GTIA.  See emu/system.c bus_note()/phantom_latch(), which is
// the model that passes gtia_phantomdma.
//
// RDY AND HALT ARE DIFFERENT SIGNALS AND ARE COMPOSED DIFFERENTLY.  This is the
// whole reason Atari built SALLY instead of using a stock 6502:
//
//   WSYNC -> RDY    standard 6502 behaviour, and a WRITE CANNOT BE STALLED.
//                   The CPU is driving the bus during a write and cannot let
//                   go, so the write completes and the stall begins after it.
//
//   DMA   -> HALT   Atari's addition, and it is UNCONDITIONAL.  A stock 6502's
//                   RDY cannot stop a write, so ANTIC could never be sure of
//                   getting the cycle it needs; SALLY's HALT can, which is what
//                   makes a fixed DMA schedule possible at all.
//
// Getting these the same way round is a silent-corruption bug: make HALT
// write-immune and ANTIC misses fetches only when the CPU happens to be
// storing, which is data-dependent and would look like random display glitches.
//
// THE DELAY SLOTS DIFFER TOO, and for the same reason.  /RDY trails the WSYNC
// latch by a machine cycle because the latch is inside ANTIC (see
// antic_reg_file); `dma_steal` applies in the cycle it names, because that is
// ANTIC taking the bus now rather than a request propagating.
//
// rdy IS A LEVEL HERE, NOT A PULSE, and that distinction is per-core.  The turbo
// core takes rdy as its clock enable and needs a pulse; the fid core paces
// itself from phi2_tick and samples rdy as a level at its commit slot, so
// ANDing phi2_tick into it stalls the machine permanently — it never reaches a
// commit with rdy high and sits on the reset vector for ever.
//
// The memory write is strobed at SUB_DATA (N-7 subcycles into the window),
// which is where the fid core presents write data.  Strobing on the level
// instead would write every fabric clock of the cycle.
//
`timescale 1ns/1ps

module a8_core #(
    parameter int unsigned CLK_HZ  = 100_000_000,
    parameter int unsigned PHI2_HZ = 1_785_714
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,

    input  wire        tick,            // phi2, one machine cycle
    input  wire        px_tick,         // one hi-res pixel

    // Timing tune, straight through to antic_gtia (GP0 CTRL_RWTUNE on HW).
    // tune = 0 is exactly the parameter defaults.  Exposed as a PORT because
    // antic_wsync cannot see the absolute WSYNC release cycle (see 124e88e) --
    // antic_vcount can, and sweeping tune[11:8] against it is the only way to
    // measure that axis.  SystemVerilog has no default values on module input
    // ports, so every instantiation must drive this.
    input  wire [15:0] tune,

    // ---- CPU memory port -------------------------------------------------
    output wire [15:0] cpu_addr,
    output wire [7:0]  cpu_wdata,
    output wire        cpu_we,
    input  wire [7:0]  cpu_rdata,       // memory only; registers are muxed here

    // ---- ANTIC's own read port -------------------------------------------
    output wire [15:0] antic_addr,
    input  wire [7:0]  antic_rdata,

    // ---- interrupts ------------------------------------------------------
    input  wire        irq_n,

    // ---- console and controllers -----------------------------------------
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,

    // ---- the scanline out ------------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start,

    // ---- observability ---------------------------------------------------
    output wire        dma_steal,
    output wire        rdy_n,
    output wire        nmi_n,
    output wire        sync,
    output wire [15:0] dbg_pc,
    output wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p,
    output wire [6:0]  hcount,
    output wire [8:0]  line
);

    // ---- the CPU ----------------------------------------------------------
    wire [15:0] c_addr;
    wire [7:0]  c_dout;
    wire        c_rw;                    // 1 = read, 0 = write
    logic [7:0] c_din;
    wire        c_rdy;
    wire [7:0]  c_sub;                   // the core's subcycle position

    localparam int unsigned N        = CLK_HZ / PHI2_HZ;
    localparam int unsigned SUB_DATA = N - 7;

    assign cpu_addr  = c_addr;
    assign cpu_wdata = c_dout;
    assign cpu_we    = !c_rw && c_rdy && (c_sub == 8'(SUB_DATA));

    // $D000-$D0FF is GTIA, $D400-$D4FF is ANTIC.
    wire cs_gtia  = (c_addr[15:8] == 8'hD0);
    wire cs_antic = (c_addr[15:8] == 8'hD4);
    wire [7:0] reg_rdata;

    always_comb begin
        if (cs_gtia || cs_antic) c_din = reg_rdata;
        else                     c_din = cpu_rdata;
    end

    xt6502f u_cpu (
        .clk(clk), .rst(rst), .phi2_tick(tick),
        .addr(c_addr), .data_in(c_din), .data_out(c_dout), .rw(c_rw),
        .rdy(c_rdy),
        .irq_n(irq_n), .nmi_n(nmi_n),
        .sync(sync), .dbg_pc(dbg_pc),
        .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .dbg_sub(c_sub), .dbg_ir(),
        .dbg_load(1'b0), .dbg_pc_in(16'h0000)
    );

    // ---- the display chips -------------------------------------------------
    antic_gtia u_video (
        .tune(tune),
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick),
        .cs_antic(cs_antic), .cs_gtia(cs_gtia),
        .addr(c_addr[7:0]), .we(cpu_we), .wdata(c_dout), .rdata(reg_rdata),
        .rdy_n(rdy_n), .nmi_n(nmi_n), .dma_steal(dma_steal),
        .mem_addr(antic_addr), .mem_data(antic_rdata),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .hcount(hcount), .line(line), .vcount(), .line_start(), .dlpc()
    );

    // ---- the halt composition -----------------------------------------------
    // HALT is unconditional; WSYNC's RDY cannot stall a write.  A LEVEL, not a
    // pulse: the fid core is paced by phi2_tick and samples this at its commit
    // slot.
    wire halt_n   = !dma_steal;
    wire wsync_ok = !rdy_n || !c_rw;

    assign c_rdy = halt_n && wsync_ok;

endmodule

`default_nettype wire
