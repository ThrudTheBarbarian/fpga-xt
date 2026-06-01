// compositor.sv — per-row playfield index emitter.
//
// On `start_compose`, composes exactly ONE row — the row supplied on `row_in`
// (compositor option (b)).  The dl_parser meta read port yields
// (mode, lms_addr, sub_row) for that row; the compositor then dispatches
// per-mode.  The ANTIC native-raster sequencer (antic_seq) pulses
// `start_compose` once per active scanline with row_in = ar_atari_row, so the
// frame is walked in raster order in lockstep with the CPU (register values
// latched here reflect mid-frame writes up to the composed row).
//
// This module composes one row per start_compose, so render is
// phi2/beam-locked.
//
// Per-mode dispatch:
//
//   Mode F  (1 bpp, 320 atari px): 40 source bytes; bit set → $04
//                                  (COLPF2 owner), bit clear → $00.
//   Mode 2  (40-col text, 1 bpp): 40 char codes; glyph from
//                                  (chbase<<8) + (code & $7F)*8 + sub_row.
//                                  CHACTL: vrefl, inv_en, inv_blank.
//                                  bit set → $02 (COLPF1 owner).
//   Mode 4  (40-col multi-color, 2 bpp): per-cell value 0..3 →
//                                  0=$00, 1=$01, 2=$02, 3=code[7]?$08:$04.
//                                  scan_count = 8.
//   Mode 5  (mode 4, vertical 2x): scan_count = 16, glyph_row = sub_row >> 1.
//   Mode 6  (20-col 4-color, 1 bpp): 20 char codes, 16 atari px/char.
//                                  bit set → ci_to_pf[code[7:6]] =
//                                  {$01, $02, $04, $08}; bit clear → $00.
//                                  Code mask = $3F.
//   Mode 7  (mode 6, vertical 2x): scan_count = 16, glyph_row = sub_row >> 1.
//
//   Mode 8 (40 px, 2bpp): 10 source bytes; cell-LUT (0/1/2/4); 8 atari
//                                  px per cell.
//   Mode 9 (80 px, 1bpp): 10 source bytes; bit set → $04, clear → $00;
//                                  4 atari px per bit.
//   Mode A (80 px, 2bpp): 20 source bytes; cell-LUT; 4 atari px per cell.
//   Mode B (160 px, 1bpp): 20 source bytes; 2 atari px per bit. scan_count=2.
//   Mode C (mode B, scan_count=1).
//   Mode D (160 px, 2bpp): 40 source bytes; cell-LUT; 2 atari px per cell.
//   Mode E (mode D, scan_count=1).
//
// Mode 3 (descender) is deferred — the variable glyph_row mapping
// (codes < 96 vs ≥ 96 wrap differently across the 10 scan lines)
// adds enough state to warrant its own milestone slot.
//
// Modes 0/1 are skipped (the row's mode metadata is checked and
// unsupported modes go straight to S_NEXT_ROW).
//
// Read port to cpu_shadow has 1-cycle BRAM latency; each cpu_shadow
// access is a 3-state pattern (FETCH/WAIT/LATCH). Char modes need two
// reads per char column (code, then glyph), so per-char latency is
// ~10-12 clk cycles + the 4 SETs.

`default_nettype none
`include "bus_opcodes.vh"

module compositor #(
    parameter int FB_ROW_STRIDE = 1024,
    parameter int FB_ADDR_W     = 24,
    parameter int ATARI_H       = 192
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start_compose,
    input  wire  [7:0] row_in,            // row to compose (option (b), = ar_atari_row)

    // dl_parser metadata read port.
    output logic [7:0]  meta_row,
    input  wire  [3:0]  meta_mode,
    input  wire  [15:0] meta_lms_addr,
    input  wire  [3:0]  meta_sub_row,
    input  wire         meta_hscrol_en,    // M11: this row's HSCROL enable
    input  wire         meta_vscrol_en,    // M11: this row's VSCROL enable (compositor still ignores; dl_parser owns sub_row)

    // antic_regs side-channel inputs.
    input  wire  [7:0]  chbase,            // CHBASE register ($D409)
    input  wire  [7:0]  chactl,            // CHACTL register ($D401)
    input  wire  [7:0]  pmbase,            // PMBASE register ($D407)
    input  wire  [7:0]  dmactl,            // DMACTL register ($D400) — bit 3 = player DMA, bit 4 = 1-line res
    input  wire  [7:0]  gractl,            // GRACTL register ($D01D) — bit 1 = player presence enable
    input  wire  [7:0]  hposp0,            // HPOSP0 register ($D000) — color-clock position
    input  wire  [7:0]  hposp1,            // HPOSP1 ($D001)
    input  wire  [7:0]  hposp2,            // HPOSP2 ($D002)
    input  wire  [7:0]  hposp3,            // HPOSP3 ($D003)
    input  wire  [7:0]  hposm0,            // HPOSM0 ($D004)
    input  wire  [7:0]  hposm1,            // HPOSM1 ($D005)
    input  wire  [7:0]  hposm2,            // HPOSM2 ($D006)
    input  wire  [7:0]  hposm3,            // HPOSM3 ($D007)
    input  wire  [1:0]  sizep0,            // SIZEP0 ($D008) — 00=1x, 01=2x, 10=1x, 11=4x
    input  wire  [1:0]  sizep1,
    input  wire  [1:0]  sizep2,
    input  wire  [1:0]  sizep3,
    input  wire  [7:0]  sizem,             // SIZEM ($D00C) — m0=[1:0], m1=[3:2], m2=[5:4], m3=[7:6]
    input  wire  [7:0]  vdelay,            // VDELAY ($D01C) — bit 0..3=M0..M3, 4..7=P0..P3
    input  wire  [3:0]  hscrol,            // HSCROL ($D404) — colour-clock shift, 0..15
    input  wire  [3:0]  vscrol,            // VSCROL ($D405) — sub-row shift, 0..15 (consumed by dl_parser; M11b)
    input  wire  [7:0]  prior,             // PRIOR ($D01B) — bits[7:6] select GTIA mode 9/10/11 (M10b)

    // cpu_shadow / DMA read port. mem_req pulses one cycle on entry to
    // any FETCH state so the M16-int adapter can trigger a DMA cycle in
    // DMA mode; mem_ready gates each WAIT state's advance so the
    // multi-cycle DMA path doesn't read stale data. In snoop mode the
    // adapter ties mem_ready high and mem_req is ignored.
    output logic [15:0] mem_raddr,
    input  wire  [7:0]  mem_rdata,
    output wire         mem_req,
    input  wire         mem_ready,

    // rp_tx command issuance — SET opcodes only.
    output logic [1:0]  cmd_tag,
    output logic [23:0] cmd_addr,
    output logic [23:0] cmd_data,        // 2× 12-bit pixels (M10c widened from 16-bit)
    output logic        cmd_valid,
    input  wire         cmd_ready,

    // Collision latches (sticky — accumulate per composed pixel until HITCLR).
    //   mpf_q[4i+3:4i] = M{i}PF (4 PF bits)
    //   ppf_q[4i+3:4i] = P{i}PF
    //   mpl_q[4i+3:4i] = M{i}PL bits 3:0 = {vsP3, vsP2, vsP1, vsP0}
    //   ppl_q[4i+3:4i] = P{i}PL (P{i}PL[i] always 0)
    output logic [15:0] mpf_q,
    output logic [15:0] ppf_q,
    output logic [15:0] mpl_q,
    output logic [15:0] ppl_q,
    input  wire         hitclr,            // strobe — clears all latches at posedge

    // Status.
    output logic        compose_done,
    output logic [31:0] compose_count
);

    // ---- FSM states -----------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE              = 5'd0,
        S_FETCH_META        = 5'd1,
        S_LATCH_META        = 5'd2,
        // P/M shape fetch loop (6 entities: P0, P1, P2, P3, M, M_prev)
        S_PM_FETCH          = 5'd14,
        S_PM_WAIT           = 5'd15,
        S_PM_LATCH          = 5'd16,
        // Graphics modes 8/9/A/B/D/E (single source byte per unit, no
        // HSCROL in M11a)
        S_F_FETCH_BYTE      = 5'd3,
        S_F_WAIT_BYTE       = 5'd4,
        S_F_LATCH_BYTE      = 5'd5,
        // Mode F HSCROL path. Pre-fetch initial cur_byte at hs_byte_offset
        // then per-unit fetch+latch with shift register.
        S_HS_FETCH_PRE      = 5'd17,
        S_HS_WAIT_PRE       = 5'd18,
        S_HS_LATCH_PRE      = 5'd19,
        S_HS_FETCH_BYTE     = 5'd20,
        S_HS_WAIT_BYTE      = 5'd21,
        S_HS_LATCH_BYTE     = 5'd22,
        // Char-mode path (modes 2/4/5/6/7)
        S_TXT_FETCH_CODE    = 5'd6,
        S_TXT_WAIT_CODE     = 5'd7,
        S_TXT_LATCH_CODE    = 5'd8,
        S_TXT_FETCH_GLYPH   = 5'd9,
        S_TXT_WAIT_GLYPH    = 5'd10,
        S_TXT_LATCH_GLYPH   = 5'd11,
        // Shared SET issuance
        S_ISSUE_SET         = 5'd12,
        S_NEXT_ROW          = 5'd13,

        S_BLANK_FILL        = 5'd23     // paint a full row of COLBK (idx 0) for
                                        // blank ($x0) / unsupported-mode lines
    } state_t;

    state_t      state;

    // Pulse mem_req for exactly one cycle on each FETCH→WAIT
    // transition (see dl_parser for rationale). A sustained pulse
    // would cause mem_read_mux to re-trigger on its D_BUSY→D_READY
    // return, firing a duplicate DMA cycle.
    logic prev_state_was_fetch;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            prev_state_was_fetch <= 1'b0;
        else
            prev_state_was_fetch <= (state == S_PM_FETCH)
                                  || (state == S_F_FETCH_BYTE)
                                  || (state == S_HS_FETCH_PRE)
                                  || (state == S_HS_FETCH_BYTE)
                                  || (state == S_TXT_FETCH_CODE)
                                  || (state == S_TXT_FETCH_GLYPH);
    end
    assign mem_req = prev_state_was_fetch;

    logic [7:0]  cur_row;
    logic [15:0] cur_lms;
    logic [3:0]  cur_mode;
    logic [3:0]  cur_sub_row;

    logic [5:0]  unit_idx;            // source-unit index (0..MAX_UNITS-1)
    logic [3:0]  pair_idx;            // 0..15 for mode 8/9; 0..7 for 16-px modes; 0..3 for 8-px modes
    logic [8:0]  blank_col;           // S_BLANK_FILL pair counter (0..BLANK_PAIRS)

    // Active playfield is 384 px = 192 pairs (matches the antic_top render-tap
    // LB_WIDTH).  A blank/unsupported row issues this many COLBK pairs.
    localparam int BLANK_PAIRS = 192;

    logic [7:0]  cur_byte;            // mode F's source byte (also char glyph for char modes)
    logic [7:0]  cur_code;            // char-mode char code
    logic        cur_code_bit7;       // captured for inverse-video / mode 4 PF3 select
    logic [1:0]  cur_code_bit67;      // mode 6/7 PF selector
    logic [7:0]  p0_shape;            // player 0 shape byte for current atari row
    logic [7:0]  p1_shape;
    logic [7:0]  p2_shape;
    logic [7:0]  p3_shape;
    logic [7:0]  ms_byte;              // missile byte for cur_row    (m0=[1:0], m1=[3:2], m2=[5:4], m3=[7:6])
    logic [7:0]  ms_byte_prev;         // missile byte for cur_row-1   (used per-missile via VDELAY[3:0])
    logic [2:0]  pm_fetch_idx;         // 0..5 entity counter for the PM fetch loop (P0..P3, M_now, M_prev)
    // M11 HSCROL state. shift_atari = 2*hscrol when meta_hscrol_en, else 0.
    // The actual byte_offset / sub_atari split is mode-dependent because
    // atari-px-per-source-byte varies across modes:
    //   F / D / E / 2 / 3 / 4 / 5: 8 atari/byte → sub_atari = shift[2:0], byte_off = shift[4:3]
    //   A / B / C / 6 / 7:        16 atari/byte → sub_atari = shift[3:0], byte_off = shift[4]
    //   8 / 9:                    32 atari/byte → sub_atari = shift[4:0], byte_off = 0
    // hs_sub_atari is 5 bits to cover the widest case; mode F packers
    // only consume the bottom 3 bits.
    logic [1:0]  hs_byte_offset;
    logic [4:0]  hs_sub_atari;
    logic [7:0]  next_byte;            // shift-register tail

    // M11d char-mode HSCROL: 2-char window. cur_code/cur_glyph hold the
    // left side of the window (= the only char in non-HSCROL); nxt_code/
    // nxt_glyph hold the right side. hsc_phase tracks which side the
    // current code+glyph fetch sequence is filling.
    logic        is_txt_hscrol;        // captured at S_LATCH_META
    logic        hsc_phase;            // 0 = fetching cur side, 1 = fetching nxt side
    logic [7:0]  nxt_code;
    logic        nxt_code_bit7;
    logic [1:0]  nxt_code_bit67;
    logic [15:0] nxt_glyph_addr;
    logic [7:0]  nxt_glyph;

    // ---- Per-mode parameter helpers ------------------------------------
    function automatic logic        is_char_mode_f(logic [3:0] m);
        return (m == 4'h2) || (m == 4'h3) || (m == 4'h4) || (m == 4'h5)
            || (m == 4'h6) || (m == 4'h7);
    endfunction

    function automatic logic        is_gfx_mode_f(logic [3:0] m);
        return (m == 4'h8) || (m == 4'h9) || (m == 4'hA) || (m == 4'hB)
            || (m == 4'hC) || (m == 4'hD) || (m == 4'hE);
    endfunction

    // Source bytes (units) per row.
    function automatic logic [5:0]  units_per_row(logic [3:0] m);
        case (m)
            4'h8, 4'h9:                       return 6'd10;
            4'h6, 4'h7, 4'hA, 4'hB, 4'hC:     return 6'd20;
            default:                          return 6'd40;
        endcase
    endfunction

    // Pairs per source unit (= atari px per unit / 2).
    function automatic logic [3:0]  max_pair_idx(logic [3:0] m);
        case (m)
            4'h8, 4'h9:                       return 4'd15;   // 32 atari px = 16 pairs
            4'h6, 4'h7, 4'hA, 4'hB, 4'hC:     return 4'd7;    // 16 atari px = 8 pairs
            default:                          return 4'd3;    // 8 atari px = 4 pairs
        endcase
    endfunction

    // Atari pixels per source unit.
    function automatic logic [5:0]  unit_width_atari(logic [3:0] m);
        case (m)
            4'h8, 4'h9:                       return 6'd32;
            4'h6, 4'h7, 4'hA, 4'hB, 4'hC:     return 6'd16;
            default:                          return 6'd8;
        endcase
    endfunction

    function automatic logic [7:0]  code_mask(logic [3:0] m);
        case (m)
            4'h6, 4'h7: return 8'h3F;     // mode 6/7: low 6 bits = glyph index
            default:    return 8'h7F;     // mode 2/4/5: low 7 bits
        endcase
    endfunction

    // For modes 5 / 7 the DL line is 16 scan lines tall, but the glyph
    // table is only 8 rows — divide sub_row by 2 to address. Mode 3
    // (10 scan lines tall, with descender chars) needs the code to
    // pick between regular and descender mappings.
    function automatic logic [2:0]  glyph_row(logic [3:0] m, logic [7:0] code, logic [3:0] sub);
        case (m)
            4'h5, 4'h7: return sub[3:1];
            4'h3: begin
                // Mode 3: codes with bits[6:5] == 11 (i.e. 96..127 of
                // the 7-bit char code) are descenders — sub_row 0/1
                // pull glyph rows 6/7 from the SAME glyph table; sub 2..9
                // pull rows 0..7. Codes 0..95 use sub 0..7 → rows 0..7
                // and sub 8/9 are blanked at the glyph-latch step.
                if (code[6:5] == 2'b11) begin
                    if (sub < 4'd2) return {2'b11, sub[0]};         // 6 or 7
                    else            return sub[2:0] - 3'd2;          // sub-2
                end else begin
                    return sub[2:0];                                  // 0..7 (8/9 → 0; blanked later)
                end
            end
            default:    return sub[2:0];
        endcase
    endfunction

    // Compose the 16-bit glyph address: (chbase << 8) | (masked_code << 3) | glyph_row.
    // Note: real ANTIC requires CHBASE aligned to a 512- or 1024-byte boundary
    // (chb[0:1] = 0 typically) so the byte-add can't overflow into chb. This
    // build uses an explicit add to keep width semantics legible.
    function automatic logic [15:0] compute_glyph_addr(logic [7:0] chb,
                                                       logic [7:0] code,
                                                       logic [3:0] m,
                                                       logic [3:0] sub);
        logic [7:0]  mask;
        logic [6:0]  base;
        logic [2:0]  row;
        logic [15:0] addr;
        case (m)
            4'h6, 4'h7: mask = 8'h3F;
            default:    mask = 8'h7F;
        endcase
        base = code[6:0] & mask[6:0];
        row  = glyph_row(m, code, sub);
        addr = {chb, 8'h00}                   // chbase * 256
             + {6'h0, base, 3'b000}           // (code & mask) * 8
             + {13'h0, row};                  // glyph row within char
        return addr;
    endfunction

    // ---- Per-mode pixel-pair packing -----------------------------------
    // For mode F, glyph_byte = source byte; ignore code.
    // For modes 2/4/5/6/7, glyph_byte = the post-CHACTL glyph; code +
    // bit7 / bit67 select per-mode owner bits for the high-value cells.

    // Mode F: bit p of glyph → 0x04 (set) or 0x00 (clear).
    function automatic logic [7:0] modeF_pixel(logic [7:0] glyph, logic [2:0] bit_idx);
        return glyph[bit_idx] ? 8'h04 : 8'h00;
    endfunction

    // Mode F window pack: pair p of a 16-bit window {cur_byte, next_byte}
    // with sub-byte shift hs_sub. Used by the HSCROL path. Returns the
    // pre-overlay packed pair {hi_pixel, lo_pixel}. With hs_sub=0 the
    // result is identical to pack_pair(F, cur_byte, _, p) since the LO
    // px lives at window[15-2p] = cur_byte[7-2p].
    function automatic logic [15:0] pack_pair_F_window(logic [15:0] window,
                                                       logic [3:0]  p,
                                                       logic [4:0]  hs_sub);
        // Mode F has 8 atari px per byte so only the low 3 bits of the
        // 5-bit hs_sub matter (high bits are absorbed into hs_byte_offset
        // by the caller).
        logic [4:0] lo_idx, hi_idx;
        logic [7:0] lo_px, hi_px;
        lo_idx = 5'd15 - {2'b00, hs_sub[2:0]} - {3'b000, p[1:0], 1'b0};
        hi_idx = 5'd14 - {2'b00, hs_sub[2:0]} - {3'b000, p[1:0], 1'b0};
        lo_px  = window[lo_idx[3:0]] ? 8'h04 : 8'h00;
        hi_px  = window[hi_idx[3:0]] ? 8'h04 : 8'h00;
        return {hi_px, lo_px};
    endfunction

    // GTIA-mode mode-F packer. PRIOR[7:6] != 00 reinterprets the mode-F
    // source bytes as 4-bit-per-pixel GTIA pixels (each GTIA pixel
    // covers 4 atari px). Each pair (= 2 atari px) lies wholly within
    // one nibble of the source byte_stream, so both atari px of the
    // pair carry the same nibble value. The colour resolver later
    // dispatches on PRIOR[7:6] to turn the nibble into an Atari hue:luma.
    //
    // hs_sub is always even (= 2 × hscrol[1:0]) and p ∈ [0..3], so the
    // bit position lo_idx is always within one nibble — verified
    // exhaustively for every (p, hs_sub) combination.
    function automatic logic [15:0] pack_pair_F_gtia_window(
                                        logic [15:0] window,
                                        logic [3:0]  p,
                                        logic [4:0]  hs_sub);
        logic [4:0] lo_idx;
        logic [3:0] nibble;
        logic [7:0] px_value;
        lo_idx = 5'd15 - {2'b00, hs_sub[2:0]} - {3'b000, p[1:0], 1'b0};
        // Pick the 4-bit nibble containing lo_idx. Bits 12..15 = nibble3,
        // 8..11 = nibble2, 4..7 = nibble1, 0..3 = nibble0.
        case (lo_idx[3:2])
            2'd3: nibble = window[15:12];
            2'd2: nibble = window[11:8];
            2'd1: nibble = window[7:4];
            default: nibble = window[3:0];
        endcase
        // Store nibble value in the LOW NIBBLE of idx_buf for both
        // atari px. High nibble (P/M presence) is added later by
        // apply_pm_overlay.
        px_value = {4'h0, nibble};
        return {px_value, px_value};
    endfunction

    // M11c: HSCROL window packer for graphics modes 8-E. Same shift-
    // register approach as pack_pair_F_window, but the source byte's
    // unpack pattern varies per mode (1 / 2 bpp; 2 / 4 / 8 atari px per
    // bit-or-cell). Window is {cur_byte, next_byte} (cur at [15:8]).
    // hs_sub_atari is the per-mode in-byte atari-pixel offset:
    //   F / D / E:    0..6   (8 atari/byte)
    //   A / B / C:    0..14  (16 atari/byte)
    //   8 / 9:        0..30  (32 atari/byte)
    //
    // For each pair, the lo / hi atari positions land at hs_sub + 2p
    // and hs_sub + 2p + 1. If the position is past the byte boundary
    // we read from next_byte (window[7:0]) instead of cur_byte.
    function automatic logic [7:0] gfx_pixel_extract(logic [3:0] mode,
                                                      logic [7:0] byte_data,
                                                      logic [4:0] atari_in_byte);
        logic [1:0] cell_idx;
        logic [2:0] bit_idx;
        logic [1:0] cell_v;
        case (mode)
            4'h8: begin
                cell_idx = atari_in_byte[4:3];        // 8 atari per cell
                cell_v   = {byte_data[3'd7 - {cell_idx, 1'b0}],
                            byte_data[3'd6 - {cell_idx, 1'b0}]};
                return mode4_pixel(cell_v, 1'b0);
            end
            4'h9: begin
                bit_idx = 3'd7 - atari_in_byte[4:2];  // 4 atari per bit
                return byte_data[bit_idx] ? 8'h04 : 8'h00;
            end
            4'hA: begin
                cell_idx = atari_in_byte[3:2];        // 4 atari per cell
                cell_v   = {byte_data[3'd7 - {cell_idx, 1'b0}],
                            byte_data[3'd6 - {cell_idx, 1'b0}]};
                return mode4_pixel(cell_v, 1'b0);
            end
            4'hB, 4'hC: begin
                bit_idx = 3'd7 - atari_in_byte[3:1];  // 2 atari per bit
                return byte_data[bit_idx] ? 8'h04 : 8'h00;
            end
            4'hD, 4'hE: begin
                cell_idx = atari_in_byte[2:1];        // 2 atari per cell
                cell_v   = {byte_data[3'd7 - {cell_idx, 1'b0}],
                            byte_data[3'd6 - {cell_idx, 1'b0}]};
                return mode4_pixel(cell_v, 1'b0);
            end
            default: return 8'h00;
        endcase
    endfunction

    // M11d: char-mode windowed pixel-extract. Returns the 8-bit idx-buf
    // pixel for a given (mode, glyph, code, atari-in-byte) tuple. Mode
    // 5/7 share unpack with mode 4/6 (vertical-2x is folded into glyph_row
    // at fetch time). The atari_in_byte argument is mode-relative:
    //   2/3/4/5: 0..7  (8 atari per char)
    //   6/7:     0..15 (16 atari per char)
    function automatic logic [7:0] txt_pixel_extract(logic [3:0] mode,
                                                      logic [7:0] glyph,
                                                      logic [7:0] code,
                                                      logic [4:0] atari_in_byte);
        logic [2:0] bit_idx;
        logic [1:0] cell_idx;
        logic [1:0] cell_v;
        case (mode)
            4'h2, 4'h3: begin
                bit_idx = 3'd7 - atari_in_byte[2:0];           // 1 atari per bit
                return mode2_pixel(glyph, bit_idx);
            end
            4'h4, 4'h5: begin
                cell_idx = atari_in_byte[2:1];                  // 2 atari per cell
                cell_v   = {glyph[3'd7 - {cell_idx, 1'b0}],
                            glyph[3'd6 - {cell_idx, 1'b0}]};
                return mode4_pixel(cell_v, code[7]);
            end
            4'h6, 4'h7: begin
                bit_idx = 3'd7 - atari_in_byte[3:1];           // 2 atari per bit
                return mode6_pixel(glyph, bit_idx, code[7:6]);
            end
            default: return 8'h00;
        endcase
    endfunction

    // M11d: char-mode HSCROL window pack. Window = {cur_*, nxt_*}
    // (cur on the left). For each atari px in the pair, pick whether it
    // lives in cur's char or nxt's char and apply the per-mode unpack.
    function automatic logic [15:0] pack_pair_txt_window(
        logic [3:0]  mode,
        logic [7:0]  cur_glyph_in,
        logic [7:0]  cur_code_in,
        logic [7:0]  nxt_glyph_in,
        logic [7:0]  nxt_code_in,
        logic [3:0]  p,
        logic [4:0]  hs_sub);
        logic [5:0] atari_per_byte;
        logic [6:0] src_lo, src_hi;
        logic       use_nxt_lo, use_nxt_hi;
        logic [7:0] glyph_lo, glyph_hi;
        logic [7:0] code_lo,  code_hi;
        logic [4:0] in_byte_lo, in_byte_hi;
        logic [7:0] lo_px, hi_px;

        case (mode)
            4'h6, 4'h7: atari_per_byte = 6'd16;
            default:    atari_per_byte = 6'd8;       // 2/3/4/5
        endcase

        // p is up to 7 in modes 6/7 (8 pairs/char), up to 3 in modes 2-5.
        src_lo = {2'b00, hs_sub} + {2'b00, p, 1'b0};
        src_hi = src_lo + 7'd1;
        use_nxt_lo = src_lo >= {1'b0, atari_per_byte};
        use_nxt_hi = src_hi >= {1'b0, atari_per_byte};

        glyph_lo   = use_nxt_lo ? nxt_glyph_in : cur_glyph_in;
        glyph_hi   = use_nxt_hi ? nxt_glyph_in : cur_glyph_in;
        code_lo    = use_nxt_lo ? nxt_code_in  : cur_code_in;
        code_hi    = use_nxt_hi ? nxt_code_in  : cur_code_in;
        in_byte_lo = use_nxt_lo ? src_lo[4:0] - atari_per_byte[4:0] : src_lo[4:0];
        in_byte_hi = use_nxt_hi ? src_hi[4:0] - atari_per_byte[4:0] : src_hi[4:0];

        lo_px = txt_pixel_extract(mode, glyph_lo, code_lo, in_byte_lo);
        hi_px = txt_pixel_extract(mode, glyph_hi, code_hi, in_byte_hi);
        return {hi_px, lo_px};
    endfunction

    function automatic logic [15:0] pack_pair_gfx_window(logic [3:0]  mode,
                                                          logic [15:0] window,
                                                          logic [3:0]  p,
                                                          logic [4:0]  hs_sub);
        logic [6:0] src_lo, src_hi;
        logic [5:0] atari_per_byte;        // 6-bit because mode 8/9 = 32
        logic       sel_lo, sel_hi;
        logic [7:0] byte_lo, byte_hi;
        logic [4:0] in_byte_lo, in_byte_hi;
        logic [7:0] lo_px, hi_px;

        // p ranges up to 15 in mode 8/9 (16 pairs/byte), so use the full
        // 4-bit value when scaling 2*p — not p[1:0] (which truncates).
        src_lo = {2'b00, hs_sub} + {2'b00, p, 1'b0};
        src_hi = src_lo + 7'd1;

        case (mode)
            4'h8, 4'h9:                  atari_per_byte = 6'd32;
            4'hA, 4'hB, 4'hC:            atari_per_byte = 6'd16;
            default:                      atari_per_byte = 6'd8;   // F / D / E
        endcase

        sel_lo  = src_lo >= {1'b0, atari_per_byte};
        sel_hi  = src_hi >= {1'b0, atari_per_byte};
        byte_lo = sel_lo ? window[7:0]  : window[15:8];
        byte_hi = sel_hi ? window[7:0]  : window[15:8];
        in_byte_lo = sel_lo ? src_lo[4:0] - atari_per_byte[4:0] : src_lo[4:0];
        in_byte_hi = sel_hi ? src_hi[4:0] - atari_per_byte[4:0] : src_hi[4:0];

        lo_px = gfx_pixel_extract(mode, byte_lo, in_byte_lo);
        hi_px = gfx_pixel_extract(mode, byte_hi, in_byte_hi);
        return {hi_px, lo_px};
    endfunction

    // Mode 2 (GR.0, 1 bpp text): set glyph bit → 0x02 (PF1, COLPF1 = text),
    // clear bit → 0x04 (PF2, COLPF2 = the character-cell background).  The
    // GR.0 text area is COLPF2, NOT the border colour — this was 0x00 (BG),
    // which painted the whole text field in COLBK ($00 black) instead of the
    // COLPF2 blue, so only the text glyphs showed.
    function automatic logic [7:0] mode2_pixel(logic [7:0] glyph, logic [2:0] bit_idx);
        return glyph[bit_idx] ? 8'h02 : 8'h04;
    endfunction

    // Mode 4/5: 2-bit cell value v → 0x00/0x01/0x02/(code[7]?0x08:0x04).
    function automatic logic [7:0] mode4_pixel(logic [1:0] v, logic code_b7);
        case (v)
            2'd0: return 8'h00;
            2'd1: return 8'h01;
            2'd2: return 8'h02;
            2'd3: return code_b7 ? 8'h08 : 8'h04;
            default: return 8'h00;
        endcase
    endfunction

    // Mode 6/7: bit set → ci_to_pf[code[7:6]]; bit clear → 0x00.
    function automatic logic [7:0] mode6_pixel(logic [7:0] glyph, logic [2:0] bit_idx,
                                                logic [1:0] code_b67);
        logic [7:0] pf;
        case (code_b67)
            2'd0: pf = 8'h01;
            2'd1: pf = 8'h02;
            2'd2: pf = 8'h04;
            2'd3: pf = 8'h08;
            default: pf = 8'h00;
        endcase
        return glyph[bit_idx] ? pf : 8'h00;
    endfunction

    // ---- P/M overlay ----------------------------------------------------
    // player_covers: 1 when the named player covers `atari_x`. Gated on
    // GRACTL[1] (player DMA enable) + DMACTL[3] (PM-DMA player) +
    // non-zero shape. SIZEP scaling: 00/10=1x (16 px), 01=2x (32 px),
    // 11=4x (64 px) — bit_idx = 7 - (dx >> scale_shift), where scale_shift
    // is 1/2/3 for 1x/2x/4x respectively.
    function automatic logic player_covers(logic [9:0] atari_x,
                                            logic [7:0] hposp,
                                            logic [7:0] shape,
                                            logic [1:0] sizep);
        logic signed [11:0] x_left;
        logic signed [11:0] dx;
        logic signed [11:0] width;
        logic [2:0]         bit_sel;
        if (!gractl[1] || !dmactl[3] || shape == 8'h00) return 1'b0;
        x_left = ({{4{1'b0}}, hposp} - 12'sd48) <<< 1;
        dx     = $signed({2'b00, atari_x}) - x_left;
        case (sizep)
            2'b01:        begin width = 12'sd32; bit_sel = 3'd7 - dx[4:2]; end
            2'b11:        begin width = 12'sd64; bit_sel = 3'd7 - dx[5:3]; end
            default:      begin width = 12'sd16; bit_sel = 3'd7 - dx[3:1]; end
        endcase
        if (dx < 0 || dx >= width) return 1'b0;
        return shape[bit_sel];
    endfunction

    // missile_covers: 1 when the named missile covers `atari_x`. Gated
    // on GRACTL[0] (missile presence enable) + DMACTL[2] (missile DMA).
    // m_shape is the 2-bit shape; bit 1 = leftmost, bit 0 = rightmost.
    // SIZEM (per-missile 2 bits): 00/10=1x (4 px, 2 px/bit), 01=2x (8 px),
    // 11=4x (16 px). bit_sel picks the 1 of 2 shape bits based on dx.
    function automatic logic missile_covers(logic [9:0] atari_x,
                                             logic [7:0] hposm,
                                             logic [1:0] m_shape,
                                             logic [1:0] m_size);
        logic signed [11:0] x_left;
        logic signed [11:0] dx;
        logic signed [11:0] width;
        logic               bit_sel;
        if (!gractl[0] || !dmactl[2] || m_shape == 2'h0) return 1'b0;
        x_left = ({{4{1'b0}}, hposm} - 12'sd48) <<< 1;
        dx     = $signed({2'b00, atari_x}) - x_left;
        case (m_size)
            2'b01:   begin width = 12'sd8;  bit_sel = ~dx[2]; end
            2'b11:   begin width = 12'sd16; bit_sel = ~dx[3]; end
            default: begin width = 12'sd4;  bit_sel = ~dx[1]; end
        endcase
        if (dx < 0 || dx >= width) return 1'b0;
        return m_shape[bit_sel];
    endfunction

    // pm_presence: returns 8-bit vector {P3,P2,P1,P0,M3,M2,M1,M0} for one
    // atari_x. Per-missile VDELAY picks between the current-row and prev-
    // row missile byte. Used by apply_pm_overlay (pixel path) and registered
    // per pair (col_presL/H_q) for the next-cycle collision_combine.
    function automatic logic [7:0] pm_presence(logic [9:0] atari_x);
        logic [7:0] ms_eff;
        logic       p0p, p1p, p2p, p3p;
        logic       m0p, m1p, m2p, m3p;
        ms_eff[1:0] = vdelay[0] ? ms_byte_prev[1:0] : ms_byte[1:0];
        ms_eff[3:2] = vdelay[1] ? ms_byte_prev[3:2] : ms_byte[3:2];
        ms_eff[5:4] = vdelay[2] ? ms_byte_prev[5:4] : ms_byte[5:4];
        ms_eff[7:6] = vdelay[3] ? ms_byte_prev[7:6] : ms_byte[7:6];
        p0p = player_covers(atari_x, hposp0, p0_shape, sizep0);
        p1p = player_covers(atari_x, hposp1, p1_shape, sizep1);
        p2p = player_covers(atari_x, hposp2, p2_shape, sizep2);
        p3p = player_covers(atari_x, hposp3, p3_shape, sizep3);
        m0p = missile_covers(atari_x, hposm0, ms_eff[1:0], sizem[1:0]);
        m1p = missile_covers(atari_x, hposm1, ms_eff[3:2], sizem[3:2]);
        m2p = missile_covers(atari_x, hposm2, ms_eff[5:4], sizem[5:4]);
        m3p = missile_covers(atari_x, hposm3, ms_eff[7:6], sizem[7:6]);
        return {p3p, p2p, p1p, p0p, m3p, m2p, m1p, m0p};
    endfunction

    // apply_pm_overlay ORs P0..P3 + M0..M3 presence bits onto a packed
    // pair. Returns 24 bits with the M-only nibbles ABOVE the legacy
    // 16-bit pair so a legacy 16-bit consumer still sees the original
    // {hi_byte, lo_byte} layout in the bottom 16 bits:
    //
    //   bits [7:0]   = pixel-lo legacy 8-bit (PF/GTIA nibble + P|M shared)
    //   bits [15:8]  = pixel-hi legacy 8-bit
    //   bits [19:16] = pixel-lo M-only nibble (NEW for M10c PM5)
    //   bits [23:20] = pixel-hi M-only nibble (NEW for M10c PM5)
    //
    // rp_bus_mock unpacks to 12-bit fb cells:
    //   fb[addr]   = {pl[19:16], pl[7:0]}    // pixel-lo, 12-bit
    //   fb[addr+1] = {pl[23:20], pl[15:8]}   // pixel-hi, 12-bit
    //
    // Legacy testbenches that read u_mock.fb[i] as logic[7:0] still see
    // exactly the original PF + P|M-shared encoding; the M-only nibble
    // sits in bits[11:8] of the storage cell and is invisible to byte-
    // level reads.
    function automatic logic [23:0] apply_pm_overlay(logic [15:0] packed_pair,
                                                      logic [9:0]  atari_x_lo);
        logic [7:0] lo, hi;
        logic [3:0] m_lo, m_hi;
        logic [7:0] pres_lo, pres_hi;

        lo      = packed_pair[7:0];
        hi      = packed_pair[15:8];
        pres_lo = pm_presence(atari_x_lo);
        pres_hi = pm_presence(atari_x_lo + 10'd1);

        // Legacy P|M shared bits.
        if (pres_lo[0] | pres_lo[4]) lo = lo | 8'h10;
        if (pres_hi[0] | pres_hi[4]) hi = hi | 8'h10;
        if (pres_lo[1] | pres_lo[5]) lo = lo | 8'h20;
        if (pres_hi[1] | pres_hi[5]) hi = hi | 8'h20;
        if (pres_lo[2] | pres_lo[6]) lo = lo | 8'h40;
        if (pres_hi[2] | pres_hi[6]) hi = hi | 8'h40;
        if (pres_lo[3] | pres_lo[7]) lo = lo | 8'h80;
        if (pres_hi[3] | pres_hi[7]) hi = hi | 8'h80;

        // M-only nibbles — pres[3:0] = {M3, M2, M1, M0}.
        m_lo = pres_lo[3:0];
        m_hi = pres_hi[3:0];

        return {m_hi, m_lo, hi, lo};
    endfunction

    // collision_combine: returns the OR-into-latches contribution for both
    // atari pixels of a pair, from the PF nibbles (raw_pair) and the two
    // already-resolved P/M presence vectors.  Split out from the old
    // collision_contribution() so the deep pm_presence cone can be REGISTERED
    // in the emit cycle (clk_sys closure): this combine is then a shallow
    // nibble-AND + 4x4 P/P matrix, run one cycle later.  64-bit packed return:
    //   bits [15:0]  = mpf
    //   bits [31:16] = ppf
    //   bits [47:32] = mpl
    //   bits [63:48] = ppl
    function automatic logic [63:0] collision_combine(
        logic [15:0] raw_pair,
        logic [7:0]  pres_lo,
        logic [7:0]  pres_hi);
        logic [3:0]  pf_lo, pf_hi;
        logic [15:0] mpf_c, ppf_c, mpl_c, ppl_c;
        integer      i, j;

        pf_lo   = raw_pair[3:0];
        pf_hi   = raw_pair[11:8];

        mpf_c = 16'h0;
        ppf_c = 16'h0;
        mpl_c = 16'h0;
        ppl_c = 16'h0;

        // M[i] / P[i] vs PF nibble.
        for (i = 0; i < 4; i = i + 1) begin
            if (pres_lo[i])     mpf_c[4*i +: 4] = mpf_c[4*i +: 4] | pf_lo;
            if (pres_hi[i])     mpf_c[4*i +: 4] = mpf_c[4*i +: 4] | pf_hi;
            if (pres_lo[i+4])   ppf_c[4*i +: 4] = ppf_c[4*i +: 4] | pf_lo;
            if (pres_hi[i+4])   ppf_c[4*i +: 4] = ppf_c[4*i +: 4] | pf_hi;
        end

        // M[i] vs P[j] and P[i] vs P[j] (P-vs-P excludes self).
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1) begin
                if (pres_lo[i]   && pres_lo[j+4]) mpl_c[4*i + j] = 1'b1;
                if (pres_hi[i]   && pres_hi[j+4]) mpl_c[4*i + j] = 1'b1;
                if (i != j) begin
                    if (pres_lo[i+4] && pres_lo[j+4]) ppl_c[4*i + j] = 1'b1;
                    if (pres_hi[i+4] && pres_hi[j+4]) ppl_c[4*i + j] = 1'b1;
                end
            end
        end

        return {ppl_c, mpl_c, ppf_c, mpf_c};
    endfunction

    // pack_pair: returns 16-bit {high_pixel, low_pixel} for the pair
    // at index p of unit `cur_byte`/`cur_code`. Mode-dispatched. p is
    // 4-bit to accommodate modes 8/9 (16 pairs per source byte).
    function automatic logic [15:0] pack_pair(logic [3:0] m,
                                              logic [7:0] glyph,
                                              logic [7:0] code,
                                              logic [3:0] p);
        logic [2:0] bit_lo, bit_hi;
        logic [1:0] cell_v;
        logic [2:0] cell_idx;
        logic [2:0] gfx_bit;
        logic [7:0] lo_px, hi_px;
        case (m)
            4'hF: begin
                // Mode F: 4 pairs; pair p covers bits (7-2p, 6-2p).
                bit_lo = 3'd7 - {p[1:0], 1'b0};
                bit_hi = 3'd6 - {p[1:0], 1'b0};
                lo_px  = modeF_pixel(glyph, bit_lo);
                hi_px  = modeF_pixel(glyph, bit_hi);
            end
            4'h2, 4'h3: begin
                // Mode 3 has the same per-pixel encoding as mode 2; the
                // only differences (10 scan lines, descender row mapping,
                // sub 8/9 blank) live in glyph_row + the latch step.
                bit_lo = 3'd7 - {p[1:0], 1'b0};
                bit_hi = 3'd6 - {p[1:0], 1'b0};
                lo_px  = mode2_pixel(glyph, bit_lo);
                hi_px  = mode2_pixel(glyph, bit_hi);
            end
            4'h4, 4'h5: begin
                cell_v = {glyph[3'd7 - {p[1:0], 1'b0}], glyph[3'd6 - {p[1:0], 1'b0}]};
                lo_px  = mode4_pixel(cell_v, code[7]);
                hi_px  = lo_px;
            end
            4'h6, 4'h7: begin
                lo_px = mode6_pixel(glyph, 3'd7 - p[2:0], code[7:6]);
                hi_px = lo_px;
            end
            // Graphics modes 8/A/D/E: per-cell 2bpp. cell_idx depends on
            // pairs-per-cell ratio.
            //   Mode 8: 16 pairs / 4 cells = 4 pairs per cell → cell_idx = p[3:2]
            //   Mode A: 8 pairs / 4 cells  = 2 pairs per cell → cell_idx = p[2:1]
            //   Mode D/E: 4 pairs / 4 cells = 1 pair per cell → cell_idx = p[1:0]
            // Cell value v read from bit pair (7-2c, 6-2c). Output uses
            // mode4 encoding without the code-bit-7 PF3 split (graphics
            // modes always emit PF2 for v=3).
            4'h8: begin
                cell_idx = {1'b0, p[3:2]};
                cell_v   = {glyph[3'd7 - {cell_idx[1:0], 1'b0}],
                            glyph[3'd6 - {cell_idx[1:0], 1'b0}]};
                lo_px    = mode4_pixel(cell_v, 1'b0);
                hi_px    = lo_px;
            end
            4'hA: begin
                cell_idx = {1'b0, p[2:1]};
                cell_v   = {glyph[3'd7 - {cell_idx[1:0], 1'b0}],
                            glyph[3'd6 - {cell_idx[1:0], 1'b0}]};
                lo_px    = mode4_pixel(cell_v, 1'b0);
                hi_px    = lo_px;
            end
            4'hD, 4'hE: begin
                cell_idx = {1'b0, p[1:0]};
                cell_v   = {glyph[3'd7 - {cell_idx[1:0], 1'b0}],
                            glyph[3'd6 - {cell_idx[1:0], 1'b0}]};
                lo_px    = mode4_pixel(cell_v, 1'b0);
                hi_px    = lo_px;
            end
            // Graphics modes 9/B/C: per-bit 1bpp.
            //   Mode 9: 16 pairs / 8 bits = 2 pairs per bit → bit_idx = p[3:1]
            //   Mode B/C: 8 pairs / 8 bits = 1 pair per bit → bit_idx = p[2:0]
            // bit set → 0x04 (COLPF2 owner per rp-antic), clear → 0x00.
            4'h9: begin
                gfx_bit = 3'd7 - p[3:1];
                lo_px   = glyph[gfx_bit] ? 8'h04 : 8'h00;
                hi_px   = lo_px;
            end
            4'hB, 4'hC: begin
                gfx_bit = 3'd7 - p[2:0];
                lo_px   = glyph[gfx_bit] ? 8'h04 : 8'h00;
                hi_px   = lo_px;
            end
            default: begin
                lo_px = 8'h00;
                hi_px = 8'h00;
            end
        endcase
        return {hi_px, lo_px};
    endfunction

    // ---- Address / state registers --------------------------------------
    wire [FB_ADDR_W-1:0] row_base    = cur_row * FB_ROW_STRIDE;
    wire [FB_ADDR_W-1:0] unit_offset = unit_idx * unit_width_atari(cur_mode);
    wire [FB_ADDR_W-1:0] pair_offset = {pair_idx, 1'b0};        // 2 atari px / pair
    wire [FB_ADDR_W-1:0] set_addr    = row_base + unit_offset + pair_offset;
    // Atari-x of the LOW byte of the current pair (within the row).
    wire [9:0]           pair_atari_x_lo = unit_offset[9:0] + pair_offset[9:0];

    // P/M shape addresses with 1-line / 2-line resolution + VDELAY.
    // 1-line (DMACTL[4]=1):
    //   missile byte: pmbase*256 + $300 + atari_row
    //   player p:     pmbase*256 + $400 + p*$100 + atari_row
    // 2-line (DMACTL[4]=0):
    //   missile byte: pmbase*256 + $180 + (atari_row >> 1)
    //   player p:     pmbase*256 + $200 + p*$80 + (atari_row >> 1)
    // VDELAY[i]=1 shifts the effective row down by 1 (uses cur_row-1).
    // For idx 5 (the row-1 missile byte), eff_row = cur_row - 1 unconditionally.
    function automatic logic [15:0] pm_addr_for(logic [2:0] idx);
        logic [7:0]  eff_row;
        logic [7:0]  byte_idx;
        logic        two_line;
        logic [15:0] base;
        logic [15:0] pm_origin;
        two_line  = !dmactl[4];
        pm_origin = {pmbase, 8'h00};
        case (idx)
            3'd0: eff_row = (vdelay[4] && cur_row != 8'h0) ? cur_row - 8'd1 : cur_row;
            3'd1: eff_row = (vdelay[5] && cur_row != 8'h0) ? cur_row - 8'd1 : cur_row;
            3'd2: eff_row = (vdelay[6] && cur_row != 8'h0) ? cur_row - 8'd1 : cur_row;
            3'd3: eff_row = (vdelay[7] && cur_row != 8'h0) ? cur_row - 8'd1 : cur_row;
            3'd4: eff_row = cur_row;
            3'd5: eff_row = (cur_row != 8'h0) ? cur_row - 8'd1 : cur_row;
            default: eff_row = cur_row;
        endcase
        byte_idx = two_line ? {1'b0, eff_row[7:1]} : eff_row;
        case (idx)
            3'd0: base = two_line ? 16'h0200 : 16'h0400;
            3'd1: base = two_line ? 16'h0280 : 16'h0500;
            3'd2: base = two_line ? 16'h0300 : 16'h0600;
            3'd3: base = two_line ? 16'h0380 : 16'h0700;
            3'd4: base = two_line ? 16'h0180 : 16'h0300;
            3'd5: base = two_line ? 16'h0180 : 16'h0300;
            default: base = 16'h0;
        endcase
        return pm_origin + base + {8'h0, byte_idx};
    endfunction

    // Glyph address: (chbase << 8) | (code_base << 3) | glyph_row.
    logic [15:0] cur_glyph_addr;

    // Post-CHACTL glyph (after vrefl / inv_en / inv_blank).
    logic [7:0]  cur_glyph;

    // ---- Collision-accumulation pipeline (clk_sys closure) --------------
    // The collision latches (mpf/ppf/mpl/ppl) feed the GTIA $D000-$D00F
    // collision reads + HITCLR — they are NOT on the pixel-output path, and
    // the CPU reads them many cycles later.  So the collision math is
    // pipelined off the emit critical path:
    //   emit cycle  : register the pair's PF bits (col_raw_q) AND the two
    //                 resolved P/M presence vectors (col_presL/H_q).  This
    //                 splits the long cone — pack_pair and pm_presence each
    //                 terminate at their own FF (both individually meet 150
    //                 MHz; the pixel path cmd_data uses the same two cones).
    //   next cycle  : collision_combine() does the shallow nibble-AND + 4x4
    //                 P/P matrix from the registered values and ORs into the
    //                 latches.
    // Collisions simply lag the beam by one clk_bus cycle.
    logic [15:0] col_raw_q;        // PF-bit pair, registered for the combine
    logic [7:0]  col_presL_q;      // P/M presence at the pair's low  atari_x
    logic [7:0]  col_presH_q;      // P/M presence at the pair's high atari_x
    logic        col_valid_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state           <= S_IDLE;
            cur_row         <= 8'h0;
            cur_lms         <= 16'h0;
            cur_mode        <= 4'h0;
            cur_sub_row     <= 4'h0;
            unit_idx        <= 6'd0;
            pair_idx  <= 4'd0;
            cur_byte        <= 8'h0;
            cur_code        <= 8'h0;
            cur_code_bit7   <= 1'b0;
            cur_code_bit67  <= 2'd0;
            cur_glyph_addr  <= 16'h0;
            cur_glyph       <= 8'h0;
            is_txt_hscrol   <= 1'b0;
            hsc_phase       <= 1'b0;
            nxt_code        <= 8'h0;
            nxt_code_bit7   <= 1'b0;
            nxt_code_bit67  <= 2'd0;
            nxt_glyph_addr  <= 16'h0;
            nxt_glyph       <= 8'h0;
            hs_byte_offset  <= 2'd0;
            hs_sub_atari    <= 5'd0;
            next_byte       <= 8'h0;
            cmd_valid       <= 1'b0;
            cmd_tag         <= `BUS_TAG_NOP;
            cmd_addr        <= '0;
            cmd_data        <= 24'h0;
            blank_col       <= 9'd0;
            mem_raddr       <= 16'h0;
            meta_row        <= 8'h0;
            compose_done    <= 1'b0;
            compose_count   <= 32'h0;
            mpf_q           <= 16'h0;
            ppf_q           <= 16'h0;
            mpl_q           <= 16'h0;
            ppl_q           <= 16'h0;
            col_raw_q       <= 16'h0;
            col_presL_q     <= 8'h0;
            col_presH_q     <= 8'h0;
            col_valid_q     <= 1'b0;
        end else begin
            compose_done <= 1'b0;
            cmd_valid    <= cmd_valid;     // hold by default
            col_valid_q  <= 1'b0;          // 1-cycle pulse: a pair was produced

            unique case (state)
                S_IDLE: begin
                    cmd_valid <= 1'b0;
                    if (start_compose) begin
                        // option (b): compose exactly the supplied row.  Guard
                        // against an out-of-range index (active band is
                        // 0..ATARI_H-1); the sequencer only fires in-band, so
                        // an out-of-range request just stays idle (dropped).
                        cur_row <= row_in;
                        if (row_in < ATARI_H[7:0])
                            state <= S_FETCH_META;
                    end
                end

                S_FETCH_META: begin
                    meta_row <= cur_row;
                    state    <= S_LATCH_META;
                end

                S_LATCH_META: begin
                    cur_mode    <= meta_mode;
                    cur_lms     <= meta_lms_addr;
                    cur_sub_row <= meta_sub_row;
                    unit_idx    <= 6'd0;
                    pair_idx    <= 4'd0;
                    pm_fetch_idx<= 3'd0;
                    // M11 / M11c / M11d HSCROL state. atari px shift =
                    // 2*hscrol = 0..30. The byte_offset / sub_atari split
                    // depends on atari-px-per-source-byte, which varies
                    // by mode:
                    //   F / D / E / 2 / 3 / 4 / 5 →  8 atari/byte → byte=shift[4:3], sub=shift[2:0]
                    //   A / B / C / 6 / 7         → 16 atari/byte → byte=shift[4],   sub=shift[3:0]
                    //   8 / 9                     → 32 atari/byte → byte=0,          sub=shift[4:0]
                    if (meta_hscrol_en) begin
                        case (meta_mode)
                            4'h8, 4'h9: begin
                                hs_byte_offset <= 2'd0;
                                hs_sub_atari   <= {hscrol, 1'b0};
                            end
                            4'h6, 4'h7, 4'hA, 4'hB, 4'hC: begin
                                hs_byte_offset <= {1'b0, hscrol[3]};
                                hs_sub_atari   <= {1'b0, hscrol[2:0], 1'b0};
                            end
                            default: begin   // F / D / E / 2 / 3 / 4 / 5
                                hs_byte_offset <= hscrol[3:2];
                                hs_sub_atari   <= {2'b00, hscrol[1:0], 1'b0};
                            end
                        endcase
                    end else begin
                        hs_byte_offset <= 2'd0;
                        hs_sub_atari   <= 5'd0;
                    end
                    is_txt_hscrol <= meta_hscrol_en && is_char_mode_f(meta_mode);
                    hsc_phase     <= 1'b0;
                    if (meta_mode == 4'hF || is_gfx_mode_f(meta_mode)
                        || is_char_mode_f(meta_mode)) begin
                        // All visible modes go through the P/M shape
                        // fetch first; mode dispatch happens after.
                        state <= S_PM_FETCH;
                    end else begin
                        // Blank ($x0) line or an unsupported mode (e.g. 3): paint
                        // the whole active row with background (idx 0 -> COLBK) so
                        // the writeback always gets a fully-written row — no stale
                        // / FF-garbage rows on real DDR — and a mid-screen blank
                        // line renders as a COLBK band.
                        blank_col <= 9'd0;
                        state     <= S_BLANK_FILL;
                    end
                end

                // ==== P/M shape fetch loop (P0, P1, P2, P3, M-byte) ======
                S_PM_FETCH: begin
                    mem_raddr <= pm_addr_for(pm_fetch_idx);
                    state     <= S_PM_WAIT;
                end
                S_PM_WAIT: if (mem_ready) state <= S_PM_LATCH;
                S_PM_LATCH: begin
                    case (pm_fetch_idx)
                        3'd0: p0_shape     <= mem_rdata;
                        3'd1: p1_shape     <= mem_rdata;
                        3'd2: p2_shape     <= mem_rdata;
                        3'd3: p3_shape     <= mem_rdata;
                        3'd4: ms_byte      <= mem_rdata;
                        3'd5: ms_byte_prev <= mem_rdata;
                        default: ;
                    endcase
                    if (pm_fetch_idx == 3'd5) begin
                        // All entities fetched — dispatch to mode path.
                        // M11c: byte-source modes (F + gfx 8-E) all go
                        // through the HSCROL-aware shift-register path.
                        // The pack helper dispatches on cur_mode to pick
                        // the right per-mode pixel unpack. Char modes
                        // still take their dedicated code+glyph path.
                        if (cur_mode == 4'hF || is_gfx_mode_f(cur_mode)) begin
                            state <= S_HS_FETCH_PRE;
                        end else begin
                            state <= S_TXT_FETCH_CODE;
                        end
                    end else begin
                        pm_fetch_idx <= pm_fetch_idx + 3'd1;
                        state        <= S_PM_FETCH;
                    end
                end

                // ==== Mode F path ============================================
                S_F_FETCH_BYTE: begin
                    mem_raddr <= cur_lms + {10'h0, unit_idx};
                    state     <= S_F_WAIT_BYTE;
                end

                S_F_WAIT_BYTE: if (mem_ready) state <= S_F_LATCH_BYTE;

                S_F_LATCH_BYTE: begin : sblk_f_latch
                    logic [15:0] raw_f;
                    raw_f     = pack_pair(cur_mode, mem_rdata, 8'h0, 4'd0);
                    cur_byte  <= mem_rdata;
                    pair_idx  <= 4'd0;
                    cmd_tag   <= `BUS_TAG_SET;
                    cmd_addr  <= set_addr;
                    cmd_data  <= apply_pm_overlay(raw_f, pair_atari_x_lo);
                    cmd_valid <= 1'b1;
                    col_raw_q   <= raw_f;           // combined + accumulated next cycle
                    col_presL_q <= pm_presence(pair_atari_x_lo);
                    col_presH_q <= pm_presence(pair_atari_x_lo + 10'd1);
                    col_valid_q <= 1'b1;
                    state     <= S_ISSUE_SET;
                end

                // ==== Mode F + HSCROL path (shift-register windowing) =======
                S_HS_FETCH_PRE: begin
                    // Pre-fetch the byte that will become cur_byte for unit 0.
                    mem_raddr <= cur_lms + {14'h0, hs_byte_offset};
                    state     <= S_HS_WAIT_PRE;
                end
                S_HS_WAIT_PRE: if (mem_ready) state <= S_HS_LATCH_PRE;
                S_HS_LATCH_PRE: begin
                    cur_byte <= mem_rdata;
                    state    <= S_HS_FETCH_BYTE;
                end

                S_HS_FETCH_BYTE: begin
                    // Fetch the byte to the RIGHT of cur_byte (i.e. the
                    // "next_byte" of the shift register) for the current
                    // unit_idx. Address = cur_lms + hs_byte_offset + unit_idx + 1.
                    mem_raddr <= cur_lms + {14'h0, hs_byte_offset}
                               + {10'h0, unit_idx} + 16'd1;
                    state     <= S_HS_WAIT_BYTE;
                end
                S_HS_WAIT_BYTE: if (mem_ready) state <= S_HS_LATCH_BYTE;

                S_HS_LATCH_BYTE: begin : sblk_hs_latch
                    logic [15:0] window;
                    logic [15:0] raw_h;       // PF-bit encoding (collision input)
                    logic [15:0] idx_h;       // value actually stored in idx_buf
                    window = {cur_byte, mem_rdata};
                    // Mode-dispatched pack: F → bit-set window (or GTIA
                    // nibble); 8-E → per-mode gfx_window unpack.
                    if (cur_mode == 4'hF) begin
                        raw_h = pack_pair_F_window(window, 4'd0, hs_sub_atari);
                        if (prior[7:6] != 2'b00)
                            idx_h = pack_pair_F_gtia_window(window, 4'd0, hs_sub_atari);
                        else
                            idx_h = raw_h;
                    end else begin
                        // Graphics modes 8-E.
                        raw_h = pack_pair_gfx_window(cur_mode, window, 4'd0, hs_sub_atari);
                        idx_h = raw_h;
                    end
                    next_byte <= mem_rdata;
                    pair_idx  <= 4'd0;
                    cmd_tag   <= `BUS_TAG_SET;
                    cmd_addr  <= set_addr;
                    cmd_data  <= apply_pm_overlay(idx_h, pair_atari_x_lo);
                    cmd_valid <= 1'b1;
                    col_raw_q   <= raw_h;           // combined + accumulated next cycle
                    col_presL_q <= pm_presence(pair_atari_x_lo);
                    col_presH_q <= pm_presence(pair_atari_x_lo + 10'd1);
                    col_valid_q <= 1'b1;
                    state     <= S_ISSUE_SET;
                end

                // ==== Char-mode path (modes 2/3/4/5/6/7) ====================
                // M11d: when meta_hscrol_en is set, hsc_phase sequences
                // a 2-char window. Phase 0 fetches cur_code+cur_glyph;
                // phase 1 fetches nxt_code+nxt_glyph; emit happens at
                // phase 1's S_TXT_LATCH_GLYPH using pack_pair_txt_window.
                // Non-HSCROL char mode keeps phase=0 for the whole row
                // and emits at the cur LATCH (= legacy behavior).
                S_TXT_FETCH_CODE: begin
                    // Address depends on phase + HSCROL state. In non-
                    // HSCROL the address is cur_lms + unit_idx (legacy).
                    // With HSCROL: phase-0 fetches the cur side at
                    // (lms + unit_idx + hs_byte_offset); phase-1 fetches
                    // the nxt side at (... + 1).
                    if (is_txt_hscrol)
                        mem_raddr <= cur_lms + {10'h0, unit_idx}
                                    + {14'h0, hs_byte_offset}
                                    + (hsc_phase ? 16'd1 : 16'd0);
                    else
                        mem_raddr <= cur_lms + {10'h0, unit_idx};
                    state <= S_TXT_WAIT_CODE;
                end

                S_TXT_WAIT_CODE: if (mem_ready) state <= S_TXT_LATCH_CODE;

                S_TXT_LATCH_CODE: begin
                    if (is_txt_hscrol && hsc_phase) begin
                        nxt_code        <= mem_rdata;
                        nxt_code_bit7   <= mem_rdata[7];
                        nxt_code_bit67  <= mem_rdata[7:6];
                        nxt_glyph_addr  <= compute_glyph_addr(chbase, mem_rdata,
                                                               cur_mode, cur_sub_row);
                    end else begin
                        cur_code       <= mem_rdata;
                        cur_code_bit7  <= mem_rdata[7];
                        cur_code_bit67 <= mem_rdata[7:6];
                        cur_glyph_addr <= compute_glyph_addr(chbase, mem_rdata,
                                                              cur_mode, cur_sub_row);
                    end
                    state <= S_TXT_FETCH_GLYPH;
                end

                S_TXT_FETCH_GLYPH: begin
                    mem_raddr <= (is_txt_hscrol && hsc_phase)
                                  ? nxt_glyph_addr
                                  : cur_glyph_addr;
                    state     <= S_TXT_WAIT_GLYPH;
                end

                S_TXT_WAIT_GLYPH: if (mem_ready) state <= S_TXT_LATCH_GLYPH;

                S_TXT_LATCH_GLYPH: begin : sblk_txt_latch
                    logic [7:0]  glyph_eff;
                    logic [7:0]  blanking_code;
                    logic        blanking_b7;
                    logic [15:0] raw_t;
                    // Pick which char's bits drive the inv-blank / mode-3
                    // descender blanking. In HSCROL phase 1 we're latching
                    // the nxt char; otherwise it's the cur char.
                    if (is_txt_hscrol && hsc_phase) begin
                        blanking_code = nxt_code;
                        blanking_b7   = nxt_code_bit7;
                    end else begin
                        blanking_code = cur_code;
                        blanking_b7   = cur_code_bit7;
                    end
                    // chactl[0] = vrefl (handled via glyph_row); [1] = inv_en;
                    // [2] = inv_blank. Modes 4-7 take raw glyph (per
                    // rp-antic's expand.c).
                    if (cur_mode == 4'h2 && chactl[2] && blanking_b7)
                        glyph_eff = 8'h00;
                    else if (cur_mode == 4'h2 && chactl[1] && blanking_b7)
                        glyph_eff = mem_rdata ^ 8'hFF;
                    // Mode 3: codes 0..95 (code[6:5] != 11) blank rows
                    // 8/9 of the 10-scan-line cell. Codes 96..127
                    // (descenders) use rows 6/7 of the glyph for sub 0/1
                    // — handled by glyph_row() picking the right address.
                    else if (cur_mode == 4'h3 && blanking_code[6:5] != 2'b11
                             && cur_sub_row >= 4'd8)
                        glyph_eff = 8'h00;
                    else
                        glyph_eff = mem_rdata;

                    if (is_txt_hscrol && !hsc_phase) begin
                        // Just finished cur fetch — store, advance to nxt.
                        cur_glyph <= glyph_eff;
                        hsc_phase <= 1'b1;
                        state     <= S_TXT_FETCH_CODE;
                    end else begin
                        // Either non-HSCROL (emit pair 0 from cur), or
                        // HSCROL phase 1 (emit pair 0 from window).
                        if (is_txt_hscrol) begin
                            nxt_glyph <= glyph_eff;
                            raw_t = pack_pair_txt_window(
                                        cur_mode,
                                        cur_glyph, cur_code,
                                        glyph_eff, nxt_code,
                                        4'd0, hs_sub_atari);
                        end else begin
                            cur_glyph <= glyph_eff;
                            raw_t = pack_pair(cur_mode, glyph_eff, cur_code, 4'd0);
                        end
                        pair_idx  <= 4'd0;
                        cmd_tag   <= `BUS_TAG_SET;
                        cmd_addr  <= set_addr;
                        cmd_data  <= apply_pm_overlay(raw_t, pair_atari_x_lo);
                        cmd_valid <= 1'b1;
                        col_raw_q   <= raw_t;           // combined + accumulated next cycle
                        col_presL_q <= pm_presence(pair_atari_x_lo);
                        col_presH_q <= pm_presence(pair_atari_x_lo + 10'd1);
                        col_valid_q <= 1'b1;
                        state     <= S_ISSUE_SET;
                    end
                end

                // ==== Shared SET issuance ====================================
                S_ISSUE_SET: begin
`ifdef COMPOSITOR_TRACE
                    if (cmd_valid && cmd_ready) begin
                        $display("[cmp] r=%0d u=%0d p=%0d addr=$%06h data=$%04h byte=$%02h glyph=$%02h",
                                 cur_row, unit_idx, pair_idx,
                                 cmd_addr, cmd_data, cur_byte, cur_glyph);
                    end
`endif
                    if (cmd_valid && cmd_ready) begin
                        if (pair_idx == max_pair_idx(cur_mode)) begin
                            // Last pair of this unit.
                            if (unit_idx == units_per_row(cur_mode) - 6'd1) begin
                                cmd_valid <= 1'b0;
                                state     <= S_NEXT_ROW;
                            end else begin
                                unit_idx  <= unit_idx + 6'd1;
                                pair_idx  <= 4'd0;
                                cmd_valid <= 1'b0;
                                if (cur_mode == 4'hF || is_gfx_mode_f(cur_mode)) begin
                                    // Byte-source modes — promote shift
                                    // register and fetch the next byte
                                    // for the window.
                                    cur_byte <= next_byte;
                                    state    <= S_HS_FETCH_BYTE;
                                end else if (is_txt_hscrol) begin
                                    // M11d: char-mode HSCROL — promote
                                    // nxt → cur, fetch new nxt for the
                                    // advanced unit.
                                    cur_code       <= nxt_code;
                                    cur_code_bit7  <= nxt_code_bit7;
                                    cur_code_bit67 <= nxt_code_bit67;
                                    cur_glyph      <= nxt_glyph;
                                    hsc_phase      <= 1'b1;
                                    state          <= S_TXT_FETCH_CODE;
                                end else begin
                                    state <= S_TXT_FETCH_CODE;
                                end
                            end
                        end else begin : sblk_issue_advance
                            logic [15:0] raw_a;       // PF-bit form (collision)
                            logic [15:0] idx_a;       // stored value
                            logic [9:0]  next_x_lo;
                            logic [3:0]  next_p;
                            next_p    = pair_idx + 4'd1;
                            next_x_lo = unit_offset[9:0] + {next_p, 1'b0};
                            // Byte-source modes use the windowed packer;
                            // char modes use either the windowed text
                            // packer (HSCROL) or legacy pack_pair (no HSCROL).
                            if (cur_mode == 4'hF) begin
                                raw_a = pack_pair_F_window(
                                            {cur_byte, next_byte},
                                            next_p, hs_sub_atari);
                                idx_a = (prior[7:6] != 2'b00)
                                          ? pack_pair_F_gtia_window(
                                                {cur_byte, next_byte},
                                                next_p, hs_sub_atari)
                                          : raw_a;
                            end else if (is_gfx_mode_f(cur_mode)) begin
                                raw_a = pack_pair_gfx_window(
                                            cur_mode,
                                            {cur_byte, next_byte},
                                            next_p, hs_sub_atari);
                                idx_a = raw_a;
                            end else if (is_txt_hscrol) begin
                                raw_a = pack_pair_txt_window(
                                            cur_mode,
                                            cur_glyph, cur_code,
                                            nxt_glyph, nxt_code,
                                            next_p, hs_sub_atari);
                                idx_a = raw_a;
                            end else begin
                                raw_a = pack_pair(cur_mode,
                                                   cur_glyph,
                                                   cur_code, next_p);
                                idx_a = raw_a;
                            end
                            pair_idx <= next_p;
                            cmd_addr <= row_base + unit_offset
                                      + {next_p, 1'b0};
                            cmd_data <= apply_pm_overlay(idx_a, next_x_lo);
                            col_raw_q   <= raw_a;           // combined + accumulated next cycle
                            col_presL_q <= pm_presence(next_x_lo);
                            col_presH_q <= pm_presence(next_x_lo + 10'd1);
                            col_valid_q <= 1'b1;
                        end
                    end
                end

                // ==== Blank / unsupported-row background fill ===============
                // Issue BLANK_PAIRS pairs of idx 0 (-> COLBK after the colour
                // resolver) across the active row.  cmd_ready is always high in
                // this build, so one pair is accepted per cycle; the render tap
                // counts accepted pairs with its own counter and caps at the
                // active width, so cmd_addr here is cosmetic.  col_valid_q stays
                // low (default) — blank pixels make no collision contribution.
                S_BLANK_FILL: begin
                    cmd_tag   <= `BUS_TAG_SET;
                    cmd_addr  <= row_base + {blank_col, 1'b0};
                    cmd_data  <= 24'h0;            // both pixels of the pair -> COLBK
                    cmd_valid <= 1'b1;
                    if (cmd_valid && cmd_ready) begin
                        if (blank_col == BLANK_PAIRS[8:0] - 9'd1) begin
                            cmd_valid <= 1'b0;
                            state     <= S_NEXT_ROW;
                        end else begin
                            blank_col <= blank_col + 9'd1;
                        end
                    end
                end

                S_NEXT_ROW: begin
                    // option (b): one row per start_compose.  The
                    // antic_seq sequencer supplies the row (= ar_atari_row) and
                    // pulses start_compose once per active scanline, so the
                    // compositor no longer self-walks rows 0..ATARI_H-1.
                    compose_done  <= 1'b1;
                    compose_count <= compose_count + 32'd1;
                    state         <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase

            // Pipelined collision accumulate: OR the previous cycle's
            // registered contribution into the latches.  One OR level — short
            // path.  (HITCLR below still wins over this same-cycle update.)
            if (col_valid_q) begin : sblk_col_acc
                logic [63:0] cc;
                cc = collision_combine(col_raw_q, col_presL_q, col_presH_q);
                mpf_q <= mpf_q | cc[15:0];
                ppf_q <= ppf_q | cc[31:16];
                mpl_q <= mpl_q | cc[47:32];
                ppl_q <= ppl_q | cc[63:48];
            end

            // HITCLR override — strobed by gtia_regs on $D01E write. Wins
            // over any same-cycle collision OR-update.
            if (hitclr) begin
                mpf_q <= 16'h0;
                ppf_q <= 16'h0;
                mpl_q <= 16'h0;
                ppl_q <= 16'h0;
            end
        end
    end

endmodule

`default_nettype wire
