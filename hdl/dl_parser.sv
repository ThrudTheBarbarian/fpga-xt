// dl_parser.sv — walks the cpu_shadow display list once per VBI and
// produces per-atari-row metadata.
//
// Reads bytes via a single-port read interface to cpu_shadow (1-cycle
// BlockRAM latency). Output is a 192-entry table of:
//   line_mode[r]      4 bits   ANTIC mode (0 = blank, 1 = JMP/JVB, 2..F)
//   line_dli[r]       1 bit    DLI bit on the previous DL line
//   line_lms_addr[r]  16 bits  current LMS pointer for this row's data
//   line_sub_row[r]   4 bits   sub-row within the DL line (0..scan_count-1)
//
// Output is exposed as a row-index lookup port (`meta_row` →
// `meta_*`) backed by 192-entry distributed RAM. M5 covers:
//   - Blank lines ($00 with bits 4..6 = scanline count - 1)
//   - JMP ($01) / JVB ($41) with 2-byte target
//   - Text + graphics modes 2..F (with scan counts per mode)
//   - LMS option bit (loads cur_lms from 2-byte address that follows)
//   - DLI option bit (sets line_dli on the FIRST scan line of the
//     NEXT DL line, matching real ANTIC's "fire at end of line" semantic)
//
// M11: per-row HSCROL / VSCROL enable bits captured from inst[4] /
// inst[5]. The compositor uses these together with the live HSCROL /
// VSCROL register values to scroll. char_row tracking still deferred.
//
// M11d/M11e: VSCROL region accounting, modelled on the real ANTIC DCTR
// (the 4-bit within-mode-line scan counter) and its VSCROL comparison.
// Each emitted DL line runs the DCTR from a START value S, incrementing
// (wrapping mod-16), and ends AFTER the scan line where DCTR == a TERMINAL
// value E.  Row count = ((E - S) & 15) + 1.  VSCROL modifies S and E only
// at the two edges of a scroll region, decided purely from the CURRENT
// line's own VSCROL bit and the PREVIOUS emitted line's VSCROL bit — no
// look-ahead to the next line is needed:
//   - first-of-block  (cur.vs && !prev.vs): S = VSCROL, E = mode_h-1.
//        emits ((mode_h-1 - VSCROL) & 15)+1 rows.  When VSCROL >= mode_h
//        the DCTR wraps past 15 → a long line (the ANTIC "over-scroll"
//        quirk, e.g. mode 2 + VSCROL 9 shows 15 scan lines).
//   - last-of-block   (!cur.vs && prev.vs): S = 0, E = VSCROL.
//        emits VSCROL+1 rows.  This is the NON-vscrol line that FOLLOWS a
//        scroll region (mode OR blank) — it grows/shrinks, not the last
//        line that still carries the VSCROL bit.
//   - middle / normal (else): S = 0, E = scan_count-1 → full height.
// S (=pend_init_sub) and E (=pend_eff_end) are computed once, when a line
// is stashed into "pending", using the previous line's VSCROL bit (which
// is exactly pend_vscrol_en at REFILL time, before it is overwritten).
// The 1-DL-line pending buffer is retained for LMS auto-advance and the
// "DLI fires at end of the flagged line" semantics.
//   At end-of-DL (JVB or atari_row >= ATARI_H) the final pending is
//   flushed using its already-computed S/E.
//
// NOTE (out of scope for this module): a DLI that rewrites VSCROL *mid*
// frame (ACID800 antic_vscroll / antic_vscroldli) changes the region size
// live, per raster line.  dl_parser builds one static table per VBI from
// the VSCROL value latched at parse time, so it cannot reproduce a mid-
// frame VSCROL change — that belongs to the live raster/compositor path.
//
// Reference: rp-antic/src/display_list.c § parse_display_list().

`default_nettype none

module dl_parser (
    input  wire         clk,
    input  wire         rst,

    // Trigger: pulse to (re)start a parse from DLIST{H,L}.
    input  wire         start_parse,

    // ANTIC register inputs.
    input  wire [7:0]   dlistl,
    input  wire [7:0]   dlisth,
    input  wire [3:0]   vscrol,            // VSCROL ($D405) — sub-row offset
                                           // applied at the first row of a
                                           // VSCROL block; emit-end clipped at
                                           // last-of-block (M11d).

    // cpu_shadow / DMA read port. We drive the address; rdata arrives
    // 1 cycle later in snoop mode, or after the DMA fetch completes
    // when M16-int's mem_read_mux routes us through dma_master. The
    // mem_ready input gates each WAIT state's advance so the multi-
    // cycle DMA path doesn't read stale data; mem_req pulses for one
    // cycle at the start of each fetch so the adapter knows to trigger
    // a fresh DMA cycle (back-to-back same-address reads still work).
    output logic [15:0] mem_raddr,
    input  wire  [7:0]  mem_rdata,
    output wire         mem_req,
    input  wire         mem_ready,

    // Per-row metadata read port. Consumer presents row (0..191), gets
    // metadata back combinationally.
    input  wire  [7:0]  meta_row,
    output wire  [3:0]  meta_mode,
    output wire         meta_dli,
    output wire  [15:0] meta_lms_addr,
    output wire  [3:0]  meta_sub_row,
    output wire         meta_hscrol_en,
    output wire         meta_vscrol_en,

    // Second read port — DLI-only. nmi_gen drives this with the live
    // vbeam atari_row to decide whether to fire NMI on each row
    // transition.
    input  wire  [7:0]  dli_row,
    output wire         dli_at,
    // TEMP diag: snapshot of line_dli_p at the rows pfstart's DL should flag
    // ($F0 blank-8+DLI at rows 23/41 etc.) so we can see WHICH rows dl_parser
    // records — vs the row nmi_gen looks up.
    output wire  [7:0]  dbg_dli_rows,
    output wire  [4:0]  dbg_dli_cnt,       // # of DLI rows recorded this parse
    output wire         dbg_dli_has23,     // list contains raster row 23

    // Status.
    output logic        parse_done,        // pulses after each parse pass
    output logic [31:0] parse_count
);

    localparam int ATARI_H = 192;
    // Leading blank-line scanlines to treat as TOP OVERSCAN and skip (a normal
    // 2-3 blank-8 OS/game margin). Blanks BEYOND this are intentional vertical
    // positioning (e.g. a centred title/intro screen) and MUST be emitted as
    // visible COLBK rows, or the content collapses to the top (DR MASTERTRONIC
    // title + coloured-bars rendered squashed into the top band).
    localparam [7:0] LEAD_OVERSCAN = 8'd24;
    localparam int OPS_LIMIT = 1024;       // safety against malformed JMP loops

    // ---- Per-row metadata storage --------------------------------------
    logic [3:0]  line_mode      [0:ATARI_H-1];
    logic        line_dli       [0:ATARI_H-1];
    logic [15:0] line_lms_addr  [0:ATARI_H-1];
    logic [3:0]  line_sub_row   [0:ATARI_H-1];
    logic        line_hscrol_en [0:ATARI_H-1];
    logic        line_vscrol_en [0:ATARI_H-1];

    // Physical-scanline DLI map — indexed by the PHYSICAL display row
    // (ar_atari_row = raster scanline - DISPLAY_TOP), NOT the compressed
    // emit-row space that line_dli[] lives in.  nmi_gen looks up DLIs via
    // `dli_at` using the LIVE raster row, so the two spaces MUST agree.  The
    // compressed line_dli[] diverges from the raster row by the leading-
    // overscan skip (and drops DLIs on skipped/late blank lines), which made
    // real-HW DLIs fire at the wrong scan line — or not at all — even though
    // the unit sims (which drive the compressed row directly) passed.  This
    // table is built in raster-row space: phys_row = lead_skipped + atari_row
    // for emitted content, lead_skipped-relative for skipped leading blanks.
    // Real ANTIC raises the DLI on the LAST scan line of the flagged DL line.
    //
    // MUST be flip-flops, not RAM.  `dli_at = line_dli_p[dli_row]` is a
    // variable-index read that closes a combinational loop back through nmi_gen
    // (dli_row comes from nmi_gen.cur_row).  Left to infer, Vivado builds this
    // 1-bit table as distributed RAM whose read does NOT match the parallel
    // constant-index reads: on hardware line_dli_p[23] reads 1 by constant
    // index yet dli_at reads 0 for dli_row=23, so the DLI never fires even
    // though the table is correct (measured — the whole ACID800 DLI cluster).
    // Forcing registers makes the variable read behave exactly like the sim's
    // array read.
    (* ram_style = "registers" *)
    logic        line_dli_p     [0:ATARI_H-1];

    // DLI ROW LIST — replaces the fragile 240-entry line_dli_p[dli_row] variable
    // read.  A DL frame has only a handful of DLI rows, so record them (physical
    // raster rows) in a small list and match the live raster row with parallel
    // comparators.  This is a clean flop file + N-way compare with NO variable-
    // index array read/write, which on hardware silently mis-behaved (line_dli_p
    // set correctly yet dli_at read 0 — the whole ACID800 DLI cluster).
    localparam int DLI_LIST_N = 24;
    logic [7:0]  dli_list [0:DLI_LIST_N-1];
    logic [4:0]  dli_cnt;

    // Read port: combinational lookup.
    assign meta_mode       = line_mode      [meta_row[7:0]];
    assign meta_dli        = line_dli       [meta_row[7:0]];
    assign meta_lms_addr   = line_lms_addr  [meta_row[7:0]];
    assign meta_sub_row    = line_sub_row   [meta_row[7:0]];
    assign meta_hscrol_en  = line_hscrol_en [meta_row[7:0]];
    assign meta_vscrol_en  = line_vscrol_en [meta_row[7:0]];

    // dli_at = the live raster row matches any recorded DLI row.
    logic dli_hit;
    always_comb begin
        dli_hit = 1'b0;
        for (int k = 0; k < DLI_LIST_N; k++)
            if (k < dli_cnt && dli_list[k] == dli_row[7:0]) dli_hit = 1'b1;
    end
    assign dli_at = dli_hit;
    assign dbg_dli_cnt = dli_cnt;
    logic has23;
    always_comb begin
        has23 = 1'b0;
        for (int k = 0; k < DLI_LIST_N; k++)
            if (k < dli_cnt && dli_list[k] == 8'd23) has23 = 1'b1;
    end
    assign dbg_dli_has23 = has23;
    // rows 8,16,22,23,24,25,40,41 — pfstart's first two $F0 DLIs land at 23 & 41
    assign dbg_dli_rows = {line_dli_p[41], line_dli_p[40], line_dli_p[25],
                           line_dli_p[24], line_dli_p[23], line_dli_p[22],
                           line_dli_p[16], line_dli_p[8]};

    // ---- FSM -----------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_FETCH_OP      = 4'd1,    // request opcode read at dl_pos
        S_WAIT_OP       = 4'd2,    // wait 1 cycle for BRAM read
        S_DECODE_OP     = 4'd3,    // mem_rdata = opcode, classify
        S_FETCH_LMS_LO  = 4'd4,
        S_WAIT_LMS_LO   = 4'd5,
        S_LATCH_LMS_LO  = 4'd6,
        S_FETCH_LMS_HI  = 4'd7,
        S_WAIT_LMS_HI   = 4'd8,
        S_LATCH_LMS_HI  = 4'd9,
        S_FETCH_JMP_LO  = 4'd10,
        S_WAIT_JMP_LO   = 4'd11,
        S_LATCH_JMP_LO  = 4'd12,
        S_FETCH_JMP_HI  = 4'd13,
        S_WAIT_JMP_HI   = 4'd14,
        S_STAGE         = 4'd15
        // S_EMIT_ROWS / S_REFILL_PEND share encodings via case-default;
        // see emit_phase reg below to disambiguate.
    } state_t;

    // Sub-state for the emit/refill cycle. Reusing S_STAGE for the
    // entry; emit_phase tracks which step we're in:
    //   STAGE     — decide what to do with pending given decoded
    //   EMIT      — walk sub_rows 0..pend_eff_end-1 of pending
    //   REFILL    — copy decoded into pending (after emit completes)
    //   FLUSH_END — final emit of pending hit JVB / end-of-DL; finish
    typedef enum logic [1:0] {
        E_STAGE     = 2'd0,
        E_EMIT      = 2'd1,
        E_REFILL    = 2'd2,
        E_FLUSH_END = 2'd3
    } emit_phase_t;

    // Pulse mem_req for exactly one cycle on each FETCH→WAIT transition.
    // - WAIT is when mem_raddr's NBA has settled and the address is
    //   valid for the DMA adapter to capture.
    // - The pulse must NOT be held high through a stalling WAIT, or
    //   mem_read_mux would re-trigger on its D_BUSY→D_READY return.
    // Implementation: register "previous state was a FETCH" and use it
    // as the req strobe.
    state_t state;
    logic   prev_state_was_fetch;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            prev_state_was_fetch <= 1'b0;
        else
            prev_state_was_fetch <= (state == S_FETCH_OP)
                                  || (state == S_FETCH_LMS_LO)
                                  || (state == S_FETCH_LMS_HI)
                                  || (state == S_FETCH_JMP_LO)
                                  || (state == S_FETCH_JMP_HI);
    end
    assign mem_req = prev_state_was_fetch;

    emit_phase_t  emit_phase;

    // Display-list pointer. Per Altirra §4.6, ANTIC's normal
    // DL-fetch increment is split: only the lower 10 bits advance,
    // and the top 6 bits stay frozen during the parse — so a DL
    // straddling a 1 KB boundary wraps from $xxFF → $x000 (within
    // the same 1 KB block) instead of crossing into the next block.
    // Jump-instruction targets still load the full 16 bits, so JMP /
    // JVB can move out of the current 1 KB region.
    logic [15:0] dl_pos;            // current DL byte address
    logic [15:0] lms_ptr;            // running LMS pointer (was cur_lms)
    logic [15:0] target_addr;       // JMP/JVB target / LMS scratch
    logic [15:0] new_lms_loaded;    // LMS captured by S_LATCH_LMS_HI
    logic        lms_was_loaded;    // 1 if decoded line had LMS bit
    logic [7:0]  inst;              // current opcode
    logic [3:0]  mode_q;            // mode bits of current opcode (decoded)
    logic        dli_q;             // DLI bit  (inst[7])
    logic        lms_q;             // LMS bit  (inst[6])
    logic        vscrol_q;          // VSCROL enable (inst[5])
    logic        hscrol_q;          // HSCROL enable (inst[4])
    logic        is_jvb;            // current $41 JVB (vs $01 JMP)
    logic        is_blank;          // decoded line is a blank ($00)
    logic [4:0]  blank_count;       // blank-line scan count (1..8)
    logic [7:0]  lead_skipped;      // leading-blank scanlines skipped as overscan
    logic        seen_mode;         // a visible mode line (2..F) has been
                                    // emitted this frame. Leading blanks (before
                                    // the first mode line) are top overscan and
                                    // are skipped so they don't consume rows;
                                    // blanks AFTER it are interior bands and DO
                                    // emit COLBK rows. See video-arch §5.1.

    // ---- Pending (1-DL-line buffer; decoded before emit) ---------------
    logic        pend_valid;
    logic [3:0]  pend_mode;
    logic        pend_dli;
    logic        pend_vscrol_en;
    logic        pend_hscrol_en;
    logic [15:0] pend_lms;
    logic [3:0]  pend_init_sub;      // S: DCTR start value (first emitted sub_row)
    logic [4:0]  pend_eff_end;       // E: terminal DCTR value; emit ends when sub_row==E

    // ---- Emit walker ----------------------------------------------------
    logic [3:0]  sub_row;             // current sub_row within the emitting pend
    logic [7:0]  atari_row;           // 0..ATARI_H-1
    logic [10:0] ops;                 // ops counter (safety)
    logic        pending_dli;         // DLI to fire on FIRST emitted row of next pend
    logic        pending_dli_is_mode; // pending_dli came from a visible mode line
                                      // (uses compressed compositor-aligned position)
                                      // vs a blank line (uses physical position)

    // ANTIC mode → scan count per DL line. Max is 16 (modes 5/7).
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

    // Bytes ANTIC fetches (and advances the memory scan by) for one mode line.
    // A line with HSCROL enabled is fetched one playfield-width WIDER (NORMAL->WIDE,
    // +20%: 40->48, 20->24, 10->12) so there is data to scroll in from the right, and
    // the scan pointer advances by that wider count.  Ignoring this drifts every
    // HSCROL char line 8 bytes short of the previous — Despatch Rider's bottom view
    // (mode-4 + HSCROL, 48-byte rows) "spread out" until this was accounted for.
    // (DMACTL NARROW base is not modelled; DR and the OS use NORMAL.)
    function automatic logic [15:0] bytes_per_line(logic [3:0] m, logic hs);
        case (m)
            4'h2, 4'h3, 4'h4, 4'h5: return hs ? 16'd48 : 16'd40;   // text modes
            4'h6, 4'h7:              return hs ? 16'd24 : 16'd20;   // 20-col text
            4'h8, 4'h9:              return hs ? 16'd12 : 16'd10;   // low-res gfx
            4'hA, 4'hB, 4'hC:        return hs ? 16'd24 : 16'd20;
            4'hD, 4'hE, 4'hF:        return hs ? 16'd48 : 16'd40;
            default:                 return 16'd0;
        endcase
    endfunction

    // ---- FSM body ------------------------------------------------------
    integer i;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            emit_phase      <= E_STAGE;
            dl_pos          <= 16'h0;
            lms_ptr         <= 16'h0;
            target_addr     <= 16'h0;
            new_lms_loaded  <= 16'h0;
            lms_was_loaded  <= 1'b0;
            inst            <= 8'h0;
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
            pend_valid      <= 1'b0;
            pend_mode       <= 4'h0;
            pend_dli        <= 1'b0;
            pend_vscrol_en  <= 1'b0;
            pend_hscrol_en  <= 1'b0;
            pend_lms        <= 16'h0;
            pend_init_sub   <= 4'h0;
            pend_eff_end    <= 5'd0;
            sub_row         <= 4'd0;
            atari_row       <= 8'd0;
            ops             <= 11'd0;
            pending_dli     <= 1'b0;
            pending_dli_is_mode <= 1'b0;
            parse_done      <= 1'b0;
            parse_count     <= 32'h0;
            mem_raddr       <= 16'h0;
            for (i = 0; i < ATARI_H; i++) begin
                line_mode[i]      <= 4'h0;
                line_dli[i]       <= 1'b0;
                line_lms_addr[i]  <= 16'h0;
                line_sub_row[i]   <= 4'h0;
                line_hscrol_en[i] <= 1'b0;
                line_vscrol_en[i] <= 1'b0;
                line_dli_p[i]     <= 1'b0;
            end
            dli_cnt <= 5'd0;
        end else begin
            parse_done <= 1'b0;     // single-cycle pulse

            unique case (state)
                S_IDLE: begin
                    if (start_parse) begin
                        dl_pos         <= {dlisth, dlistl};
                        lms_ptr        <= 16'h0;
                        atari_row      <= 8'd0;
                        ops            <= 11'd0;
                        pending_dli    <= 1'b0;
                        pending_dli_is_mode <= 1'b0;
                        pend_valid     <= 1'b0;
                        seen_mode      <= 1'b0;
                        lead_skipped   <= 8'd0;
                        emit_phase     <= E_STAGE;
                        state          <= S_FETCH_OP;
                        // Physical DLI map is written sparsely (only on DLI
                        // lines' last scan line), so clear it every parse or
                        // stale bits from a prior frame's DL would fire phantom
                        // NMIs.  Parallel reset (same as the master reset loop);
                        // the whole VBI is available before the first fetch.
                        for (i = 0; i < ATARI_H; i++) line_dli_p[i] <= 1'b0;
                        dli_cnt <= 5'd0;   // clear the DLI row list for a new parse
                    end
                end

                S_FETCH_OP: begin
                    if (atari_row >= ATARI_H[7:0] || ops >= OPS_LIMIT[10:0]) begin
                        // End-of-DL or safety abort. Flush pending if any.
                        if (pend_valid) begin
                            // Flush trailing pending using its already-computed
                            // S (pend_init_sub) / E (pend_eff_end).
                            sub_row    <= pend_init_sub;
                            emit_phase <= E_FLUSH_END;
                            state      <= S_STAGE;
                        end else begin
                            parse_done  <= 1'b1;
                            parse_count <= parse_count + 32'd1;
                            state       <= S_IDLE;
                        end
                    end else begin
                        mem_raddr      <= dl_pos;
                        ops            <= ops + 11'd1;
                        lms_was_loaded <= 1'b0;
                        state          <= S_WAIT_OP;
                    end
                end

                S_WAIT_OP: if (mem_ready) state <= S_DECODE_OP;

                S_DECODE_OP: begin
                    inst     <= mem_rdata;
                    mode_q   <= mem_rdata[3:0];
                    dli_q    <= mem_rdata[7];
                    lms_q    <= mem_rdata[6];
                    // HSCROL/VSCROL bits only meaningful for visible-mode
                    // lines (mode 2..F). Blank/JMP bytes use these bits
                    // for other purposes.
                    vscrol_q <= (mem_rdata[3:0] >= 4'd2) ? mem_rdata[5] : 1'b0;
                    hscrol_q <= (mem_rdata[3:0] >= 4'd2) ? mem_rdata[4] : 1'b0;
                    dl_pos   <= {dl_pos[15:10], dl_pos[9:0] + 10'd1};

                    if (mem_rdata[3:0] == 4'h0) begin
                        // Blank line: bits 4..6 = scan_count - 1.
                        is_blank    <= 1'b1;
                        blank_count <= {2'b0, mem_rdata[6:4]} + 5'd1;
                        if (seen_mode) begin
                            // Interior/trailing blank: emit it (the compositor
                            // paints these rows COLBK) so a mid-screen blank band
                            // renders and the writeback gets a written row.
                            state       <= S_STAGE;
                            emit_phase  <= E_STAGE;
                        end else if ((lead_skipped + {5'd0, mem_rdata[6:4]} + 8'd1)
                                        <= LEAD_OVERSCAN) begin
                            // Leading blank within the top-overscan budget — skip so
                            // the playfield tops out correctly (a normal 2-3 blank-8
                            // OS/game margin). Must NOT consume an atari_row or the
                            // playfield shoves down + bottom mode lines clip.
                            // BUT a skipped blank can still carry a DLI (ACID800
                            // antic_dlitiming's $90 blank-2-line+DLI list): record it
                            // in physical space at its LAST scan line so the NMI still
                            // fires at the right raster row.  phys = lead_skipped +
                            // (blank_count-1) = lead_skipped + mem_rdata[6:4].
                            if (mem_rdata[7]
                                && (lead_skipped + {5'd0, mem_rdata[6:4]}) < ATARI_H[7:0]) begin
                                line_dli_p[lead_skipped + {5'd0, mem_rdata[6:4]}] <= 1'b1;
                                if (dli_cnt < DLI_LIST_N[4:0]) begin
                                    dli_list[dli_cnt] <= lead_skipped + {5'd0, mem_rdata[6:4]};
                                    dli_cnt <= dli_cnt + 5'd1;
                                end
                            end
                            lead_skipped <= lead_skipped + {5'd0, mem_rdata[6:4]} + 8'd1;
                            state        <= S_FETCH_OP;
                        end else begin
                            // Leading blanks BEYOND the overscan budget are intentional
                            // vertical positioning (centred title / intro) — EMIT them
                            // as visible COLBK rows so the content lands at the right
                            // scanline instead of collapsing into the top band.
                            state        <= S_STAGE;
                            emit_phase   <= E_STAGE;
                        end
                    end else if (mem_rdata[3:0] == 4'h1) begin
                        // JMP ($01) / JVB ($41) — bit 6 distinguishes.
                        is_blank <= 1'b0;
                        is_jvb   <= mem_rdata[6];
                        state    <= S_FETCH_JMP_LO;
                    end else if (mem_rdata[6]) begin
                        // LMS-bearing graphics/text mode. Read 2-byte LMS,
                        // then stage.
                        is_blank       <= 1'b0;
                        seen_mode      <= 1'b1;
                        lms_was_loaded <= 1'b1;
                        state          <= S_FETCH_LMS_LO;
                    end else begin
                        // Plain mode line — auto-advance LMS at REFILL.
                        is_blank   <= 1'b0;
                        seen_mode  <= 1'b1;
                        state      <= S_STAGE;
                        emit_phase <= E_STAGE;
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
                    state          <= S_STAGE;
                    emit_phase     <= E_STAGE;
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
                        // JVB ends the frame. Flush any trailing pending
                        // using its already-computed S/E.
                        if (pend_valid) begin
                            sub_row    <= pend_init_sub;
                            emit_phase <= E_FLUSH_END;
                            state      <= S_STAGE;
                        end else begin
                            parse_done  <= 1'b1;
                            parse_count <= parse_count + 32'd1;
                            state       <= S_IDLE;
                        end
                    end else begin
                        target_addr[15:8] <= mem_rdata;
                        dl_pos            <= {mem_rdata, target_addr[7:0]};
                        state             <= S_FETCH_OP;
                    end
                end

                // ==== STAGE / EMIT / REFILL ==================================
                // Triple-purpose state, dispatched on emit_phase.
                S_STAGE: begin
                    case (emit_phase)
                        E_STAGE: begin : sblk_stage
                            // Decide what to do with pending given decoded.
                            // For blank/non-LMS visible/LMS visible we land here
                            // with mode_q / vscrol_q / hscrol_q reflecting the
                            // decoded line; is_blank picks whether mode_q is 0.
                            logic        decoded_vs;
                            logic [4:0]  sc;
                            decoded_vs = is_blank ? 1'b0 : vscrol_q;
                            sc         = is_blank ? blank_count
                                                  : scanline_count_for_mode(mode_q);

                            if (pend_valid) begin
                                // S/E were computed when this pending was filled
                                // (first-stash or REFILL); just launch the walk.
                                sub_row    <= pend_init_sub;
                                emit_phase <= E_EMIT;
                                // stay in S_STAGE; emit phase handles the walk
                            end else begin
                                // First decode — stash without emit. lms_ptr
                                // updates from new_lms_loaded if LMS bit was set.
                                // The line before the first DL line is treated as
                                // non-VSCROL (frame top), so first-of-block ==
                                // (this line has the VSCROL bit).  last-of-block
                                // can't apply to the very first line.
                                if (lms_was_loaded) lms_ptr <= new_lms_loaded;
                                pend_mode      <= is_blank ? 4'h0 : mode_q;
                                pend_dli       <= dli_q;
                                pend_vscrol_en <= decoded_vs;
                                pend_hscrol_en <= is_blank ? 1'b0 : hscrol_q;
                                pend_lms       <= lms_was_loaded
                                                    ? new_lms_loaded
                                                    : lms_ptr;
                                // first-of-block: S = VSCROL; else S = 0.
                                pend_init_sub  <= decoded_vs ? vscrol : 4'd0;
                                // no last-of-block on line 0 → E = scan_count-1.
                                pend_eff_end   <= sc - 5'd1;
                                pend_valid     <= 1'b1;
                                state          <= S_FETCH_OP;
                                emit_phase     <= E_STAGE;
                            end
                        end

                        E_EMIT, E_FLUSH_END: begin : sblk_emit
                            // Physical raster row for this emitted scan line:
                            // leading-overscan scanlines were skipped without
                            // consuming an atari_row, so the raster row lags the
                            // compressed atari_row by exactly lead_skipped.
                            logic [8:0] phys_r;
                            phys_r = {1'b0, lead_skipped} + {1'b0, atari_row};
                            if (atari_row < ATARI_H[7:0]) begin
                                line_mode[atari_row]      <= pend_mode;
                                line_sub_row[atari_row]   <= sub_row;
                                line_lms_addr[atari_row]  <= pend_lms;
                                line_hscrol_en[atari_row] <= pend_hscrol_en;
                                line_vscrol_en[atari_row] <= pend_vscrol_en;
                                line_dli[atari_row]       <=
                                    (sub_row == pend_init_sub) ? pending_dli : 1'b0;
                                // Physical DLI map (what nmi_gen reads), hybrid by
                                // source line type so BOTH real games and the ACID800
                                // raster tests are served despite the leading-overscan
                                // compression the compositor relies on:
                                //  - VISIBLE mode-line DLIs keep the COMPRESSED,
                                //    compositor-aligned "fire on the next line's first
                                //    row" convention (via pending_dli, deferred here),
                                //    so per-scanline colour DLIs still land on the row
                                //    the compositor actually draws (top-aligned).  A
                                //    physical index would drop them lead_skipped rows
                                //    too low.
                                //  - BLANK-line DLIs are recorded at their TRUE
                                //    physical last scan line (below).  ACID800 nmist/
                                //    dlitiming/pfstart-stop hang their DLIs on blank
                                //    lines precisely to probe raster timing, and carry
                                //    no compositor content to align against.
                                if ((sub_row == pend_init_sub)
                                    && pending_dli && pending_dli_is_mode) begin
                                    line_dli_p[atari_row] <= 1'b1;
                                    if (dli_cnt < DLI_LIST_N[4:0]) begin
                                        dli_list[dli_cnt] <= atari_row;
                                        dli_cnt <= dli_cnt + 5'd1;
                                    end
                                end
                                atari_row <= atari_row + 8'd1;
                                sub_row   <= sub_row + 4'd1;    // 4-bit DCTR wraps mod-16
                                if ({1'b0, sub_row} == pend_eff_end) begin
                                    // Terminal DCTR reached: the DL line's last
                                    // physical scan line, where real ANTIC raises
                                    // the DLI.  Only blank lines record here (physical);
                                    // mode lines defer to the compressed path above.
                                    if (pend_dli && pend_mode == 4'd0
                                        && phys_r < {1'b0, ATARI_H[7:0]}) begin
                                        line_dli_p[phys_r[7:0]] <= 1'b1;
                                        if (dli_cnt < DLI_LIST_N[4:0]) begin
                                            dli_list[dli_cnt] <= phys_r[7:0];
                                            dli_cnt <= dli_cnt + 5'd1;
                                        end
                                    end
                                    pending_dli         <= pend_dli;
                                    pending_dli_is_mode <= (pend_mode >= 4'd2);
                                    if (emit_phase == E_FLUSH_END) begin
                                        parse_done  <= 1'b1;
                                        parse_count <= parse_count + 32'd1;
                                        state       <= S_IDLE;
                                    end else begin
                                        emit_phase <= E_REFILL;
                                    end
                                end
                            end else begin
                                // Hit ATARI_H mid-emit. Done.
                                parse_done  <= 1'b1;
                                parse_count <= parse_count + 32'd1;
                                state       <= S_IDLE;
                            end
                        end

                        E_REFILL: begin : sblk_refill
                            // Advance lms_ptr by emitted line's bpl, then
                            // override with new_lms_loaded if decoded had LMS.
                            logic [15:0] adv;
                            logic [15:0] new_lms_after_load;
                            // VSCROL edge decision for the NEW (decoded) line.
                            // prev.vs is the OLD pending's vscrol_en (the line we
                            // just emitted) — still valid here as pend_vscrol_en
                            // has not yet been overwritten.  vscrol_q is already
                            // gated to 0 for mode < 2 in S_DECODE_OP, so new_vs
                            // implies a real visible-mode VSCROL line.
                            logic        new_vs;
                            logic        first_of_block;
                            logic        last_of_block;
                            logic [4:0]  sc;
                            adv = (pend_mode >= 4'd2)
                                    ? lms_ptr + bytes_per_line(pend_mode, pend_hscrol_en)
                                    : lms_ptr;
                            new_lms_after_load = lms_was_loaded ? new_lms_loaded : adv;
                            lms_ptr        <= new_lms_after_load;

                            new_vs         = is_blank ? 1'b0 : vscrol_q;
                            first_of_block = new_vs  && !pend_vscrol_en;
                            last_of_block  = !new_vs &&  pend_vscrol_en;
                            sc             = is_blank ? blank_count
                                                     : scanline_count_for_mode(mode_q);

                            // Copy decoded → pending.
                            pend_mode      <= is_blank ? 4'h0 : mode_q;
                            pend_dli       <= dli_q;
                            pend_vscrol_en <= new_vs;
                            pend_hscrol_en <= is_blank ? 1'b0 : hscrol_q;
                            pend_lms       <= new_lms_after_load;
                            // S: first-of-block starts at VSCROL, else 0.
                            pend_init_sub  <= first_of_block ? vscrol : 4'd0;
                            // E: last-of-block ends at DCTR==VSCROL (VSCROL+1 rows);
                            //    else at scan_count-1 (full height).  A first-of-
                            //    block line with VSCROL >= mode height wraps the DCTR
                            //    past 15 → the ANTIC over-scroll long line.
                            pend_eff_end   <= last_of_block ? {1'b0, vscrol}
                                                            : (sc - 5'd1);
                            // pend_valid stays 1.
                            state          <= S_FETCH_OP;
                            emit_phase     <= E_STAGE;
                        end

                        default: ; // unreachable
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
