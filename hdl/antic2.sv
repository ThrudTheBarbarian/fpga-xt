`default_nettype none
//
// antic2 — the from-scratch ANTIC, stage 1.
//
// Wires the four transcribed pieces together:
//
//   antic2_regs   $D400-$D40F, and the WSYNC RMW re-arm detected at the writes
//   antic2_dl     the display-list executor
//   antic2_line   start-of-line row / DL bookkeeping
//   antic2_seq    the per-machine-cycle sequence, in antic_tick's order
//
// plus antic_beam for the position counters, which is measured good standalone.
//
// ONE vcount, NOT TWO.  antic_beam also produces a vcount (line[8:1]), and it
// is NOT used here.  antic2_seq computes its own, because the software's has a
// ONE-CYCLE ROLLOVER WINDOW that a plain line[8:1] cannot express: +1 at cycle
// 111 of odd scanlines, CLEARED at 112 on the last line, so scanline 261
// momentarily reads 131.  antic_vcount's two rollover probes sit on the SAME
// scanline and differ only in read cycle -- 111 must read 131, 112 must read 0.
// Taking vcount from the beam as well would put two different definitions of the
// same register in one design, which is precisely the failure the previous
// rewrite spent weeks on ("104" meaning two different events in two files).
// Only hcount / line / line_start are taken from the beam.
//
// SCOPE: STAGE 1.  No playfield fetch and no render; DMA steal is REFRESH ONLY.
// The playfield map and its priority/slip rules are stage 2 and reuse
// antic_dma_sched, which is already measured correct end to end.
//
// Refresh is in stage 1 on purpose, and the reason is a scoping check worth
// keeping: the four gate tests all set DMACTL = $22, so DMA is on -- but they
// MEASURE at scanlines 2-7, inside vertical blank, where the playfield never
// fetches.  Refresh is the only thing stealing cycles there.  Without it the CPU
// runs nine cycles a line too fast and the gate cannot pass however correct the
// rest is; with it, and with no playfield to contend against, there is nothing
// to arbitrate.
//
`timescale 1ns/1ps

module antic2 #(
    parameter int LINE_CYCLES    = 114,
    parameter int LINES          = 262,
    parameter int DISPLAY_TOP    = 8,
    parameter int DISPLAY_BOTTOM = 248
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,               // phi2

    // ---- CPU register port -------------------------------------------------
    input  wire        cs,                 // $D4xx
    input  wire        we,
    input  wire [3:0]  addr,
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,
    input  wire        cpu_writing,

    // ---- memory (display-list fetch) ---------------------------------------
    output wire [15:0] mem_addr,
    input  wire [7:0]  mem_data,
    input  wire        mem_valid,
    output wire        mem_req,

    // ---- to the CPU / rest of the machine ----------------------------------
    output wire        nmi,                // ONE-CYCLE PULSE
    output wire        wsync_take,         // ANTIC takes this cycle for WSYNC
    output wire        dma_steal,          // stage 1: memory refresh only
    output wire [6:0]  hcount,
    output wire [8:0]  line
);

    wire        line_start;
    wire [7:0]  dmactl, chactl, hscrol, vscrol;
    wire        dlist_lo_stb, dlist_hi_stb;
    wire [7:0]  dlist_val;
    wire [7:0]  pmbase, chbase, nmien;
    wire [7:0]  nmist, vcount;
    wire        wsync_stb, wsync_rmw_readd, nmires_stb;
    wire        row_ends, dli_line, dli_fired_set;
    wire [7:0]  dl_insn;
    wire [3:0]  row_line;
    wire        dl_done, row_first, jvb_pulse;
    wire        dl_fetch_req;
    wire [3:0]  dl_row_end;
    wire        dl_row_end_live;
    wire [3:0]  dl_row_line_load;
    wire        dl_row_line_set;
    wire        dl_busy;
    wire [15:0] dl_addr_o, pf_addr_o;
    wire [4:0]  mode_rows;

    // ---- position ----------------------------------------------------------
    antic_beam #(
        .CYCLES_PER_LINE(LINE_CYCLES), .LINES_PER_FRAME(LINES),
        .DISPLAY_TOP(DISPLAY_TOP)
    ) u_beam (
        .clk(clk), .rst(rst), .tick(tick), .vcount_adv(7'd111),
        .hcount(hcount), .line(line), .vcount(),          // NOT used -- see header
        .line_start(line_start), .in_display(), .in_vblank(), .vbi_line()
    );

    // ---- registers ---------------------------------------------------------
    antic2_regs u_regs (
        .clk(clk), .rst(rst), .tick(tick),
        .cs(cs), .we(we), .addr(addr), .wdata(wdata),
        .nmist_in(nmist), .vcount_in(vcount),
        .dmactl(dmactl), .chactl(chactl),
        .dlist_lo_stb(dlist_lo_stb), .dlist_hi_stb(dlist_hi_stb),
        .dlist_val(dlist_val),
        .hscrol(hscrol), .vscrol(vscrol), .pmbase(pmbase), .chbase(chbase),
        .nmien(nmien), .rdata(rdata),
        .wsync_stb(wsync_stb), .wsync_rmw_readd(wsync_rmw_readd),
        .nmires_stb(nmires_stb)
    );

    // ---- the mode's natural row height -------------------------------------
    antic_mode_tbl u_mode (
        .mode(dl_insn[3:0]),
        .is_char(), .bpp(), .px_width(), .rows(mode_rows),
        .descender(), .is_display()
    );

    // ---- display-list executor ---------------------------------------------
    antic2_dl u_dl (
        .clk(clk), .rst(rst),
        .exec_req(dl_fetch_req),
        .mem_data(mem_data), .mem_valid(mem_valid),
        .mem_req(mem_req), .mem_addr(mem_addr),
        .dlist_lo_stb(dlist_lo_stb), .dlist_hi_stb(dlist_hi_stb),
        .dlist_val(dlist_val),
        .vscrol(vscrol), .mode_rows(mode_rows),
        .dl_insn(dl_insn), .dl_addr(dl_addr_o), .pf_addr(pf_addr_o),
        .row_end(dl_row_end), .row_end_live(dl_row_end_live),
        .row_line_load(dl_row_line_load), .row_line_set(dl_row_line_set),
        .jvb_pulse(jvb_pulse), .busy(dl_busy)
    );

    // ---- start-of-line bookkeeping -----------------------------------------
    antic2_line #(
        .DISPLAY_TOP(DISPLAY_TOP), .DISPLAY_BOTTOM(DISPLAY_BOTTOM)
    ) u_line (
        .clk(clk), .rst(rst), .line_start(line_start),
        .scanline(line), .dmactl(dmactl), .row_ends_in(row_ends),
        .dl_fetch_req(dl_fetch_req), .jvb_pulse(jvb_pulse),
        .row_line(row_line), .dl_done(dl_done), .row_first(row_first)
    );

    // The row's last scanline, resolved NOW.  `row_end_live` is emu's -1: the
    // comparison is against VSCROL AS IT STANDS AT THIS INSTANT, not against a
    // height latched when the instruction was fetched.  antic_vscroldli moves a
    // VSCROL write one cycle either side of the compare and requires the row's
    // end -- and the following DLI -- to move with it.
    wire [3:0] row_last = dl_row_end_live ? vscrol[3:0] : dl_row_end;

    // `dli_fired` holder.  antic2_seq raises dli_fired_set when a DLI is taken;
    // the flag suppresses a RE-FIRE in vertical blank (antic_hiresbug) while
    // still allowing a FIRST firing outside the display region
    // (antic_dlistwrap #1).  Cleared once per frame.
    logic dli_fired;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                                  dli_fired <= 1'b0;
        else if (line_start && (line == 9'd0))    dli_fired <= 1'b0;
        else if (dli_fired_set)                   dli_fired <= 1'b1;
    end

    // ---- memory refresh ----------------------------------------------------
    //
    // NINE cycles at 25, 29 .. 57, on EVERY scanline, whatever DMACTL says.  The
    // CPU never gets them even with the screen off.  emu builds this before any
    // playfield work (line_start calls antic_dma_refresh unconditionally), and
    // omitting it let the CPU run nine cycles a line too fast whenever DMA was
    // off -- gtia_pmretrigger's fourth case, whose `sta hposp0` landed on cycle
    // 81 against an annotated 90.
    //
    // STAGE 1 NEEDS THIS AND NOTHING ELSE OF THE DMA SCHEDULE, which is why it
    // is here rather than waiting for antic_dma_sched.  The four gate tests
    // (antic_vcount, antic_nmist, antic_dlitiming, antic_blockednmi) all run with
    // DMACTL = $22, but they MEASURE at scanlines 2-7 -- inside vertical blank,
    // where the playfield never fetches.  Refresh is the only thing stealing
    // there, and with no playfield there is no contention to arbitrate: it
    // simply takes its nine cycles.  The priority and slip rules come with the
    // playfield in stage 2.
    localparam int REFRESH_FIRST = 25;
    localparam int REFRESH_STEP  = 4;
    localparam int REFRESH_COUNT = 9;

    wire refresh_steal =
        (hcount >= 7'(REFRESH_FIRST)) &&
        (hcount <= 7'(REFRESH_FIRST + (REFRESH_COUNT-1)*REFRESH_STEP)) &&
        (((hcount - 7'(REFRESH_FIRST)) % 7'(REFRESH_STEP)) == 7'd0);

    assign dma_steal = refresh_steal;

    // ---- the per-cycle sequence --------------------------------------------
    antic2_seq #(
        .LINE_CYCLES(LINE_CYCLES), .DISPLAY_TOP(DISPLAY_TOP),
        .DISPLAY_BOTTOM(DISPLAY_BOTTOM), .LINES(LINES)
    ) u_seq (
        .clk(clk), .rst(rst), .tick(tick),
        .cycle(hcount), .scanline(line),
        .row_line(row_line), .row_last(row_last),
        .dl_insn_dli(dl_insn[7]), .dli_fired(dli_fired),
        .dli_fired_set(dli_fired_set),
        .nmien(nmien), .nmires_stb(nmires_stb),
        .wsync_stb(wsync_stb), .wsync_rmw_readd(wsync_rmw_readd),
        .cpu_writing(cpu_writing),
        .nmist(nmist), .vcount(vcount), .nmi(nmi),
        .wsync_take(wsync_take), .row_ends(row_ends), .dli_line(dli_line)
    );

endmodule

`default_nettype wire
