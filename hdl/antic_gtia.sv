`default_nettype none
//
// antic_gtia — the pair of chips, as one addressable block.
//
// docs/ANTIC-rewrite.md.  Beam, registers and raster path wired together behind
// a CPU bus.  This is the point the rewrite becomes something a 6502 can talk
// to rather than a collection of modules with testbenches: everything below is
// driven by register writes at $D0xx and $D4xx and answers on the same bus.
//
// THE TWO CHIPS ARE ONE MODULE HERE, WHICH THE REAL MACHINE IS NOT.  On an
// Atari they are separate packages joined by the AN0-AN2 lines, and the split
// matters for exactly one thing this design cares about: ANTIC decides what the
// playfield IS and GTIA decides what colour it comes out.  That boundary is kept
// inside — antic_line_render publishes a playfield SOURCE and gtia_stage
// resolves it — so putting them in one wrapper costs nothing and saves plumbing
// two sets of registers through the top level.
//
// WHAT THE CPU SEES
//   cs_antic + addr[3:0]   $D400-$D4FF, sixteen registers mirrored sixteen times
//   cs_gtia  + addr[4:0]   $D000-$D0FF, thirty-two mirrored eight times
//   rdy_n                  WSYNC is holding the CPU
//   nmi_n                  a DLI or VBI is being delivered
//   dma_steal              this machine cycle belongs to ANTIC, not the CPU
//
// dma_steal and rdy_n are separate on purpose and are not the same thing.
// A stolen cycle is ANTIC using the bus for its own fetch; WSYNC is the CPU
// asking to be parked until the end of the line.  A core needs both, for
// different reasons, and antic_dmapattern and antic_wsync test them apart.
//
// TIMING COMES IN, NOT OUT.  `tick` and `px_tick` are generated outside — one
// machine cycle and one hi-res pixel respectively, four of the latter to each of
// the former.  Keeping the divider outside means this module has no opinion
// about the fabric clock, and the testbenches can run it at the real 56:1 ratio
// or a compressed one as suits them.
//
`timescale 1ns/1ps

module antic_gtia #(
    parameter int CYCLES_PER_LINE = 114,
    parameter int LINES_PER_FRAME = 262,
    parameter int DISPLAY_TOP     = 8,
    parameter int DISPLAY_LINES   = 240
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,

    // ---- timing ----------------------------------------------------------
    input  wire        tick,            // 1-clk per machine cycle
    input  wire        px_tick,         // 1-clk per hi-res pixel

    // ---- CPU bus ---------------------------------------------------------
    input  wire        cs_antic,        // $D4xx
    input  wire        cs_gtia,         // $D0xx
    input  wire [7:0]  addr,
    input  wire        we,
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,

    // ---- to the CPU ------------------------------------------------------
    output wire        rdy_n,           // WSYNC is holding it
    output wire        nmi_n,           // active low
    output wire        dma_steal,       // ANTIC has this machine cycle

    // ---- ANTIC's memory port ---------------------------------------------
    output wire [15:0] mem_addr,
    input  wire [7:0]  mem_data,

    // ---- console and controller inputs -----------------------------------
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,

    // ---- the scanline out ------------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start,

    // ---- observability ---------------------------------------------------
    output wire [6:0]  hcount,
    output wire [8:0]  line,
    output wire [7:0]  vcount,
    output wire        line_start,
    output wire [15:0] dlpc,
    // NMIST as the register file serves it.  Exposed alongside vcount because
    // whoever holds timing authority must also answer the CPU's VCOUNT/NMIST
    // reads: served from the far side of the hwreg read CDC they come back a
    // round-trip stale, which is fatal to the cycle-accurate tests
    // (antic_vcount measures the exact cycle VCOUNT steps on).
    output wire [7:0]  nmist_o
);

    // ---- the beam --------------------------------------------------------
    wire in_display, in_vblank, vbi_line;

    antic_beam #(
        .CYCLES_PER_LINE(CYCLES_PER_LINE), .LINES_PER_FRAME(LINES_PER_FRAME),
        .DISPLAY_TOP(DISPLAY_TOP), .DISPLAY_LINES(DISPLAY_LINES)
    ) u_beam (
        .clk(clk), .rst(rst), .tick(tick),
        .hcount(hcount), .line(line), .vcount(vcount),
        .line_start(line_start), .in_display(in_display),
        .in_vblank(in_vblank), .vbi_line(vbi_line)
    );

    // ---- ANTIC's registers -----------------------------------------------
    wire [7:0] a_rdata;
    wire [7:0] dmactl, chactl, hscrol, vscrol, pmbase, chbase, nmien;
    wire       dlist_we_l, dlist_we_h, nmires;
    wire [7:0] dlist_wdata;
    wire [7:0] nmist;
    assign nmist_o = nmist;

    antic_reg_file u_aregs (
        .clk(clk), .rst(rst), .tick(tick), .hcount(hcount),
        .addr(addr), .we(we && cs_antic), .wdata(wdata), .rdata(a_rdata),
        .vcount(vcount), .nmist(nmist),
        .dmactl(dmactl), .chactl(chactl), .hscrol(hscrol), .vscrol(vscrol),
        .pmbase(pmbase), .chbase(chbase), .nmien(nmien),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata), .nmires(nmires), .rdy_n(rdy_n)
    );

    // ---- GTIA's registers -------------------------------------------------
    wire [7:0] g_rdata;
    wire [7:0] hposp0, hposp1, hposp2, hposp3;
    wire [7:0] hposm0, hposm1, hposm2, hposm3;
    wire [1:0] sizep0, sizep1, sizep2, sizep3;
    wire [7:0] sizem, grafp0, grafp1, grafp2, grafp3, grafm;
    wire [7:0] colpm0, colpm1, colpm2, colpm3;
    wire [7:0] colpf0, colpf1, colpf2, colpf3, colbk;
    wire [7:0] prior, vdelay, gractl;
    wire       hitclr;

    wire        pm_we;
    wire [2:0]  pm_obj;
    wire [7:0]  pm_data, pm_mask;
    wire [15:0] m_pf, p_pf, m_pl, p_pl;

    gtia_reg_file u_gregs (
        .clk(clk), .rst(rst),
        .addr(addr), .we(we && cs_gtia), .wdata(wdata), .rdata(g_rdata),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data), .pm_mask(pm_mask),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk(colbk), .prior(prior), .vdelay(vdelay), .gractl(gractl),
        .hitclr(hitclr)
    );

    // One of the two chips answers, never both — they are decoded from
    // different pages.
    assign rdata = cs_antic ? a_rdata : cs_gtia ? g_rdata : 8'hFF;

    // ---- the raster path ---------------------------------------------------
    antic_scanline u_sl (
        .clk(clk), .rst(rst), .cold(cold),
        .line_start(line_start), .tick(tick), .px_tick(px_tick),
        .hcount(hcount), .line(line), .in_vblank(in_vblank),
        .vbi_line(vbi_line),
        .dmactl(dmactl), .chactl(chactl[2:0]),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata),
        .hscrol(hscrol[3:0]), .vscrol(vscrol[3:0]),
        .chbase(chbase), .pmbase(pmbase),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm), .prior(prior),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .nmien(nmien), .nmires(nmires),
        .vdelay(vdelay), .hitclr(hitclr),
        // GTIA does not compare during vertical blank; that gate is per LINE.
        .active_line(in_display),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data), .pm_mask(pm_mask),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl),
        .dma_steal(dma_steal), .nmist(nmist), .nmi_n(nmi_n),
        .dli(), .dlpc(dlpc)
    );

endmodule

`default_nettype wire
