`default_nettype none
//
// antic_scanline — one scanline, end to end.
//
// docs/ANTIC-rewrite.md.  This is where the pieces meet: the beam says where we
// are, antic_dl says what to draw, antic_pf_geom says where it goes, antic_pf_fetch
// gets the bytes and antic_line_render turns them into colours.  It owns nothing
// itself except the sequencing and the window comparison.
//
// THE WINDOW COMPARISON IS THE WHOLE POINT.  Every hi-res pixel, the beam's live
// position is compared against antic_pf_geom's live output — which is
// combinational on DMACTL and HSCROL.  A write to either partway along a
// scanline therefore moves the playfield edge partway along that scanline.
// That is antic_pfstarttiming, antic_pfstoptiming and antic_hscrolbug, none of
// which the old burst renderer could express at any price.
//
// EVERY PIXEL OF THE LINE IS WRITTEN, not just the playfield.  Outside the
// window the background colour goes down instead, which is where the border
// comes from and keeps the line buffer's write pointer in step with the beam
// without a separate address.  One mux.
//
// THE ORDER WITHIN A SCANLINE is: display list at line_start, then the whole
// playfield fetch, then emission paced by the beam.  There is a lot of room —
// the display list costs ~10 fabric clocks and the widest fetch ~200, against
// the ~1,100 clocks between line_start and the earliest display start.  What
// this does NOT yet model is WHICH machine cycle each fetch steals from the CPU;
// that is the DMA schedule, and it arrives with antic_dmapattern.
//
// MEMORY IS SHARED BY STRICT HANDOFF, not arbitration.  Ownership passes down a
// chain once per scanline: display list, then player/missile DMA, then the
// playfield fetch.  None can overlap — the P/M fetch cannot start until the line
// is known and the playfield fetch cannot start until its byte count is — so a
// chain is all that is needed and there is nothing to arbitrate.
//
// GTIA RUNS TWO COLOUR CLOCKS BEHIND THE BEAM, and the line buffer is rewound
// two colour clocks late to match.  The reason is structural, not a fudge:
//
//   * a colour clock's PAIR of playfield pixels is not complete until its second
//     hi-res pixel has been emitted, so gtia_stage cannot start on colour clock
//     N until N+1 begins;
//   * the stage needs 26 of the 28 fabric clocks in N+1 to answer;
//   * so the resolved pair is written during N+2.
//
// That is a uniform four-hi-res-pixel delay on playfield, objects and border
// alike, so nothing shifts relative to anything else.  Delaying the line
// buffer's rewind by the same four pixels means each line's buffer still
// receives exactly its own 456 pixels — the four written between the beam's line
// start and the delayed rewind are the PREVIOUS line's last four, and they land
// in the previous line's slots, which is where they belong.
//
// CLOCK BUDGET: a 9-bit compare per pixel and a 2-bit counter.  Everything
// expensive is inside the modules this one wires together.
//
`timescale 1ns/1ps

module antic_scanline (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,

    // ---- from the beam ---------------------------------------------------
    input  wire        line_start,     // 1-clk at the start of each scanline
    input  wire        px_tick,        // 1-clk per hi-res pixel, 4 per cycle
    input  wire [6:0]  hcount,
    input  wire [8:0]  line,
    input  wire        in_vblank,

    // ---- live registers --------------------------------------------------
    input  wire [7:0]  dmactl,         // $D400
    input  wire [2:0]  chactl,         // $D401
    input  wire        dlist_we_l,     // $D402
    input  wire        dlist_we_h,     // $D403
    input  wire [7:0]  dlist_wdata,
    input  wire [3:0]  hscrol,         // $D404
    input  wire [3:0]  vscrol,         // $D405
    input  wire [7:0]  chbase,         // $D409
    input  wire [7:0]  pmbase,         // $D407
    input  wire [7:0]  colbk, colpf0, colpf1, colpf2, colpf3,

    // ---- GTIA registers --------------------------------------------------
    input  wire [7:0]  hposp0, hposp1, hposp2, hposp3,
    input  wire [7:0]  hposm0, hposm1, hposm2, hposm3,
    input  wire [1:0]  sizep0, sizep1, sizep2, sizep3,
    input  wire [7:0]  sizem,
    input  wire [7:0]  grafp0, grafp1, grafp2, grafp3,
    input  wire [7:0]  grafm,
    input  wire [7:0]  prior,          // $D01B
    input  wire [7:0]  colpm0, colpm1, colpm2, colpm3,
    input  wire        hitclr,         // $D01E write
    input  wire        active_line,    // an active display line

    // ---- memory ----------------------------------------------------------
    output logic [15:0] mem_addr,
    input  wire [7:0]  mem_data,

    // ---- line buffer write port ------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start,  // rewind, delayed by the pipeline

    // ---- P/M DMA stores into GRAFM / GRAFP0-3 ---------------------------
    output wire        pm_we,
    output wire [2:0]  pm_obj,
    output wire [7:0]  pm_data,

    // ---- collision latches ------------------------------------------------
    output wire [15:0] m_pf,
    output wire [15:0] p_pf,
    output wire [15:0] m_pl,
    output wire [15:0] p_pl,

    // ---- out -------------------------------------------------------------
    output wire        dli,
    output wire [15:0] dlpc
);

    // ---- where the beam is, in hi-res pixels -----------------------------
    logic [1:0] sub;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)             sub <= 2'd0;
        else if (line_start) sub <= 2'd0;
        else if (px_tick)    sub <= sub + 2'd1;
    end

    wire [8:0] px_pos = {hcount, sub};

    // ---- the display list ------------------------------------------------
    wire        dl_line_ready, dl_line_valid, dl_hscrol_en;
    wire [3:0]  dl_mode, dl_row;
    wire [15:0] dl_scan_addr, dl_addr;

    wire [15:0] fetch_scan_out;
    wire        fetch_busy, fetch_done;

    antic_dl u_dl (
        .clk(clk), .rst(rst), .cold(cold),
        .line_start(line_start), .in_vblank(in_vblank),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata),
        .dl_dma_en(dmactl[5]), .vscrol(vscrol),
        .dl_addr(dl_addr), .dl_data(mem_data), .dl_rd(),
        // The fetcher hands the advanced scan pointer back at the next line
        // start, before the display list can overwrite it with an LMS operand.
        .scan_ret(fetch_scan_out), .scan_we(line_start),
        .line_ready(dl_line_ready), .mode(dl_mode), .scan_addr(dl_scan_addr),
        .row(dl_row), .hscrol_en(dl_hscrol_en), .line_valid(dl_line_valid),
        .dli(dli), .dlpc(dlpc)
    );

    // ---- geometry for this line's mode -----------------------------------
    wire       g_is_char, g_descender, g_is_display;
    wire [1:0] g_bpp;
    wire [3:0] g_px_width;
    wire [4:0] g_rows;

    antic_mode_tbl u_tbl (
        .mode(dl_mode), .is_char(g_is_char), .bpp(g_bpp),
        .px_width(g_px_width), .rows(g_rows), .descender(g_descender),
        .is_display(g_is_display)
    );

    wire       pf_on;
    wire [7:0] bytes_per_line;
    wire [6:0] dma_start, dma_stop, disp_start, disp_stop;
    wire [8:0] px_start, px_stop;
    wire [2:0] hs_delay;
    wire       hs_fine;

    antic_pf_geom u_geom (
        .pf_width(dmactl[1:0]), .hscrol_en(dl_hscrol_en), .hscrol(hscrol),
        .is_char(g_is_char), .bpp(g_bpp), .px_width(g_px_width),
        .pf_on(pf_on), .bytes_per_line(bytes_per_line),
        .dma_start(dma_start), .dma_stop(dma_stop),
        .disp_start(disp_start), .disp_stop(disp_stop),
        .px_start(px_start), .px_stop(px_stop),
        .hs_delay(hs_delay), .hs_fine(hs_fine)
    );

    // ---- memory handoff: display list, then P/M DMA, then playfield ------
    // A chain, not an arbiter: none of the three can overlap, because each
    // needs an answer the previous one produces.
    localparam logic [1:0] OWN_DL = 2'd0, OWN_PM = 2'd1, OWN_PF = 2'd2;

    wire [15:0] pm_addr;
    wire        pm_done;

    logic [1:0] bus_owner;
    always_ff @(posedge clk or posedge rst) begin
        if (rst || cold)        bus_owner <= OWN_DL;
        else if (line_start)    bus_owner <= OWN_DL;
        else if (dl_line_ready) bus_owner <= OWN_PM;
        else if (pm_done)       bus_owner <= OWN_PF;
    end

    wire [15:0] fetch_addr;
    always_comb begin
        case (bus_owner)
            OWN_DL:  mem_addr = dl_addr;
            OWN_PM:  mem_addr = pm_addr;
            default: mem_addr = fetch_addr;
        endcase
    end

    // ---- player/missile DMA, at the very start of the line ---------------
    antic_pm_fetch u_pm (
        .clk(clk), .rst(rst),
        .start(dl_line_ready), .line(line),
        .pmbase(pmbase), .player_dma_en(dmactl[3]),
        .missile_dma_en(dmactl[2]), .res_1line(dmactl[4]),
        .mem_addr(pm_addr), .mem_data(mem_data),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data),
        .busy(), .done(pm_done)
    );

    // ---- fetch, then emit ------------------------------------------------
    wire        fetch_start  = pm_done && dl_line_valid && pf_on;
    wire [5:0]  rd_idx;
    wire [7:0]  rd_data, rd_code;

    antic_pf_fetch u_fetch (
        .clk(clk), .rst(rst),
        .start(fetch_start), .mode(dl_mode), .scan_addr_in(dl_scan_addr),
        .row({1'b0, dl_row}), .chbase(chbase), .chactl(chactl),
        .bytes_per_line(bytes_per_line),
        .mem_addr(fetch_addr), .mem_data(mem_data),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .scan_addr_out(fetch_scan_out), .busy(fetch_busy), .done(fetch_done)
    );

    // A line only draws playfield if the display list says so, the width is
    // non-zero and the bytes actually got fetched.  Latched for the scanline
    // because it must not change under the window comparison mid-pixel.
    logic line_has_pf;
    always_ff @(posedge clk or posedge rst) begin
        if (rst || cold)     line_has_pf <= 1'b0;
        else if (line_start) line_has_pf <= 1'b0;
        else if (fetch_done) line_has_pf <= 1'b1;
    end

    // ---- the window comparison, live, every pixel ------------------------
    wire in_window = line_has_pf && pf_on &&
                     (px_pos >= px_start) && (px_pos < px_stop);

    wire        pf_wr;
    wire [7:0]  pf_color;
    wire [2:0]  pf_src_now;

    antic_line_render u_render (
        .clk(clk), .rst(rst),
        .start(fetch_done), .emit_en(px_tick && in_window),
        .mode(dl_mode), .bytes_per_line(bytes_per_line),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .lb_wr(pf_wr), .lb_color(pf_color), .lb_pf_src(pf_src_now),
        .busy(), .done()
    );

    // ---- the playfield pair for GTIA -------------------------------------
    // Outside the window there is no playfield, only background.  GTIA needs
    // the SOURCE, not the colour: it decides priority and collisions on which
    // playfield a pixel is, and colours it afterwards.
    localparam logic [2:0] SRC_BK = 3'd0;

    wire [2:0] this_px_src = pf_wr ? pf_src_now : SRC_BK;

    logic [2:0] pf_cap_a, pf_cap_b;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pf_cap_a <= SRC_BK;
            pf_cap_b <= SRC_BK;
        end else if (px_tick) begin
            if (!sub[0]) pf_cap_a <= this_px_src;
            else         pf_cap_b <= this_px_src;
        end
    end

    // A colour clock starts on the even hi-res pixel.  At that same edge
    // gtia_stage samples pf_cap_a/b, which still hold the PREVIOUS colour
    // clock's pair — non-blocking assignment is doing the pipelining here.
    wire cc_tick = px_tick && !sub[0];

    // ...and the objects must be evaluated where that pair was, one colour
    // clock back.  {hcount, sub[1]} is constant across a colour clock, so
    // subtracting one gives the previous one throughout.
    wire [7:0] cc_pos = {hcount, sub[1]} - 8'd1;

    wire       gtia_valid;
    wire [7:0] gtia_a, gtia_b;

    gtia_stage u_gtia (
        .clk(clk), .rst(rst),
        .line_start(line_start), .cc_tick(cc_tick), .cc_pos(cc_pos),
        .active(active_line), .hitclr(hitclr),
        .pf_src_a(pf_cap_a), .pf_src_b(pf_cap_b),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm), .prior(prior),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .out_valid(gtia_valid), .out_color_a(gtia_a), .out_color_b(gtia_b),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl)
    );

    // The resolved pair waits here for the colour clock after next.
    logic [7:0] pend_a, pend_b;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pend_a <= 8'h00;
            pend_b <= 8'h00;
        end else if (gtia_valid) begin
            pend_a <= gtia_a;
            pend_b <= gtia_b;
        end
    end

    // Every pixel of the line is written; the border is background that came
    // through the same path as everything else.
    assign lb_wr    = px_tick;
    assign lb_color = sub[0] ? pend_b : pend_a;

    // ---- the delayed rewind ----------------------------------------------
    // Four hi-res pixels, the pipeline depth.  The four pixels written between
    // the beam's line start and this are the PREVIOUS line's last four, and the
    // pointer has not rewound yet, so they land where they belong.
    localparam int PIPE_PX = 4;

    logic [2:0] ls_cnt;
    logic       ls_arm;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ls_arm <= 1'b0;
            ls_cnt <= 3'd0;
        end else if (line_start) begin
            ls_arm <= 1'b1;
            ls_cnt <= 3'd0;
        end else if (ls_arm && px_tick) begin
            if (ls_cnt == 3'(PIPE_PX - 1)) ls_arm <= 1'b0;
            else                           ls_cnt <= ls_cnt + 3'd1;
        end
    end

    assign lb_line_start = ls_arm && px_tick && (ls_cnt == 3'(PIPE_PX - 1));

endmodule

`default_nettype wire
