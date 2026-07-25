// dl_parser.sv — parses the display list once per VBI into a per-DL-LINE
// entry list, then a LIVE WALKER expands entries into per-scanline metadata
// in raster lockstep, comparing the ANTIC DCTR against the LIVE VSCROL
// register each scanline.
//
// Split of responsibilities:
//
//   PARSE (once per frame, during vblank): walks the DL bytes via the
//   cpu_shadow read port and appends one ENTRY per DL line:
//     {sc_m1, mode, dli, vs_en, hs_en, lms}
//   LMS loads and the per-line memory-scan advance (4K-wrapped) are
//   resolved at parse time — the scan advance per DL line is a constant
//   per mode and does NOT depend on how many scanlines the line displays,
//   so it stays correct under live VSCROL resizing.  Entries land in a
//   ping-pong RAM; the ACTIVE bank swaps only at parse_done so the
//   display always reads a frame-stable snapshot (measured HW lesson:
//   live parse state read mid-frame misbehaves).
//
//   WALK (every scanline): a cursor advances through the active entry
//   list in raster lockstep (one flip per line_start).  The 4-bit DCTR
//   starts at S = (first-of-block ? VSCROL : 0), latched at the line's
//   first scanline, and the line ends after the scanline where
//   DCTR == E, evaluated LIVE each scanline with
//     E = last-of-block ? VSCROL : scan_count-1
//   so a mid-frame VSCROL write moves the region boundary exactly like
//   the real DCTR comparison (ACID800 antic_vscroll / antic_vscroldli).
//   first-of-block = cur.vs && !prev.vs, last-of-block = !cur.vs &&
//   prev.vs — same edge rules as before, now evaluated at walk time.
//   VSCROL >= mode height wraps the DCTR past 15 (the ANTIC over-scroll
//   long line).
//
//   DLI: fires on the LAST scanline of a flagged line (real ANTIC
//   semantics, uniform for mode and blank lines): dli_at = cur.dli &&
//   (DCTR == E_live), a single comparator — no variable-index array
//   reads (the HW-misbehaving pattern this file previously worked
//   around with the dli_act list).  nmi_gen samples dli_at at phi2
//   cycle 7/8 of the row; the walker flips at the scanline-start pulse
//   (cycle 0), so post-WSYNC VSCROL writes (cycle ~105 of the previous
//   row) are honoured and there are ~7 phi2 cycles of settle margin.
//
//   Leading blank lines within the LEAD_OVERSCAN budget are skipped
//   (top-overscan compression, unchanged) and do NOT become entries;
//   a DLI hanging on a skipped blank is recorded in a small PHANTOM
//   row list at its true physical position (lead_skipped + count-1)
//   and matched against dli_row with parallel comparators, exactly as
//   the old dli_act list did (ACID800 dlitiming's $90 blank+DLI rows).
//
// The meta_* read port is retained for the compositor but now presents
// the walker's CURRENT-row registers; meta_row is accepted for
// interface compatibility (the compositor always asks for the row the
// raster is on, which is the row the walker is presenting).
//
// Reference: rp-antic/src/display_list.c + Altirra DCTR/VSCROL notes.

`default_nettype none

module dl_parser (
    input  wire         clk,
    input  wire         rst,

    // Trigger: pulse to (re)start a parse from DLIST{H,L}.
    input  wire         start_parse,
    // SALLYRST cold-boot: abort any parse in flight and return to idle.
    input  wire         cold_abort,
    // Diagnostic: current FSM state + (legacy) emit phase.
    output wire  [3:0]  dbg_state,
    output wire  [1:0]  dbg_emit_phase,

    // Raster lockstep for the walker.
    input  wire         frame_start,       // vbi pulse: prime the walker for the next frame
    input  wire         line_start,        // scanline-start pulse, gated to the active window
    input  wire         prep_tick,         // late-line pulse (phi2 cycle ~111): prefetch next entry

    // ANTIC register inputs.
    input  wire [7:0]   dlistl,
    input  wire [7:0]   dlisth,
    input  wire         dlistl_we,      // 1-clk pulse: CPU wrote DLISTL
    input  wire         dlisth_we,      // 1-clk pulse: CPU wrote DLISTH
    input  wire [3:0]   vscrol,         // VSCROL ($D405) — LIVE, read by the walker

    // cpu_shadow / DMA read port (parse only).
    output logic [15:0] mem_raddr,
    input  wire  [7:0]  mem_rdata,
    output wire         mem_req,
    input  wire         mem_ready,

    // Per-row metadata port — the walker's current-row registers.
    input  wire  [7:0]  meta_row,
    output wire  [3:0]  meta_mode,
    output wire         meta_dli,
    output wire  [15:0] meta_lms_addr,
    output wire  [3:0]  meta_sub_row,
    output wire         meta_hscrol_en,
    output wire         meta_vscrol_en,

    // DLI read port — nmi_gen drives dli_row with the live raster row.
    input  wire  [7:0]  dli_row,
    output wire         dli_at,
    output wire  [7:0]  dbg_dli_rows,
    output wire  [4:0]  dbg_dli_cnt,       // # of DLI entries recorded this parse
    output wire         dbg_dli_has23,     // phantom list contains raster row 23

    // Status.
    output logic        parse_done,        // pulses after each parse pass
    output logic [31:0] parse_count
);

    localparam int ATARI_H = 192;
    // Leading blank-line scanlines treated as TOP OVERSCAN and skipped.
    localparam [7:0] LEAD_OVERSCAN = 8'd24;
    localparam int OPS_LIMIT = 1024;       // safety against malformed JMP loops
    localparam int EMAX = 256;             // entry list depth per bank
    localparam int PH_N = 24;              // phantom (blank-line) DLI rows

    // ---- Entry list (ping-pong) -----------------------------------------
    // {sc_m1[26:23], mode[22:19], dli[18], vs[17], hs[16], lms[15:0]}
    (* ram_style = "block" *)
    logic [26:0] eram [0:2*EMAX-1];        // bank in bit 8 of the index —
                                           // one write site (S_APPEND) + one
                                           // registered read site (pf_q):
                                           // simple-dual-port BLOCK RAM, keeps
                                           // ~500 LUTs of LUTRAM off the
                                           // placer's back (clk_sally closure)
    logic        act_bank;                 // walker reads this bank
    logic [8:0]  act_count;
    logic        act_carry_vs;      // VS bit of the line straddling the frame end
    logic [4:0]  act_dli_cnt;
    logic [7:0]  ph_act  [0:PH_N-1];       // active phantom DLI rows
    logic [4:0]  ph_act_cnt;

    // Parse-side (building) copies.
    logic [8:0]  ecount;
    logic        bld_last_vs;       // VS of the last appended entry
    logic [4:0]  bld_dli_cnt;
    logic [7:0]  ph_bld  [0:PH_N-1];
    logic [4:0]  ph_bld_cnt;
    wire         wr_bank = ~act_bank;

    // ---- Parse FSM ------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE, S_FETCH_OP, S_WAIT_OP, S_DECODE_OP,
        S_FETCH_LMS_LO, S_WAIT_LMS_LO, S_LATCH_LMS_LO,
        S_FETCH_LMS_HI, S_WAIT_LMS_HI, S_LATCH_LMS_HI,
        S_FETCH_JMP_LO, S_WAIT_JMP_LO, S_LATCH_JMP_LO,
        S_FETCH_JMP_HI, S_WAIT_JMP_HI, S_APPEND, S_SKIP
    } pstate_e;
    pstate_e state;

    assign dbg_state      = state[3:0];   // low 4 bits (17 states)
    assign dbg_emit_phase = 2'b00;         // legacy (emit phases are gone)

    // mem_req: pulse for exactly one cycle on each FETCH->WAIT transition —
    // one cycle AFTER the FETCH state, so the registered mem_raddr has
    // settled before the read adapter latches it (pulsing during FETCH
    // makes the adapter capture the PREVIOUS address and every decode
    // reads one byte behind — measured in tb_antic_dli).
    logic prev_state_was_fetch;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) prev_state_was_fetch <= 1'b0;
        else     prev_state_was_fetch <=
                     (state == S_FETCH_OP)     || (state == S_FETCH_LMS_LO)
                  || (state == S_FETCH_LMS_HI) || (state == S_FETCH_JMP_LO)
                  || (state == S_FETCH_JMP_HI);
    end
    assign mem_req = prev_state_was_fetch;

    logic [15:0] dl_pos;            // current DL byte address (free-running PC)
    logic [15:0] lms_ptr;           // running memory-scan pointer
    logic        dlistl_we_q, dlisth_we_q;
    logic        dlist_dirty;
    logic [15:0] target_addr;
    logic [15:0] new_lms_loaded;
    logic        lms_was_loaded;
    logic [3:0]  mode_q;
    logic        dli_q, lms_q, vscrol_q, hscrol_q;
    logic        is_jvb, is_blank;
    logic [4:0]  blank_count;
    logic [7:0]  lead_skipped;
    logic        seen_mode;
    logic [10:0] ops;
    logic [9:0]  scan_total;        // scanlines represented so far (bounds the parse)

    function automatic logic [4:0] scanline_count_for_mode(logic [3:0] m);
        case (m)
            4'h2, 4'h4, 4'h6, 4'h8: return 5'd8;
            4'h3:                    return 5'd10;
            4'h5, 4'h7:              return 5'd16;
            4'h9, 4'hA:              return 5'd4;
            4'hB, 4'hD:              return 5'd2;
            4'hC, 4'hE, 4'hF:        return 5'd1;
            default:                 return 5'd1;
        endcase
    endfunction

    // Bytes ANTIC fetches (and advances the memory scan by) for one mode
    // line.  HSCROL lines fetch one playfield width wider (NORMAL->WIDE).
    function automatic logic [15:0] bytes_per_line(logic [3:0] m, logic hs);
        case (m)
            4'h2, 4'h3, 4'h4, 4'h5: return hs ? 16'd48 : 16'd40;
            4'h6, 4'h7:              return hs ? 16'd24 : 16'd20;
            4'h8, 4'h9:              return hs ? 16'd12 : 16'd10;
            4'hA, 4'hB, 4'hC:        return hs ? 16'd24 : 16'd20;
            4'hD, 4'hE, 4'hF:        return hs ? 16'd48 : 16'd40;
            default:                 return 16'd0;
        endcase
    endfunction

    // ---- Walker ---------------------------------------------------------
    logic [8:0]  w_idx;             // entry index being displayed
    logic [3:0]  w_dctr;            // ANTIC DCTR (sub-row within the line)
    logic        w_prev_vs;         // previous displayed line's VSCROL bit
    logic        w_carry_vs;        // VS bit carried across the frame boundary:
                                    // a line straddling the vertical blank keeps
                                    // its VSCROL state into the next frame's
                                    // first line (antic_vscroll #5)
    logic        w_boot;            // primed, first active line pending
    // Current-line registers (what meta_* presents).
    logic [3:0]  cur_sc_m1, cur_mode;
    logic        cur_dli, cur_vs, cur_hs;
    logic [15:0] cur_lms;
    // Prefetched next-entry registers (advance candidate, entry w_idx+1).
    logic [3:0]  nxt_sc_m1, nxt_mode;
    logic        nxt_dli, nxt_vs, nxt_hs;
    logic        nxt_blankfill;     // entries exhausted -> blank rows
    logic [15:0] nxt_lms;
    logic        pf_pend;           // RAM read issued, latch next cycle
    logic [8:0]  pf_idx;
    logic [26:0] pf_q;

    // Live line-end comparison (the real DCTR/VSCROL semantics).
    wire w_last_of_block = w_prev_vs && !cur_vs;
    wire [4:0] e_live    = w_last_of_block ? {1'b0, vscrol}
                                           : {1'b0, cur_sc_m1};
    wire w_is_last       = ({1'b0, w_dctr} == e_live);

    // Walker-facing outputs (meta_row is interface-compatibility only —
    // the compositor always asks for the row being walked).
    assign meta_mode      = cur_mode;
    assign meta_dli       = cur_dli;
    assign meta_lms_addr  = cur_lms;
    assign meta_sub_row   = w_dctr;
    assign meta_hscrol_en = cur_hs;
    assign meta_vscrol_en = cur_vs;

    // DLI: last scanline of a flagged line, plus phantom (skipped-blank)
    // rows matched by physical position.
    logic ph_hit;
    always_comb begin
        ph_hit = 1'b0;
        for (int k = 0; k < PH_N; k++)
            if (k < ph_act_cnt && ph_act[k] == dli_row) ph_hit = 1'b1;
    end
    assign dli_at = (cur_dli && w_is_last && cur_mode != 4'h0) || ph_hit;

    assign dbg_dli_cnt   = act_dli_cnt;
    assign dbg_dli_rows  = {3'd0, ph_act_cnt};
    logic has23;
    always_comb begin
        has23 = 1'b0;
        for (int k = 0; k < PH_N; k++)
            if (k < ph_act_cnt && ph_act[k] == 8'd23) has23 = 1'b1;
    end
    assign dbg_dli_has23 = has23;

    // While the frame prime is pending (w_boot), every prep re-prefetches
    // entry 0 — prep_tick fires on vblank lines between frame_start and the
    // first active row, and must not clobber the primed entry with w_idx+1.
    wire [8:0] pf_next_idx = w_boot ? 9'd0 : (w_idx + 9'd1);

    // ---- Sequential body -------------------------------------------------
    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            dl_pos          <= {dlisth, dlistl};
            dlistl_we_q     <= 1'b0;
            dlisth_we_q     <= 1'b0;
            dlist_dirty     <= 1'b1;   // first parse always loads from the regs
            lms_ptr         <= 16'h0;
            target_addr     <= 16'h0;
            new_lms_loaded  <= 16'h0;
            lms_was_loaded  <= 1'b0;
            mode_q          <= 4'h0;
            dli_q           <= 1'b0;
            lms_q           <= 1'b0;
            vscrol_q        <= 1'b0;
            hscrol_q        <= 1'b0;
            is_jvb          <= 1'b0;
            is_blank        <= 1'b0;
            blank_count     <= 5'd1;
            lead_skipped    <= 8'd0;
            seen_mode       <= 1'b0;
            ops             <= 11'd0;
            scan_total      <= 10'd0;
            parse_done      <= 1'b0;
            parse_count     <= 32'h0;
            mem_raddr       <= 16'h0;
            act_bank        <= 1'b0;
            act_count       <= 9'd0;
            act_carry_vs    <= 1'b0;
            act_dli_cnt     <= 5'd0;
            ph_act_cnt      <= 5'd0;
            ecount          <= 9'd0;
            bld_last_vs     <= 1'b0;
            bld_dli_cnt     <= 5'd0;
            ph_bld_cnt      <= 5'd0;
            for (i = 0; i < PH_N; i++) begin
                ph_act[i] <= 8'hFF;
                ph_bld[i] <= 8'hFF;
            end
            w_idx           <= 9'd0;
            w_dctr          <= 4'd0;
            w_prev_vs       <= 1'b0;
            w_carry_vs      <= 1'b0;
            w_boot          <= 1'b0;
            cur_sc_m1       <= 4'd0;
            cur_mode        <= 4'd0;
            cur_dli         <= 1'b0;
            cur_vs          <= 1'b0;
            cur_hs          <= 1'b0;
            cur_lms         <= 16'h0;
            nxt_sc_m1       <= 4'd0;
            nxt_mode        <= 4'd0;
            nxt_dli         <= 1'b0;
            nxt_vs          <= 1'b0;
            nxt_hs          <= 1'b0;
            nxt_blankfill   <= 1'b1;
            nxt_lms         <= 16'h0;
            pf_pend         <= 1'b0;
            pf_idx          <= 9'd0;
            pf_q            <= 27'h0;
        end else begin
            parse_done <= 1'b0;     // single-cycle pulse

            // ================= PARSE FSM =================
            unique case (state)
                S_IDLE: begin
                    if (start_parse) begin
                        // Reload dl_pos from the registers only when written
                        // since the last parse (free-running DL PC otherwise —
                        // ACID800 antic_dlistwrap / Altirra mDLIST semantics).
                        if (dlist_dirty) dl_pos <= {dlisth, dlistl};
                        dlist_dirty    <= 1'b0;
                        lms_ptr        <= 16'h0;
                        ops            <= 11'd0;
                        scan_total     <= 10'd0;
                        seen_mode      <= 1'b0;
                        lead_skipped   <= 8'd0;
                        ecount         <= 9'd0;
                        bld_dli_cnt    <= 5'd0;
                        ph_bld_cnt     <= 5'd0;
                        state          <= S_FETCH_OP;
                    end
                end

                S_FETCH_OP: begin
                    if (ecount >= EMAX[8:0] || ops >= OPS_LIMIT[10:0]
                        || ({2'd0, lead_skipped} + scan_total) >= 10'd240) begin
                        // Frame scanline budget exhausted (240 physical
                        // display lines) or safety limit: STOP FETCHING and
                        // publish.  dl_pos is left at the next unfetched op,
                        // so the next frame's parse CONTINUES mid-list —
                        // real ANTIC halts its DL fetch at vertical blank
                        // and resumes; a DL longer than the frame (ACID800
                        // antic_vscroll #5's 29x blank-8 + trailing lines)
                        // spreads across frames.
                        act_bank    <= wr_bank;
                        act_count   <= ecount;
                        // Budget stop: the LAST APPENDED line straddles the
                        // vertical blank; its VS bit carries into the next
                        // frame (antic_vscroll #5 — the walker never reaches
                        // that entry, its rows sit beyond the visible window,
                        // so the carry must come from the parse).
                        act_carry_vs <= bld_last_vs;
                        act_dli_cnt <= bld_dli_cnt;
                        ph_act_cnt  <= ph_bld_cnt;
                        for (i = 0; i < PH_N; i++) ph_act[i] <= ph_bld[i];
                        parse_done  <= 1'b1;
                        parse_count <= parse_count + 32'd1;
                        state       <= S_IDLE;
                    end else begin
                        mem_raddr      <= dl_pos;
                        ops            <= ops + 11'd1;
                        lms_was_loaded <= 1'b0;
                        state          <= S_WAIT_OP;
                    end
                end

                S_WAIT_OP: if (mem_ready) state <= S_DECODE_OP;

                S_DECODE_OP: begin
                    mode_q   <= mem_rdata[3:0];
                    dli_q    <= mem_rdata[7];
                    lms_q    <= mem_rdata[6];
                    vscrol_q <= (mem_rdata[3:0] >= 4'd2) ? mem_rdata[5] : 1'b0;
                    hscrol_q <= (mem_rdata[3:0] >= 4'd2) ? mem_rdata[4] : 1'b0;
                    // DL PC wraps within its 1K block; JMP targets escape.
                    dl_pos   <= {dl_pos[15:10], dl_pos[9:0] + 10'd1};

                    if (mem_rdata[3:0] == 4'h0) begin
                        is_blank    <= 1'b1;
                        blank_count <= {2'b0, mem_rdata[6:4]} + 5'd1;
                        if (seen_mode) begin
                            state <= S_APPEND;
                        end else if ((lead_skipped + {5'd0, mem_rdata[6:4]} + 8'd1)
                                        <= LEAD_OVERSCAN) begin
                            // Skipped top-overscan blank — bookkeeping happens
                            // in S_SKIP from REGISTERED operands: gating the
                            // phantom-list write CE on raw mem_rdata put the
                            // shadow-BRAM clk-to-out plus decode in one cycle
                            // (timing violator, build 36f).
                            state <= S_SKIP;
                        end else begin
                            // Intentional vertical positioning — emit it.
                            state <= S_APPEND;
                        end
                    end else if (mem_rdata[3:0] == 4'h1) begin
                        is_blank <= 1'b0;
                        is_jvb   <= mem_rdata[6];
                        state    <= S_FETCH_JMP_LO;
                    end else if (mem_rdata[6]) begin
                        is_blank       <= 1'b0;
                        seen_mode      <= 1'b1;
                        lms_was_loaded <= 1'b1;
                        state          <= S_FETCH_LMS_LO;
                    end else begin
                        is_blank   <= 1'b0;
                        seen_mode  <= 1'b1;
                        state      <= S_APPEND;
                    end
                end

                // ---- LMS bytes ---------------------------------------
                S_FETCH_LMS_LO: begin
                    mem_raddr <= dl_pos;
                    state     <= S_WAIT_LMS_LO;
                end
                S_WAIT_LMS_LO: if (mem_ready) state <= S_LATCH_LMS_LO;
                S_LATCH_LMS_LO: begin
                    target_addr[7:0] <= mem_rdata;
                    dl_pos           <= {dl_pos[15:10], dl_pos[9:0] + 10'd1};
                    state            <= S_FETCH_LMS_HI;
                end
                S_FETCH_LMS_HI: begin
                    mem_raddr <= dl_pos;
                    state     <= S_WAIT_LMS_HI;
                end
                S_WAIT_LMS_HI: if (mem_ready) state <= S_LATCH_LMS_HI;
                S_LATCH_LMS_HI: begin
                    new_lms_loaded <= {mem_rdata, target_addr[7:0]};
                    dl_pos         <= {dl_pos[15:10], dl_pos[9:0] + 10'd1};
                    state          <= S_APPEND;
                end

                // ---- JMP / JVB target --------------------------------
                S_FETCH_JMP_LO: begin
                    mem_raddr <= dl_pos;
                    state     <= S_WAIT_JMP_LO;
                end
                S_WAIT_JMP_LO: if (mem_ready) state <= S_LATCH_JMP_LO;
                S_LATCH_JMP_LO: begin
                    target_addr[7:0] <= mem_rdata;
                    dl_pos           <= {dl_pos[15:10], dl_pos[9:0] + 10'd1};
                    state            <= S_FETCH_JMP_HI;
                end
                S_FETCH_JMP_HI: begin
                    mem_raddr <= dl_pos;
                    state     <= S_WAIT_JMP_HI;
                end
                S_WAIT_JMP_HI: begin
                    if (!mem_ready) begin
                        // hold — multi-cycle DMA fetch in progress
                    end else if (is_jvb) begin
                        // JVB ends the frame and SETS the DL PC to its target
                        // (next frame's parse continues from there).
                        dl_pos      <= {mem_rdata, target_addr[7:0]};
                        act_bank    <= wr_bank;
                        act_count   <= ecount;
                        act_carry_vs <= 1'b0;   // JVB line (vs=0) displays to the VBI
                        act_dli_cnt <= bld_dli_cnt;
                        ph_act_cnt  <= ph_bld_cnt;
                        for (i = 0; i < PH_N; i++) ph_act[i] <= ph_bld[i];
                        parse_done  <= 1'b1;
                        parse_count <= parse_count + 32'd1;
                        state       <= S_IDLE;
                    end else begin
                        target_addr[15:8] <= mem_rdata;
                        dl_pos            <= {mem_rdata, target_addr[7:0]};
                        state             <= S_FETCH_OP;
                    end
                end

                // ---- Skipped leading blank: phantom + lead bookkeeping ----
                S_SKIP: begin
                    // A DLI riding on a skipped blank is recorded at its TRUE
                    // physical last scan line (lead + count-1).
                    if (dli_q && ph_bld_cnt < PH_N[4:0]) begin
                        ph_bld[ph_bld_cnt] <=
                            8'(lead_skipped + {3'd0, blank_count} - 8'd1);
                        ph_bld_cnt <= ph_bld_cnt + 5'd1;
                    end
                    lead_skipped <= lead_skipped + {3'd0, blank_count};
                    state        <= S_FETCH_OP;
                end

                // ---- Append one entry --------------------------------
                S_APPEND: begin : sblk_append
                    logic [4:0]  sc;
                    logic [3:0]  emode;
                    logic [15:0] elms;
                    sc    = is_blank ? blank_count : scanline_count_for_mode(mode_q);
                    emode = is_blank ? 4'h0 : mode_q;
                    elms  = lms_was_loaded ? new_lms_loaded : lms_ptr;
                    // Emitted BLANK line carrying a DLI: physical phantom row
                    // (fires at true raster position; see the dli_at note).
                    if (is_blank && dli_q && ph_bld_cnt < PH_N[4:0])
                    begin
                        ph_bld[ph_bld_cnt] <= 8'(lead_skipped
                                                 + scan_total[7:0] + sc[4:0] - 5'd1);
                        ph_bld_cnt <= ph_bld_cnt + 5'd1;
                    end
                    eram[{wr_bank, ecount[7:0]}] <= {
                        4'(sc - 5'd1), emode, dli_q,
                        (is_blank ? 1'b0 : vscrol_q),
                        (is_blank ? 1'b0 : hscrol_q),
                        elms };
                    // Memory-scan advance for the NEXT line: within a 4K page
                    // (Altirra HW ref; ACID800 antic_addresswrap).
                    lms_ptr <= (emode >= 4'd2)
                                 ? {elms[15:12], 12'(elms[11:0]
                                     + 12'(bytes_per_line(emode,
                                           is_blank ? 1'b0 : hscrol_q)))}
                                 : elms;
                    if (dli_q) bld_dli_cnt <= bld_dli_cnt + 5'd1;
                    bld_last_vs <= is_blank ? 1'b0 : vscrol_q;
                    ecount     <= ecount + 9'd1;
                    scan_total <= scan_total + {5'd0, sc};
                    state      <= S_FETCH_OP;
                end

                default: state <= S_IDLE;
            endcase

            if (cold_abort && state != S_IDLE) begin
                // Cold-boot abort: retire the parse cleanly (do NOT publish).
                state       <= S_IDLE;
                parse_done  <= 1'b1;
            end
            if (dlistl_we_q || dlisth_we_q) dlist_dirty <= 1'b1;
            dlistl_we_q <= dlistl_we;
            dlisth_we_q <= dlisth_we;

            // ================= WALKER =================
            // Prefetch the advance candidate (entry w_idx+1) late in every
            // scanline; the flip at line_start picks it iff the line ended.
            if (prep_tick) begin
                pf_idx  <= pf_next_idx;
                pf_pend <= 1'b1;
                pf_q    <= eram[{act_bank, pf_next_idx[7:0]}];
            end else if (pf_pend) begin
                pf_pend <= 1'b0;
                if (pf_idx >= act_count) begin
                    nxt_blankfill <= 1'b1;
                    nxt_sc_m1     <= 4'd0;
                    nxt_mode      <= 4'd0;
                    nxt_dli       <= 1'b0;
                    nxt_vs        <= 1'b0;
                    nxt_hs        <= 1'b0;
                    nxt_lms       <= 16'h0;
                end else begin
                    nxt_blankfill <= 1'b0;
                    {nxt_sc_m1, nxt_mode, nxt_dli, nxt_vs, nxt_hs, nxt_lms}
                        <= pf_q;
                end
            end

            if (frame_start) begin
                // Prime: the first active line_start flips into entry 0.
                w_idx   <= 9'd0;
                w_boot  <= 1'b1;
                pf_idx  <= 9'd0;
                pf_pend <= 1'b1;
                pf_q    <= eram[{act_bank, 8'd0}];
                // The line straddling the frame end carries its VS bit into
                // the next frame's first line — published by the parse
                // (act_carry_vs): the straddling entry's rows sit beyond the
                // 192-row visible window, so the walker never reaches it.
                w_carry_vs <= act_carry_vs;
            end else if (line_start) begin
                if (w_boot) begin
                    // First displayed row of the frame: load entry 0.
                    w_boot    <= 1'b0;
                    w_prev_vs <= w_carry_vs;
                    {cur_sc_m1, cur_mode, cur_dli, cur_vs, cur_hs, cur_lms}
                              <= (act_count == 9'd0) ? 27'h0 : {nxt_sc_m1,
                                 nxt_mode, nxt_dli, nxt_vs, nxt_hs, nxt_lms};
                    // S: first-of-block against the carried-over VS state.
                    w_dctr    <= ((act_count != 9'd0) && nxt_vs && !w_carry_vs)
                                     ? vscrol : 4'd0;
                end else if (w_is_last) begin
                    // Advance to the prefetched entry; S latched NOW with the
                    // live VSCROL (first-of-block) else 0.
                    w_prev_vs <= cur_vs;
                    w_idx     <= pf_idx;
                    {cur_sc_m1, cur_mode, cur_dli, cur_vs, cur_hs, cur_lms}
                              <= {nxt_sc_m1, nxt_mode, nxt_dli, nxt_vs,
                                  nxt_hs, nxt_lms};
                    w_dctr    <= (nxt_vs && !cur_vs) ? vscrol : 4'd0;
                end else begin
                    w_dctr <= w_dctr + 4'd1;   // 4-bit DCTR wraps mod-16
                end
            end
        end
    end

endmodule

`default_nettype wire
