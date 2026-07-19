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
// M11d: VSCROL last-row truncation. The DL is now parsed with a
// 1-DL-line buffer: after a line is decoded into the "decoded" regs,
// it is staged into "pending" only after the prior pending has emitted
// (or, on the first decode, stashed without emitting). This lets the
// emit step look at the FRESHLY-DECODED line's vscrol bit to decide
// whether the pending line is the LAST line of a vscroll block:
//   - First-of-block (pend_vscrol_en && !prev_pend_vscrol_en): sub_row
//     starts at VSCROL → emits scan_count - VSCROL rows.
//   - Last-of-block (pend_vscrol_en && !decoded_vscrol_en && pend was
//     not also first-of-block): emits sub_rows 0..VSCROL → VSCROL+1 rows.
//   - Middle: emits scan_count rows starting at sub_row 0.
//   At end-of-DL (JVB or atari_row >= ATARI_H), the final pending is
//   flushed with last-of-block treatment.
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

    // Read port: combinational lookup.
    assign meta_mode       = line_mode      [meta_row[7:0]];
    assign meta_dli        = line_dli       [meta_row[7:0]];
    assign meta_lms_addr   = line_lms_addr  [meta_row[7:0]];
    assign meta_sub_row    = line_sub_row   [meta_row[7:0]];
    assign meta_hscrol_en  = line_hscrol_en [meta_row[7:0]];
    assign meta_vscrol_en  = line_vscrol_en [meta_row[7:0]];
    assign dli_at          = line_dli       [dli_row[7:0]];

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
    logic [3:0]  pend_init_sub;
    logic [4:0]  pend_eff_end;       // emit sub_row in [pend_init_sub, pend_eff_end-1]
    logic [3:0]  pend_vscrol_val;    // VSCROL register snapshot at pend's decode time
    logic [4:0]  pend_scan_count;    // natural scan count (for blank lines this = blank_count)

    // ---- Emit walker ----------------------------------------------------
    logic [3:0]  sub_row;             // current sub_row within the emitting pend
    logic [7:0]  atari_row;           // 0..ATARI_H-1
    logic [10:0] ops;                 // ops counter (safety)
    logic        pending_dli;         // DLI to fire on FIRST emitted row of next pend

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
            pend_vscrol_val <= 4'h0;
            pend_scan_count <= 5'd1;
            sub_row         <= 4'd0;
            atari_row       <= 8'd0;
            ops             <= 11'd0;
            pending_dli     <= 1'b0;
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
            end
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
                        pend_valid     <= 1'b0;
                        seen_mode      <= 1'b0;
                        lead_skipped   <= 8'd0;
                        emit_phase     <= E_STAGE;
                        state          <= S_FETCH_OP;
                    end
                end

                S_FETCH_OP: begin
                    if (atari_row >= ATARI_H[7:0] || ops >= OPS_LIMIT[10:0]) begin
                        // End-of-DL or safety abort. Flush pending if any.
                        if (pend_valid) begin
                            // Last-of-block treatment for trailing pending.
                            if (pend_vscrol_en && pend_init_sub == 4'd0)
                                pend_eff_end <= {1'b0, pend_vscrol_val} + 5'd1;
                            else
                                pend_eff_end <= pend_scan_count;
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
                        // with last-of-block treatment.
                        if (pend_valid) begin
                            if (pend_vscrol_en && pend_init_sub == 4'd0)
                                pend_eff_end <= {1'b0, pend_vscrol_val} + 5'd1;
                            else
                                pend_eff_end <= pend_scan_count;
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
                            decoded_vs = is_blank ? 1'b0 : vscrol_q;

                            if (pend_valid) begin
                                // Determine pend_eff_end based on lookahead.
                                // Last-of-block when pend has VSCROL bit, the
                                // decoded line does NOT, AND pend wasn't itself
                                // first-of-block (init_sub == 0). The first-of-
                                // block clamp wins for single-line blocks.
                                if (pend_vscrol_en && !decoded_vs
                                    && pend_init_sub == 4'd0)
                                    pend_eff_end <= {1'b0, pend_vscrol_val} + 5'd1;
                                else
                                    pend_eff_end <= pend_scan_count;
                                sub_row    <= pend_init_sub;
                                emit_phase <= E_EMIT;
                                // stay in S_STAGE; emit phase handles the walk
                            end else begin
                                // First decode — stash without emit. lms_ptr
                                // updates from new_lms_loaded if LMS bit was set.
                                if (lms_was_loaded) lms_ptr <= new_lms_loaded;
                                pend_mode      <= is_blank ? 4'h0 : mode_q;
                                pend_dli       <= dli_q;
                                pend_vscrol_en <= decoded_vs;
                                pend_hscrol_en <= is_blank ? 1'b0 : hscrol_q;
                                pend_lms       <= lms_was_loaded
                                                    ? new_lms_loaded
                                                    : lms_ptr;
                                // First decode has no prior pending; can't be
                                // first-of-block.
                                pend_init_sub  <= 4'd0;
                                pend_vscrol_val<= vscrol;
                                pend_scan_count<= is_blank
                                                    ? blank_count
                                                    : scanline_count_for_mode(mode_q);
                                pend_valid     <= 1'b1;
                                state          <= S_FETCH_OP;
                                emit_phase     <= E_STAGE;
                            end
                        end

                        E_EMIT, E_FLUSH_END: begin
                            if (atari_row < ATARI_H[7:0]) begin
                                line_mode[atari_row]      <= pend_mode;
                                line_sub_row[atari_row]   <= sub_row;
                                line_lms_addr[atari_row]  <= pend_lms;
                                line_hscrol_en[atari_row] <= pend_hscrol_en;
                                line_vscrol_en[atari_row] <= pend_vscrol_en;
                                line_dli[atari_row]       <=
                                    (sub_row == pend_init_sub) ? pending_dli : 1'b0;
                                atari_row <= atari_row + 8'd1;
                                sub_row   <= sub_row + 4'd1;
                                if ({1'b0, sub_row} + 5'd1 == pend_eff_end) begin
                                    // Last emitted sub_row of pending.
                                    pending_dli <= pend_dli;
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
                            adv = (pend_mode >= 4'd2)
                                    ? lms_ptr + bytes_per_line(pend_mode, pend_hscrol_en)
                                    : lms_ptr;
                            new_lms_after_load = lms_was_loaded ? new_lms_loaded : adv;
                            lms_ptr        <= new_lms_after_load;

                            // Copy decoded → pending. prev_vscrol = old pend's
                            // vscrol_en (which IS pend_vscrol_en RIGHT NOW since
                            // we haven't overwritten yet).
                            pend_mode      <= is_blank ? 4'h0 : mode_q;
                            pend_dli       <= dli_q;
                            pend_vscrol_en <= is_blank ? 1'b0 : vscrol_q;
                            pend_hscrol_en <= is_blank ? 1'b0 : hscrol_q;
                            pend_lms       <= new_lms_after_load;
                            pend_init_sub  <= (!is_blank && (mode_q >= 4'd2)
                                                && vscrol_q && !pend_vscrol_en)
                                                  ? vscrol : 4'd0;
                            pend_vscrol_val<= vscrol;
                            pend_scan_count<= is_blank
                                                ? blank_count
                                                : scanline_count_for_mode(mode_q);
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
