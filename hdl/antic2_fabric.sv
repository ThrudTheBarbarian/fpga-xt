// antic2_fabric.sv — the ACID-validated antic2 + a2_video pair behind
// antic_gtia-shaped ports (docs/antic-unification-plan.md, phase 1).
//
// The shell owns exactly the conversions the two worlds disagree on, each
// one already validated somewhere:
//   * mem handshake: the fabric answers a combinational address with
//     registered data one clock later; antic2 wants mem_req/mem_valid.
//     valid = req delayed one clock — a8_core's exact pattern.
//   * /NMI: antic2 emits a positive one-cycle pulse; the fabric consumes an
//     active-low level.  Stretched to NMI_LOW_TICKS phi2 ticks so every
//     every-clk edge detector sees it (the fid core samples each clk; the
//     external SALLY bus's nmi_gen used 256 — revisit at phase 3 when the
//     consumer set is final).
//   * RDY: rdy_n = wsync stall as a level.  antic2's wsync_take is already
//     write-aware (a write is never taken), so no `|| !rw` term here —
//     the same composition a8_core ships under ACID.
//   * last-thing-on-the-bus: antic2's virtual-playfield/phantom-P/M latch
//     wants the last byte ANY bus master drove.  ANTIC's own reads fold in
//     on mem_valid; the CPU side arrives via bus_byte/bus_byte_stb from the
//     fabric's snoop (phase 2 wires it; tied low it degrades to ANTIC-only
//     traffic, which is what the legacy raster modelled).
//   * tune: accepted so the GP0 bisect plumbing stays connected, but NOT
//     yet applied — antic2's constants are pinned by ACID.  If hardware
//     pacing disagrees with sim, the port becomes the bridge while the
//     offset is bisected (plan §risks); until then it must read as zero.
//
// No fabric instantiation yet — that is phase 2, parameter-gated.

`default_nettype none

module antic2_fabric #(
    parameter int NMI_LOW_TICKS = 8
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,          // accepted for port-compat; antic2 has no
                                      // cold-boot state beyond rst (registers
                                      // clear the same either way)
    input  wire        tick,          // phi2 machine-cycle pulse
    input  wire        px_tick,       // 4 hi-res pixels per machine cycle

    // ---- CPU bus ($D4xx + $D0xx) --------------------------------------
    input  wire        cs_antic,
    input  wire        cs_gtia,
    input  wire [7:0]  addr,
    input  wire        we,
    input  wire        cpu_writing,   // this bus cycle is a write (WSYNC rule)
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,

    // ---- to the CPU / bus authority ------------------------------------
    output wire        rdy_n,         // low = WSYNC stall
    output wire        nmi_n,         // low = NMI asserted (stretched level)
    output wire        dma_steal,     // level: ANTIC owns this cycle

    // ---- memory (bare fabric port: registered data, 1 clk) --------------
    output wire [15:0] mem_addr,
    input  wire [7:0]  mem_data,

    // ---- last-thing-on-the-bus (fabric snoop; see header) ---------------
    input  wire [7:0]  bus_byte,
    input  wire        bus_byte_stb,

    // ---- console / controllers ------------------------------------------
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,

    // ---- runtime bisect (accepted, not yet applied — see header) ---------
    input  wire [15:0] tune,

    // ---- video out (identical contract to antic_scanline) ----------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start,

    // ---- observability ---------------------------------------------------
    output wire [6:0]  hcount,
    output wire [8:0]  line,
    output wire [7:0]  vcount,
    output wire [7:0]  nmist_o
);

    // ---- antic2 <-> a2_video fabric ---------------------------------------
    wire        a2_nmi, a2_wsync_take;
    wire [7:0]  a2_rdata, gtia_rdata;
    wire        mem_req;
    logic       mem_valid;
    wire        px_wr, px_hires, px_in_window, px_line_start, px_active, px_collide;
    wire [2:0]  px_pf_src;
    wire [1:0]  px_val;
    wire [6:0]  px_hcount;
    wire [3:0]  px_mode;
    wire [8:0]  px_pos;
    wire        pm_we, pm_fetch;
    wire [2:0]  pm_obj;
    wire [7:0]  pm_data;

    // The fabric memory answers one clock after the address is presented.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) mem_valid <= 1'b0;
        else     mem_valid <= mem_req;
    end

    // Last byte on the bus: ANTIC's own reads fold in on the cycle their
    // data lands; the snooped CPU data phase arrives via bus_byte_stb.
    logic [7:0] last_bus;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)               last_bus <= 8'h00;
        else if (mem_valid)    last_bus <= mem_data;
        else if (bus_byte_stb) last_bus <= bus_byte;
    end

    antic2 #(
        .LINE_CYCLES(114), .LINES(262), .DISPLAY_TOP(8), .DISPLAY_BOTTOM(248)
    ) u_antic2 (
        .clk(clk), .rst(rst), .tick(tick), .tune(tune), .px_tick(px_tick),
        .cs(cs_antic), .we(we && cs_antic), .addr(addr[3:0]), .wdata(wdata),
        .rdata(a2_rdata), .cpu_writing(cpu_writing),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .bus_byte(last_bus),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data),
        .pm_fetch(pm_fetch),
        .mem_valid(mem_valid), .mem_req(mem_req),
        .nmi(a2_nmi), .wsync_take(a2_wsync_take), .dma_steal(dma_steal),
        .hcount(hcount), .line(line),
        .px_wr(px_wr), .px_pf_src(px_pf_src), .px_val(px_val),
        .px_hires(px_hires), .px_in_window(px_in_window),
        .px_hcount(px_hcount), .px_mode(px_mode),
        .px_pos(px_pos), .px_line_start(px_line_start),
        .px_active(px_active), .px_collide(px_collide),
        .vcount_o(vcount), .nmist_o(nmist_o)
    );

    a2_video u_a2_video (
        .clk(clk), .rst(rst), .px_tick(px_tick),
        .cs(cs_gtia), .we(we && cs_gtia), .addr(addr), .wdata(wdata),
        .rdata(gtia_rdata),
        .px_wr(px_wr), .px_pf_src(px_pf_src), .px_val(px_val),
        .px_hires(px_hires), .px_in_window(px_in_window),
        .px_hcount(px_hcount), .px_mode(px_mode),
        .px_pos(px_pos), .px_line_start(px_line_start),
        .px_active(px_active), .px_collide(px_collide),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data),
        .pm_fetch(pm_fetch),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .lb_wr(lb_wr), .lb_color(lb_color),
        .lb_line_start(lb_line_start)
    );

    assign rdata = cs_antic ? a2_rdata : gtia_rdata;

    // ---- /NMI pulse -> stretched active-low level -------------------------
    logic [$clog2(NMI_LOW_TICKS+1)-1:0] nmi_cnt;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)          nmi_cnt <= '0;
        else if (a2_nmi)  nmi_cnt <= NMI_LOW_TICKS[$bits(nmi_cnt)-1:0];
        else if (tick && nmi_cnt != '0) nmi_cnt <= nmi_cnt - 1'b1;
    end
    assign nmi_n = ~(a2_nmi || (nmi_cnt != '0));

    // ---- WSYNC stall as a level ------------------------------------------
    assign rdy_n = a2_wsync_take;

    // The bisect port is accepted but must stay inert until phase 3 (see
    // header).  Referenced so lint sees it consumed.
    wire _unused_tune = cold;

endmodule

`default_nettype wire
