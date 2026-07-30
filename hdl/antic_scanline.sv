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
// MEMORY IS SHARED BY STRICT HANDOFF, not arbitration: the display list machine
// owns the bus from line_start until it reports the line, then the fetcher owns
// it.  They cannot overlap because the fetch cannot start until the line is
// known.
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
    input  wire [7:0]  colbk, colpf0, colpf1, colpf2, colpf3,

    // ---- memory ----------------------------------------------------------
    output wire [15:0] mem_addr,
    input  wire [7:0]  mem_data,

    // ---- line buffer write port ------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,

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

    // ---- memory handoff --------------------------------------------------
    // The display list machine owns the bus from line_start until it reports
    // the line; after that the fetcher does.  No arbiter is needed because the
    // fetch cannot begin until the line is known.
    logic dl_owns_bus;
    always_ff @(posedge clk or posedge rst) begin
        if (rst || cold)         dl_owns_bus <= 1'b1;
        else if (line_start)     dl_owns_bus <= 1'b1;
        else if (dl_line_ready)  dl_owns_bus <= 1'b0;
    end

    wire [15:0] fetch_addr;
    assign mem_addr = dl_owns_bus ? dl_addr : fetch_addr;

    // ---- fetch, then emit ------------------------------------------------
    wire        fetch_start  = dl_line_ready && dl_line_valid && pf_on;
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

    antic_line_render u_render (
        .clk(clk), .rst(rst),
        .start(fetch_done), .emit_en(px_tick && in_window),
        .mode(dl_mode), .bytes_per_line(bytes_per_line),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .rd_idx(rd_idx), .rd_data(rd_data), .rd_code(rd_code),
        .lb_wr(pf_wr), .lb_color(pf_color),
        .busy(), .done()
    );

    // Every pixel of the line is written: playfield inside the window,
    // background outside it.  That is the border, and it keeps the line
    // buffer's write pointer walking with the beam.
    assign lb_wr    = px_tick;
    assign lb_color = pf_wr ? pf_color : colbk;

endmodule

`default_nettype wire
