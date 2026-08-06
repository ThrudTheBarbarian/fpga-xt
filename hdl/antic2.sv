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
    // One hi-res pixel.  FOUR per machine cycle, and the display side needs it
    // because a playfield byte is two to eight pixels wide: `tick` alone cannot
    // say WHERE in the cycle a pixel lands.  Taken as an input rather than
    // divided down locally so there is one definition of the pixel clock in the
    // design -- a8_core already has it, and deriving a second one here is the
    // "two definitions of one value" mistake this rewrite exists to avoid.
    input  wire        px_tick,

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

    // What was last on the DATA BUS, whoever drove it.  Only the VIRTUAL
    // playfield slot reads it: that access drives no address, so the buffer
    // takes whatever the previous bus cycle left behind.  a8_core keeps it.
    input  wire [7:0]  bus_byte,

    // ---- to the CPU / rest of the machine ----------------------------------
    output wire        nmi,                // ONE-CYCLE PULSE
    output wire        wsync_take,         // ANTIC takes this cycle for WSYNC
    output wire        dma_steal,          // stage 1: memory refresh only
    output wire [6:0]  hcount,
    output wire [8:0]  line,

    // ---- the pixel stream, for the ANTIC->framebuffer gap filler ----------
    // ANTIC's output is not colour.  It is, per hi-res pixel, WHICH PLAYFIELD
    // this is (px_pf_src) and the raw two-bit value a GTIA mode reads instead
    // (px_val), plus whether the colour clock is a hi-res one.  Priority,
    // players, collisions and the colour lookup all happen downstream; see
    // a2_video.  px_wr says the renderer emitted this pixel at all, which is
    // not the same as px_in_window -- the border is inside neither.
    output wire        px_wr,
    output wire [2:0]  px_pf_src,
    output wire [1:0]  px_val,
    output wire        px_hires,
    output wire        px_in_window,       // LEVEL: the beam is on the playfield
    output wire [8:0]  px_pos,             // hi-res pixel index along the line
    output wire        px_line_start,      // 1-clk at the top of the scanline
    output wire        px_active,          // an active display line

    // ---- the P/M shape store ----------------------------------------------
    // What ANTIC hands GTIA for the players and missiles.  GRACTL decides
    // whether GTIA latches it (gtia_reg_file's pm_take), and pm_mask is
    // VDELAY's per-bit gate, so this side only says WHAT and WHEN.
    output wire        pm_we,
    output wire [2:0]  pm_obj,             // 0 = missiles, 1..4 = players 0..3
    output wire [7:0]  pm_data,
    output wire [7:0]  pm_mask
);

    wire        line_start;
    wire [7:0]  dmactl, chactl, hscrol, vscrol;
    wire        dlist_lo_stb, dlist_hi_stb;
    wire [7:0]  dlist_val;
    wire [7:0]  pmbase, chbase, nmien;
    wire [7:0]  nmist, vcount;
    wire        wsync_stb, nmires_stb, nmien_stb;
    wire        row_ends, dli_line, dli_fired_set;
    wire [7:0]  dl_insn;
    wire [3:0]  row_line;
    wire        dl_done, row_first, jvb_pulse, dl_insn_stb;
    wire        sched_steal;
    wire        dl_fetch_req;
    wire [3:0]  dl_row_end;
    wire        dl_row_end_live;
    wire [3:0]  dl_row_line_load;
    wire        dl_row_line_set;
    wire        dl_busy;
    wire [15:0] dl_addr_o, pf_addr_o;

    // Memory clients: the display-list executor and the playfield fetcher.
    wire [15:0] dl_mem_addr, pf_mem_addr, pf_scan_addr;
    wire        dl_mem_req,  pf_mem_req;
    wire        dl_mem_valid, pf_mem_valid;
    wire        pf_load;                    // 1-clk: an LMS operand landed

    // The schedule's own fetch slots, which the fetcher runs on.
    wire        sched_pf_fetch, sched_pf_fetch_glyph;

    // The line buffer's read port.  The renderer owns the index: it walks the
    // buffer the fetcher filled, one hi-res pixel per emit_en pulse.
    wire [5:0]  lb_rd_idx;
    // Declared here, with the read port it belongs to, because the fetcher's
    // instantiation below uses it and a variable must exist before it is
    // referenced.  Driven by the counter further down.
    logic [5:0] lb_origin;
    wire [7:0]  lb_rd_data, lb_rd_code;
    wire [6:0]  lb_len;
    wire [4:0]  mode_rows;

    // The display window and the beam's position within the scanline.  Declared
    // here, before the generate-free body below uses them, because a wire first
    // referenced inside a port connection is an implicit 1-bit net under
    // `default_nettype none` -- which is an error here, and silently the wrong
    // width where it is not.
    wire [8:0]  pf_px_start, pf_px_stop;
    wire        pf_emit_en;

    // The renderer also computes a colour, and in this design NOTHING READS IT.
    // Colour is decided downstream, in a2_video, from the source plus priority
    // plus whatever player happens to be over the pixel -- which is where the
    // real chip decides it too.  Taking antic_line_render's answer as well
    // would be two definitions of one value, and the two would disagree the
    // moment a player overlapped the playfield.  It is named and left here
    // rather than deleted because antic_line_render is shared with the legacy
    // raster, where it IS the answer.
    wire [7:0]  px_color;
    wire        render_busy, render_done;

    // ---- position ----------------------------------------------------------
    antic_beam #(
        .CYCLES_PER_LINE(LINE_CYCLES), .LINES_PER_FRAME(LINES),
        .DISPLAY_TOP(DISPLAY_TOP)
    ) u_beam (
        .clk(clk), .rst(rst), .tick(tick), .vcount_adv(7'd111),
        .hcount(hcount), .line(line), .vcount(),          // NOT used -- see header
        .line_start(line_start), .in_display(px_active),
        .in_vblank(), .vbi_line()
    );

    // The gap filler needs the beam, not just the pixels: GTIA compares object
    // positions against the colour clock even where the playfield emitted
    // nothing, and it does not compare at all during vertical blank.
    assign px_line_start = line_start;

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
        .wsync_stb(wsync_stb),
.nmien_stb(nmien_stb),
                .nmires_stb(nmires_stb)
    );

    // ---- the mode's natural row height -------------------------------------
    wire       md_is_char, md_is_display;
    wire [1:0] md_bpp;
    wire [3:0] md_px_width;
    antic_mode_tbl u_mode (
        .mode(dl_insn[3:0]),
        .is_char(md_is_char), .bpp(md_bpp), .px_width(md_px_width),
        .rows(mode_rows), .descender(), .is_display(md_is_display)
    );

    // ---- STAGE 2: the playfield fetch map ----------------------------------
    //
    // REUSED, NOT REWRITTEN.  antic_pf_geom turns the mode and DMACTL width
    // into the line's geometry and antic_dma_sched turns that into "which
    // machine cycle the CPU loses".  Both are measured correct end to end
    // (c96332a): all 50 of antic_dmapattern's maps, with the steals mapping 1:1
    // onto the cycles the CPU actually loses.  Re-deriving either here would be
    // a second definition of a value that already has one.
    //
    // antic_dma_sched OWNS REFRESH as well as the playfield, including the
    // priority rule -- a preempted refresh is deferred ONE cycle and then LOST,
    // not re-sought.  So it REPLACES antic2's own refresh steal rather than
    // being OR'd with it; ORing would double-count every refresh cycle.
    // THE SCHEDULER MUST SAMPLE THE LINE SHAPE *AFTER* THE INSTRUCTION LANDS.
    //
    // antic_dma_sched latches the WHOLE line shape on its line_start pulse --
    // pf_n from n_fetch, dma_start, pairs, is_char (antic_dma_sched.sv:161).
    // emu can do that at line_start because dl_exec runs SYNCHRONOUSLY inside
    // line_start, so the new instruction is already in place.  antic2_dl is a
    // multi-cycle state machine, so on the beam's line_start pulse `dl_insn`
    // still holds the PREVIOUS instruction -- and the map was built from it.
    //
    // MEASURED: dl_insn settles at hcount 0, THREE fabric clocks after the
    // line_start pulse, which is still well inside machine cycle 0 (the first
    // scheduled cycle is 1, and refresh does not begin until 25).  So delaying
    // the scheduler's sample by a few fabric clocks is both sufficient and
    // invisible to the schedule itself.
    //
    // SYMPTOM THIS FIXES: the display-list fetch and that row's playfield
    // landed on DIFFERENT scanlines, where emu has them on ONE --
    //   emu   .#....##.................##.####################...
    //   ours  .#....##.................#...#...#...#...#...#...#     (no playfield)
    //         .........................##.####################...   (playfield, next line)
    // -- while a LATER line of the same row matched emu character for
    // character, which is what showed the map itself was right and only its
    // start was displaced.
    localparam int SCHED_SAMPLE_DELAY = 4;
    logic [2:0] ls_delay;
    logic       sched_line_start;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ls_delay         <= 3'd0;
            sched_line_start <= 1'b0;
        end else begin
            sched_line_start <= 1'b0;
            if (line_start)               ls_delay <= 3'd1;
            else if (ls_delay != 3'd0) begin
                if (ls_delay == 3'(SCHED_SAMPLE_DELAY)) begin
                    ls_delay         <= 3'd0;
                    sched_line_start <= 1'b1;
                end else ls_delay <= ls_delay + 3'd1;
            end
        end
    end

    wire [7:0] pf_bytes, pf_step;
    // The LIVE window.  `pf_dma_start`/`pf_dma_stop` -- what everything below
    // actually consumes -- are these with any already-latched edge substituted
    // in; see the edge latch further down.
    wire [6:0] geom_dma_start, geom_dma_stop;
    antic_pf_geom u_geom (
        .pf_width(dmactl[1:0]),
        .hscrol_en(dl_insn[4] && (dl_insn[3:0] >= 4'd2)),
        .hscrol(hscrol[3:0]),
        .is_char(md_is_char), .bpp(md_bpp), .px_width(md_px_width),
        .pf_on(), .bytes_per_line(pf_bytes), .pf_step(pf_step),
        .dma_start(geom_dma_start), .dma_stop(geom_dma_stop), .disp_start(), .disp_stop(),
        .px_start(pf_px_start), .px_stop(pf_px_stop), .hs_delay(), .hs_fine()
    );

    // ---- the display window ------------------------------------------------
    //
    // FETCHING AND DISPLAYING ARE DIFFERENT WINDOWS.  Above, dma_start feeds
    // the scheduler and decides which cycles the fetcher steals; here px_start
    // and px_stop decide which hi-res pixels the beam actually paints, with
    // HSCROL already applied.  A scrolled narrow row fetches 40 bytes and
    // displays 32, so wiring the renderer to the fetch window would slide the
    // row sideways by the scroll amount.
    //
    // emit_en is a PULSE, one per displayed pixel, not a level across the
    // window -- antic_emit_win qualifies it with px_tick for exactly that
    // reason.
    antic_emit_win u_emit (
        .clk(clk), .rst(rst),
        .line_start(line_start), .px_tick(px_tick),
        .px_start(pf_px_start), .px_stop(pf_px_stop),
        .emit_en(pf_emit_en), .in_window(px_in_window), .px_pos(px_pos)
    );

    // Whether the playfield is FETCHING at all this line: the list is running,
    // the latched instruction is a display mode, and DMACTL's width is not
    // zero.  This is emu's `on` in rebuild_line -- `mode >= 2 && pf_dma_on()`
    // -- and it gates the WHOLE map, not just the playfield walk: when it is
    // false emu hands the map builder a mode of 0, and that zero takes DMACTL
    // bit 5 with it, so the display-list fetch is not charged to the CPU
    // either.
    //
    // antic_vscroldli is decided by exactly that one cycle.  It runs with
    // dmactl = $20 -- display-list DMA on, playfield width zero -- and does
    // `stx vscrol` at the top of the first line of an $F0 row.  With the fetch
    // uncharged the instruction runs at cycles 1..4 and the write lands at 4,
    // in time for the row-end compare; charging cycle 1 for the $F0's own
    // fetch pushes it to 5, the compare misses it, and the row ends a line
    // late ("VSCROL took effect too late").  Measured both ways: emu writes at
    // sl 40 cycle 4, we wrote at cycle 5, and that was the only difference in
    // the whole line.
    wire pf_fetching = md_is_display && !dl_done && (dmactl[1:0] != 2'b00);

    // ---- THE WINDOW EDGES LATCH AS THE BEAM PASSES THEM --------------------
    //
    // emu, antic.c:906-911, re-implemented from Altirra's LatchPlayfieldEdges:
    //
    //   "Each edge is a comparison against the horizontal counter, and once
    //    that comparison has been made it cannot be un-made -- so a mid-line
    //    DMACTL or HSCROL write moves only the edges still ahead of the beam,
    //    and a row can end up running the OLD start against the NEW stop.  Its
    //    byte count then belongs to neither width, which is what
    //    antic_pfstarttiming and antic_pfstoptiming measure from opposite
    //    sides."
    //
    // THE COMPARISON MUST USE THE WINDOW THE LINE HAS BEEN RUNNING, NOT THE ONE
    // THE WRITE JUST INSTALLED, AND THAT IS THE WHOLE DIFFICULTY.  emu gets it
    // by ORDERING -- latch_edges() is "Called BEFORE the register takes its new
    // value" -- which an always_ff cannot borrow.  Comparing `hcount` against a
    // target derived from the LIVE dmactl makes the target move the instant the
    // register does: antic_pfstarttiming's late DLI writes DMACTL on cycle 17,
    // a normal character row's target is 18 - 1 = 17, and the write shifts that
    // target to 25 before hcount ever reaches 17.  The match never happens, the
    // beam latches the narrow start at 25 instead, and the row answers as
    // though the write had been early -- which is exactly the failure.
    //
    // So the target comes from a SECOND, otherwise identical geometry block fed
    // from dmactl/hscrol as they stood at the START of this machine cycle.
    // Those two are the only registers here the CPU can move mid-line;
    // everything else is derived from dl_insn, which changes at a row boundary.
    logic [7:0] dmactl_q, hscrol_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dmactl_q <= 8'h00;
            hscrol_q <= 8'h00;
        end else if (tick) begin
            dmactl_q <= dmactl;
            hscrol_q <= hscrol;
        end
    end

    wire [6:0] prev_dma_start, prev_dma_stop;
    antic_pf_geom u_geom_prev (
        .pf_width(dmactl_q[1:0]),
        .hscrol_en(dl_insn[4] && (dl_insn[3:0] >= 4'd2)),
        .hscrol(hscrol_q[3:0]),
        .is_char(md_is_char), .bpp(md_bpp), .px_width(md_px_width),
        .pf_on(), .bytes_per_line(), .pf_step(),
        .dma_start(prev_dma_start), .dma_stop(prev_dma_stop),
        .disp_start(), .disp_stop(), .px_start(), .px_stop(),
        .hs_delay(), .hs_fine()
    );

    // The decision sits one cycle before the window for the character modes and
    // three before it for the bitmap ones -- the SAME absolute cycle for both,
    // since their starts differ by two (26-1 == 28-3 == 25 on a narrow line).
    wire [2:0] edge_off = md_is_char ? 3'd1 : 3'd3;

    // THE TWO EDGES LATCH INDEPENDENTLY, and that is load-bearing.  With both
    // live, or both frozen, they stay on the same phase, the DMA clock's clear
    // always succeeds, and the run-on antic_hscrolbug measures can never
    // happen -- see antic_dma_sched's header.
    logic [6:0] lat_start, lat_stop;
    logic       lat_start_v, lat_stop_v;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            lat_start   <= 7'd0;
            lat_stop    <= 7'd0;
            lat_start_v <= 1'b0;
            lat_stop_v  <= 1'b0;
        end else if (sched_line_start) begin
            lat_start_v <= 1'b0;        // both edges are live again at the top
            lat_stop_v  <= 1'b0;        //   of every scanline
        end else if (tick && pf_fetching) begin
            if (!lat_start_v && hcount == (prev_dma_start - {4'd0, edge_off})) begin
                lat_start   <= prev_dma_start;
                lat_start_v <= 1'b1;
            end
            if (!lat_stop_v && hcount == (prev_dma_stop - {4'd0, edge_off})) begin
                lat_stop   <= prev_dma_stop;
                lat_stop_v <= 1'b1;
            end
        end
    end

    // "Live where the beam has not reached the edge yet, latched where it has"
    // -- emu's pf_edges, antic.c:952-959.  The latch is ADDITIVE: u_geom above
    // stays purely combinational and every consumer reads through here.
    wire [6:0] pf_dma_start = lat_start_v ? lat_start : geom_dma_start;
    wire [6:0] pf_dma_stop  = lat_stop_v  ? lat_stop  : geom_dma_stop;

    antic_dma_sched u_sched (
        .clk(clk), .rst(rst),
        .line_start(sched_line_start), .tick(tick), .hcount(hcount),
        .first_row(row_first), .is_char(md_is_char),
        .is_display(pf_fetching),
        .bytes_per_line(pf_bytes), .dma_start(pf_dma_start),
        .dma_stop(pf_dma_stop), .step(pf_step),
        // The OPERAND fetches belong to the INSTRUCTION, not to every row.
        // Bit 6 is the LMS flag (emu's dma_mode takes `dl_insn & 0x50`), and
        // on a blank-line instruction such as $F0 that same bit is part of the
        // blank COUNT -- which is why this may not be tied high.  A jump needs
        // no case of its own: mode 1 is not a display mode, so pf_fetching is
        // already false for it, exactly as emu's `on` is.
        .lms(dl_insn[6]),
        .dl_dma_en(dmactl[5] && pf_fetching), .missile_dma_en(dmactl[2]),
        .player_dma_en(dmactl[3]),
        .steal(sched_steal),
        .pf_fetch(sched_pf_fetch), .pf_fetch_glyph(sched_pf_fetch_glyph)
    );

    // ---- display-list executor ---------------------------------------------
    antic2_dl u_dl (
        .clk(clk), .rst(rst),
        .exec_req(dl_fetch_req),
        .mem_data(mem_data), .mem_valid(dl_mem_valid),
        .mem_req(dl_mem_req), .mem_addr(dl_mem_addr),
        .dlist_lo_stb(dlist_lo_stb), .dlist_hi_stb(dlist_hi_stb),
        .dlist_val(dlist_val),
        .vscrol(vscrol), .mode_rows(mode_rows),
        .dl_insn(dl_insn), .dl_addr(dl_addr_o), .pf_addr(pf_addr_o),
        .pf_load(pf_load),
        .row_end(dl_row_end), .row_end_live(dl_row_end_live),
        .row_line_load(dl_row_line_load), .row_line_set(dl_row_line_set),
        .jvb_pulse(jvb_pulse), .insn_stb(dl_insn_stb), .busy(dl_busy)
    );

    // ---- the VIRTUAL last slot ---------------------------------------------
    // A WIDE row's last playfield access runs off the end of the line.  ANTIC
    // still accounts for it and still clocks the line buffer, but it drives
    // neither address nor data, so what the buffer takes is the bus's leftover.
    // antic_virtdma is built on it: its missiles sit over four pixels of that
    // last character, which in mode 7 is the top four bits of the byte.
    //
    // COMPUTED ONCE AT LINE START from the settled window, exactly as emu does
    // (antic_pf_last).  Counting it live against a window that a mid-line
    // DMACTL write can move is the same fault that made lb_origin wrong, and
    // this is the second place it would have bitten.
    //
    // WIDE MEANS THE PROGRAMMED WIDTH, NOT THE FETCH WIDTH.  emu gates on
    // `width_of(dmactl) == ANTIC_WIDE`, so a scrolled NORMAL row -- which
    // fetches wide -- gets no virtual slot at all.  Un-blocking one everywhere
    // costs antic_dmapattern and antic_linebuffering, which tabulate the narrow
    // and normal cases and say their last playfield cycle IS a real fetch.
    //
    // The last slot is `start + step*floor((stop-1-start)/step)`, plus the
    // three-cycle character shift, which for antic_virtdma's $57 row is
    // 11 + 4*23 = 103, +3 = 106 -- emu's own probe prints exactly that.
    // The step is a power of two, so the divide is a shift.
    //
    // NOTHING NEEDS TO CHANGE IN THE SCHEDULE.  106 is PF_HBLANK_FIRST, where
    // antic_dma_sched already stops charging the CPU, so the slot costs no
    // cycle without being told not to -- measured, not assumed.
    logic [6:0] virt_cyc;
    logic       virt_en;

    wire [2:0] virt_sh = (pf_step == 8'd8) ? 3'd3
                       : (pf_step == 8'd4) ? 3'd2 : 3'd1;
    wire       virt_win = pf_dma_stop > pf_dma_start;
    wire [6:0] virt_n   = virt_win ? ((pf_dma_stop - 7'd1 - pf_dma_start) >> virt_sh)
                                   : 7'd0;
    wire [6:0] virt_c   = pf_dma_start + (virt_n << virt_sh);
    // emu returns -1 for `mode < 2` and for `mode >= 8 && !first_line`: a
    // BITMAP row's later lines have no last slot, a character row's do.
    wire       virt_ok  = (dmactl[1:0] == 2'b11) && md_is_display && virt_win &&
                          (md_is_char || row_first);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            virt_en  <= 1'b0;
            virt_cyc <= 7'd127;
        end else if (sched_line_start) begin
            virt_en  <= virt_ok;
            virt_cyc <= md_is_char ? (virt_c + 7'd3) : virt_c;
        end
    end

    wire virt_slot = virt_en && (hcount == virt_cyc);

    // ---- the playfield fetcher ---------------------------------------------
    // Driven by the SCHEDULE, one byte per scheduled cycle, so that a mid-line
    // DMACTL or HSCROL write moves the window for what is still to come while
    // the bytes already fetched stay fetched.  See antic_pf_stream.sv.
    antic_pf_stream u_pf (
        .clk(clk), .rst(rst),
        .line_start(sched_line_start), .first_row(row_first),
        .mode(dl_insn[3:0]), .row({1'b0, row_line}),
        .chbase(chbase), .chactl(chactl[2:0]),
        .bytes_per_line(pf_bytes),
        .pf_fetch(sched_pf_fetch), .pf_fetch_glyph(sched_pf_fetch_glyph),
        .scan_addr_in(pf_addr_o), .scan_load(pf_load),
        .scan_addr_out(pf_scan_addr),
        .mem_addr(pf_mem_addr), .mem_req(pf_mem_req),
        .mem_data(mem_data), .mem_valid(pf_mem_valid),
        .rd_idx(lb_rd_idx), .rd_origin(lb_origin),
        .rd_data(lb_rd_data), .rd_code(lb_rd_code),
        .lb_len(lb_len),
        .virt_slot(virt_slot), .bus_byte(bus_byte)
    );


    // ---- the line buffer's READ ORIGIN -------------------------------------
    // How many entries were filled BEFORE this line's own fetch window opened.
    // A line whose stream ran on from the previous one starts with its write
    // pointer already ahead, and the display has to skip those bytes; a normal
    // line's origin is zero.  antic_hscrolbug is built on it: seventeen extra
    // fetches in HBLANK shift the NEXT line's display left by seventeen bytes.
    //
    // COUNT ENTRIES, NOT FETCHES.  A character first row takes two accesses per
    // entry -- the name, and the glyph three cycles later -- and pf_fetch
    // pulses for BOTH.  Counting it would double the origin on exactly the
    // rows that matter.  pf_fetch_glyph marks the second access, and
    // antic_pf_stream calls the same distinction idx_takes.
    //
    // THE CONDITION IS `mode >= 8 || first_line`, BOTH HALVES OF IT.  emu's
    // map is written under exactly that (antic_dma.c, spec_edges), and the two
    // halves say different things.  A later CHARACTER row marks nothing at
    // all: it re-reads only glyphs from the character base and replays the
    // names out of the buffer, advancing no scan address and taking no index,
    // so its origin is zero even when the stream ran on.  A BITMAP row is
    // never "later" in the sense that matters -- it marks its map on EVERY
    // scanline -- so `row_first` must not gate it.
    //
    // Measured, not reasoned: antic_hscrolbug's second sub-test is a mode E
    // row with row_first low where emu counts ten carried fetches.  With only
    // the first_line half implemented this counted none, the display read from
    // entry 0, and the byte the test looks for never appeared under the
    // players.
    //
    // Counted as the fetches happen rather than derived from a map at line
    // start, because the fetch is progressive and the display window opens
    // long after the carried entries are in.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                   lb_origin <= 6'd0;
        else if (sched_line_start) lb_origin <= 6'd0;
        else if ((!md_is_char || row_first) &&
                 sched_pf_fetch && !sched_pf_fetch_glyph &&
                 hcount < pf_dma_start)
            lb_origin <= lb_origin + 6'd1;
    end

    // ---- the renderer ------------------------------------------------------
    // Walks the buffer the fetcher filled, one hi-res pixel per emit_en pulse,
    // so the pixel stream is paced by the BEAM and not by the fetch.  `start`
    // is the scheduler's line_start, the same pulse the fetcher restarts on, so
    // the walk and the fill agree about which line's mode and byte count they
    // are working from.
    //
    // THE COLOUR REGISTERS ARE TIED OFF, AND THEY STAY THAT WAY.  COLBK and
    // COLPF0-3 are $D016-$D01A -- GTIA's registers, not ANTIC's -- and the
    // colour they select is not ANTIC's answer either: a player over the
    // playfield changes it, and only the stage that knows where the players are
    // can say what the pixel ends up being.  That stage is a2_video, and it
    // does the lookup itself from lb_pf_src.  Feeding the registers in here as
    // well would put the lookup in two places and the two would disagree the
    // first time an object overlapped.  So what leaves antic2 is the SOURCE --
    // lb_pf_src / lb_px_val / lb_is_hires -- and px_color goes nowhere.
    antic_line_render u_render (
        .clk(clk), .rst(rst),
        .start(sched_line_start), .emit_en(pf_emit_en),
        .in_window(px_in_window),
        .mode(dl_insn[3:0]), .bytes_per_line(pf_bytes),
        .colbk(8'h00), .colpf0(8'h00), .colpf1(8'h00),
        .colpf2(8'h00), .colpf3(8'h00),
        .rd_idx(lb_rd_idx), .rd_data(lb_rd_data), .rd_code(lb_rd_code),
        .lb_wr(px_wr), .lb_color(px_color), .lb_pf_src(px_pf_src),
        .lb_px_val(px_val), .lb_is_hires(px_hires),
        .busy(render_busy), .done(render_done)
    );

    // ---- memory arbitration -------------------------------------------------
    // The two clients CANNOT collide: the schedule puts the display-list fetch
    // at hcount 1 (and its operands at 6 and 7) and opens the playfield walk no
    // earlier than cycle 10.  They are the same schedule's own slots, so this
    // is a priority mux over signals that are never both asserted, not an
    // arbiter resolving real contention.  The assertion below is the check.
    assign mem_req  = dl_mem_req || pf_mem_req;
    assign mem_addr = dl_mem_req ? dl_mem_addr : pf_mem_addr;

    // mem_valid is mem_req delayed one clock, so remembering WHICH client
    // issued needs exactly one clock of delay too.  Without this the fetcher
    // would latch the display list's bytes into the line buffer, and the DL
    // executor would decode a playfield byte as an instruction.
    logic vld_is_pf;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) vld_is_pf <= 1'b0;
        else     vld_is_pf <= pf_mem_req && !dl_mem_req;
    end
    assign pf_mem_valid = mem_valid &&  vld_is_pf;
    assign dl_mem_valid = mem_valid && !vld_is_pf;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && dl_mem_req && pf_mem_req)
            $display("antic2: ASSERT display-list and playfield fetch collided at hcount %0d",
                     hcount);
    end
`endif

    // ---- start-of-line bookkeeping -----------------------------------------
    antic2_line #(
        .DISPLAY_TOP(DISPLAY_TOP), .DISPLAY_BOTTOM(DISPLAY_BOTTOM)
    ) u_line (
        .clk(clk), .rst(rst), .line_start(line_start),
        .scanline(line), .dmactl(dmactl), .row_ends_in(row_ends),
        .dl_fetch_req(dl_fetch_req), .jvb_pulse(jvb_pulse),
        .row_line_load(dl_row_line_load), .row_line_set(dl_row_line_set),
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
    // CLEARED PER DISPLAY-LIST INSTRUCTION, not per frame.  emu's dl_exec does
    // `a->dli_fired = 0` on every instruction it executes; clearing once a frame
    // let one row's firing suppress a later row's in the same frame.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                  dli_fired <= 1'b0;
        else if (dl_insn_stb)     dli_fired <= 1'b0;
        else if (dli_fired_set)   dli_fired <= 1'b1;
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
    // STAGE 2 REPLACED THE STANDALONE REFRESH STEAL.  antic_dma_sched owns the
    // whole schedule now -- refresh, the display list, P/M and the playfield --
    // together with the priority rule between them.  What survives here is the
    // refresh WINDOW, and only because the WSYNC RMW rule keys off it: emu's
    // antic_dma_in_refresh is a RANGE test over 25..57, which is a different
    // question from "is this cycle a refresh cycle" and has no other owner.
    localparam int REFRESH_FIRST = 25;
    localparam int REFRESH_STEP  = 4;
    localparam int REFRESH_COUNT = 9;


    assign dma_steal = sched_steal;

    // The WSYNC RMW extra cycle keys off the refresh WINDOW, not off individual
    // refresh cycles: emu's antic_dma_in_refresh is the RANGE test (25..57) with
    // no %STEP term -- `is_refresh` is the other, stricter one.  Evaluated at
    // cycle-1 because that is what emu passes.  Computed HERE so the window
    // bounds have a single definition, shared with refresh_steal above.
    wire [6:0] prev_cycle = (hcount == 7'd0) ? 7'(LINE_CYCLES - 1) : hcount - 7'd1;
    wire refresh_window_prev =
        (prev_cycle >= 7'(REFRESH_FIRST)) &&
        (prev_cycle <= 7'(REFRESH_FIRST + (REFRESH_COUNT-1)*REFRESH_STEP));

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
        .nmien(nmien), .nmien_stb(nmien_stb), .nmires_stb(nmires_stb),
        .wsync_stb(wsync_stb), .refresh_window_prev(refresh_window_prev),
        .cpu_writing(cpu_writing),
        .nmist(nmist), .vcount(vcount), .nmi(nmi),
        .wsync_take(wsync_take), .row_ends(row_ends), .dli_line(dli_line)
    );

    // ---- the PHANTOM P/M LATCH ---------------------------------------------
    // GTIA samples the data bus at the players' slots WHETHER OR NOT ANTIC
    // fetched anything there.  With player DMA off nobody is driving those
    // cycles for GTIA, so what lands in GRAFPn is the CPU's own traffic --
    // gtia_phantomdma sets DMACTL = $21 and then requires GRAFP0 to hold $AD,
    // the opcode fetch of its own `lda $0100`.  a8_core's header has called
    // this out from the start: the bus VALUE is a third-party observable.
    //
    // CYCLES 3,4,5,6 -> PLAYERS 0,1,2,3, MEASURED, NOT ASSUMED.  emu's PHAN
    // probe prints exactly that on every line of a passing gtia_phantomdma.
    // Note it is NOT the same as antic2's player DMA steal, which runs 2..5:
    // one is where ANTIC would fetch, the other where GTIA samples, and no
    // model has had both mechanisms at once before now, so nothing has ever
    // forced them to agree.  If a P/M test later says otherwise, this constant
    // is the thing to move -- and it is one number.
    //
    // Only the PLAYER phantom exists.  emu has a missile one behind
    // PHANTOM_PM_M, and that define is 0: dead code, not transcribed.
    //
    // GRACTL is NOT checked here.  gtia_reg_file's pm_take already gates on
    // it, and putting the same condition in both places would be two
    // definitions of one value.
    localparam int PM_SLOT_P = 3;
    wire pm_phantom = !dmactl[3] &&
                      (hcount >= 7'(PM_SLOT_P)) && (hcount < 7'(PM_SLOT_P + 4));

    assign pm_we   = tick && pm_phantom;
    assign pm_obj  = 3'd1 + 3'(hcount - 7'(PM_SLOT_P));
    assign pm_data = bus_byte;
    assign pm_mask = 8'hFF;

endmodule

`default_nettype wire
