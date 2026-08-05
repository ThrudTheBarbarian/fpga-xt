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

    // The line buffer's read port.  Nothing reads it yet -- the emit side is
    // the next piece of stage 3 -- so the index is parked at zero rather than
    // left floating, and the outputs are carried as wires so the fetcher's
    // buffer is observable from a testbench in the meantime.
    wire [5:0]  lb_rd_idx = 6'd0;
    wire [7:0]  lb_rd_data, lb_rd_code;
    wire [6:0]  lb_len;
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
    wire [6:0] pf_dma_start;
    antic_pf_geom u_geom (
        .pf_width(dmactl[1:0]),
        .hscrol_en(dl_insn[4] && (dl_insn[3:0] >= 4'd2)),
        .hscrol(hscrol[3:0]),
        .is_char(md_is_char), .bpp(md_bpp), .px_width(md_px_width),
        .pf_on(), .bytes_per_line(pf_bytes), .pf_step(pf_step),
        .dma_start(pf_dma_start), .dma_stop(), .disp_start(), .disp_stop(),
        .px_start(), .px_stop(), .hs_delay(), .hs_fine()
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

    antic_dma_sched u_sched (
        .clk(clk), .rst(rst),
        .line_start(sched_line_start), .tick(tick), .hcount(hcount),
        .first_row(row_first), .is_char(md_is_char),
        .is_display(pf_fetching),
        .bytes_per_line(pf_bytes), .dma_start(pf_dma_start), .step(pf_step),
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
        .rd_idx(lb_rd_idx), .rd_data(lb_rd_data), .rd_code(lb_rd_code),
        .lb_len(lb_len)
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

endmodule

`default_nettype wire
