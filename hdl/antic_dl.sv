`default_nettype none
//
// antic_dl — the display list machine.
//
// docs/ANTIC-rewrite.md.  This decides WHAT is on each scanline: which mode,
// which memory-scan address, which row of the block, and whether a DLI is due.
// It does not decide WHEN anything is fetched — that is the DMA schedule, and it
// arrives later.  Keeping the two apart is deliberate: the old design tangled
// them and could not fix either without disturbing the other.
//
// THE DL POINTER IS THE REGISTER.  Real ANTIC has no separate program counter:
// DLISTL/DLISTH ($D402/$D403) ARE the counter, so a CPU write mid-frame moves
// the fetch point immediately, and a read gives the live position.  Nothing
// reloads it at the top of a frame — that is what the terminating JVB is for.
// This is both the faithful model and the small one.
//
// WRAPS.  The DL pointer advances within a 1K page (low 10 bits) — pinned by
// antic_dlistwrap.  The memory-scan pointer wraps within 4K, but that belongs to
// the renderer (antic_addresswrap) and is not repeated here; we take the
// renderer's advanced pointer back over scan_ret.
//
// INSTRUCTION FORMAT
//   [3:0] mode   0 = blank lines, 1 = jump, 2..F = display
//   [4]   HSCROL enable
//   [5]   VSCROL enable
//   [6]   LMS on a display mode; "wait for vertical blank" on a jump
//   [7]   DLI
//   mode 0: [6:4] is (blank scanline count - 1), so 1..8 lines
//
// THE DLI RULE IS ONE RULE: the interrupt fires on the LAST scanline of the mode
// line, whatever the mode line is.  Blank-line instructions are not a special
// case — treating them as one is exactly the bug recorded in acid800_dli_cluster
// ("dl_parser maps blank-line DLIs wrong").
//
// VSCROL is one flip-flop and two muxes, which is the whole reason it is cheap
// enough for 1979 silicon:
//   vs_begin = vscrol_bit && !vscroll_active  -> the block STARTS at VSCROL
//   vs_end   = !vscrol_bit && vscroll_active  -> the block ENDS at VSCROL
// A scrolled region is therefore shortened at its top by the first block and
// shortened at its bottom by the first block after it, which moves the content
// up by VSCROL scanlines.  DCTR is 4 bits and wraps, so a VSCROL larger than the
// mode height runs the counter right round — the vertical-scroll "bug" that real
// programs use, present here because it is not special-cased away.
//
// COLD must clear the whole machine, not just the registers the CPU can see.
// A partially-cleared DL machine leaks state between programs and cost a day of
// chasing fake non-determinism (HANDOFF 1n).
//
// CLOCK BUDGET: this runs at fabric speed at the start of each scanline, taking
// 2 clocks per DL byte — at most 3 bytes for an LMS instruction, so under ~10
// clocks of the ~6,300 in a scanline.  There is no reason to make it parallel.
//
`timescale 1ns/1ps

module antic_dl (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold,           // clears the WHOLE machine

    // ---- from the beam ---------------------------------------------------
    input  wire        line_start,     // 1-clk at the start of each scanline
    input  wire        in_vblank,

    // ---- CPU-visible registers -------------------------------------------
    input  wire        dlist_we_l,     // $D402
    input  wire        dlist_we_h,     // $D403
    input  wire [7:0]  dlist_wdata,
    input  wire        dl_dma_en,      // DMACTL bit 5
    input  wire [3:0]  vscrol,         // $D405

    // ---- display list fetch ----------------------------------------------
    output logic [15:0] dl_addr,
    input  wire  [7:0]  dl_data,       // 1-clock read latency
    output logic        dl_rd,

    // ---- the memory scan pointer, kept live across the whole frame -------
    input  wire  [15:0] scan_ret,      // renderer's advanced pointer
    input  wire         scan_we,       // 1-clk: take it

    // ---- what to draw on this scanline -----------------------------------
    output logic        line_ready,    // 1-clk: the outputs below are valid
    output logic [3:0]  mode,
    output logic [15:0] scan_addr,
    output logic [3:0]  row,           // DCTR
    output logic        hscrol_en,
    output logic        line_valid,    // 0 = blank scanline, draw background
    output logic        dli,           // 1-clk with line_ready: fire the NMI

    output wire  [15:0] dlpc           // live DL pointer, for readback
);

    // ---- mode geometry ---------------------------------------------------
    logic [7:0] instr;
    wire        is_char_u, descender_u, is_display;
    wire [1:0]  bpp_u;
    wire [3:0]  px_width_u;
    wire [4:0]  rows;

    antic_mode_tbl u_tbl (
        .mode(instr[3:0]), .is_char(is_char_u), .bpp(bpp_u),
        .px_width(px_width_u), .rows(rows), .descender(descender_u),
        .is_display(is_display)
    );

    wire is_jump  = (instr[3:0] == 4'h1);
    wire is_blank = (instr[3:0] == 4'h0);
    wire dli_bit  = instr[7];
    wire lms_bit  = instr[6];           // "wait for vblank" when is_jump

    // THE SCROLL BITS ONLY EXIST ON DISPLAY MODES.  On a blank instruction
    // [6:4] is the line count, so the standard $70 opener has bit 5 set as part
    // of its count — reading that as VSCROL makes the block AFTER it believe it
    // is closing a scroll region, which ends it at DCTR == VSCROL after a single
    // scanline.  Every real display list starts $70 $70 $70, so this is not a
    // corner case.
    wire vs_bit    = is_display && instr[5];
    wire hs_bit    = is_display && instr[4];

    // Blank instructions carry their own height in [6:4]; display modes take it
    // from the table; a jump occupies no scanline at all.
    wire [4:0] blk_height = is_blank ? (5'({1'b0, instr[6:4]}) + 5'd1) : rows;

    // ---- state -----------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_FETCH, S_FETCH_D, S_OP1, S_OP1_D, S_OP2, S_OP2_D,
        S_BEGIN, S_STEP, S_EMIT, S_BLANK
    } state_t;
    state_t state;

    logic [15:0] pc;
    logic [15:0] memscan;
    logic [7:0]  opl;
    logic [3:0]  row_last;
    logic        vscroll_active;
    logic        need_instr;            // the current block is finished
    logic        parked;                // JVB: DMA halted until vblank
    logic        park_dli;              // the parked instruction's DLI bit
    logic        pend_dli;              // DLI owed by the blank line in flight
    logic [2:0]  chain;                 // runaway-jump guard, see below

    assign dlpc = pc;

    // vs_begin/vs_end are evaluated against the PREVIOUS instruction's bit, so
    // they must be read before vscroll_active is updated at S_BEGIN.
    wire vs_begin = vs_bit && !vscroll_active;
    wire vs_end   = !vs_bit && vscroll_active;

    wire [3:0] row_start_v = vs_begin ? vscrol : 4'd0;
    wire [3:0] row_last_v  = vs_end   ? vscrol : (blk_height[3:0] - 4'd1);

    wire [15:0] pc_next = {pc[15:10], pc[9:0] + 10'd1};   // 1K wrap

    always_ff @(posedge clk or posedge rst) begin
        if (rst || cold) begin
            state          <= S_IDLE;
            pc             <= 16'h0000;
            memscan        <= 16'h0000;
            instr          <= 8'h00;
            opl            <= 8'h00;
            row            <= 4'd0;
            row_last       <= 4'd0;
            vscroll_active <= 1'b0;
            need_instr     <= 1'b1;
            parked         <= 1'b0;
            park_dli       <= 1'b0;
            pend_dli       <= 1'b0;
            chain          <= 3'd0;
            line_ready     <= 1'b0;
            line_valid     <= 1'b0;
            dli            <= 1'b0;
            mode           <= 4'h0;
            scan_addr      <= 16'h0000;
            hscrol_en      <= 1'b0;
            dl_rd          <= 1'b0;
        end else begin
            line_ready <= 1'b0;
            dli        <= 1'b0;
            dl_rd      <= 1'b0;

            // The CPU owns DLISTL/DLISTH directly; a write moves the fetch
            // point with no frame-boundary indirection.
            if (dlist_we_l) pc[7:0]  <= dlist_wdata;
            if (dlist_we_h) pc[15:8] <= dlist_wdata;

            // The renderer hands the advanced scan pointer back at end of line.
            if (scan_we) memscan <= scan_ret;

            case (state)
                // ---- between scanlines ---------------------------------
                S_IDLE: begin
                    if (line_start) begin
                        chain <= 3'd0;
                        if (parked) begin
                            // JVB has already loaded the target; DMA stays off
                            // until vertical blank.  antic_dlistwrap pins that
                            // the DLI keeps firing while parked.
                            if (in_vblank) begin
                                parked <= 1'b0;
                                state  <= S_FETCH;
                            end else begin
                                pend_dli <= park_dli;
                                state    <= S_BLANK;
                            end
                        end else if (!dl_dma_en) begin
                            pend_dli <= 1'b0;
                            state    <= S_BLANK;
                        end else if (need_instr) begin
                            state <= S_FETCH;
                        end else begin
                            state <= S_STEP;
                        end
                    end
                end

                // ---- instruction fetch ---------------------------------
                S_FETCH: begin
                    dl_rd <= 1'b1;
                    state <= S_FETCH_D;
                end
                S_FETCH_D: begin
                    instr <= dl_data;
                    pc    <= pc_next;
                    // A jump needs its operand; so does an LMS on a display
                    // mode.  Everything else starts drawing immediately.
                    if (dl_data[3:0] == 4'h1)                      state <= S_OP1;
                    else if (dl_data[6] && (dl_data[3:0] >= 4'h2)) state <= S_OP1;
                    else                                            state <= S_BEGIN;
                end

                S_OP1: begin
                    dl_rd <= 1'b1;
                    state <= S_OP1_D;
                end
                S_OP1_D: begin
                    opl   <= dl_data;
                    pc    <= pc_next;
                    state <= S_OP2;
                end
                S_OP2: begin
                    dl_rd <= 1'b1;
                    state <= S_OP2_D;
                end
                S_OP2_D: begin
                    if (is_jump) begin
                        pc <= {dl_data, opl};
                        if (lms_bit) begin        // JVB
                            parked   <= 1'b1;
                            park_dli <= dli_bit;
                            pend_dli <= dli_bit;
                            state    <= S_BLANK;
                        end else begin
                            // A plain jump consumes no scanline, so go straight
                            // back for the real instruction.  The chain guard
                            // is NOT Atari behaviour: a display list that jumps
                            // to itself hangs real ANTIC too, but here it would
                            // wedge the whole video pipeline, so cap it.
                            chain    <= chain + 3'd1;
                            pend_dli <= 1'b0;
                            // if/else, not a ternary: assigning an enum from a
                            // conditional expression needs an explicit cast.
                            if (chain == 3'd7) state <= S_BLANK;
                            else               state <= S_FETCH;
                        end
                    end else begin
                        memscan <= {dl_data, opl};
                        pc      <= pc_next;
                        state   <= S_BEGIN;
                    end
                end

                // ---- first scanline of a mode line ---------------------
                S_BEGIN: begin
                    row            <= row_start_v;
                    row_last       <= row_last_v;
                    vscroll_active <= vs_bit;
                    state          <= S_EMIT;
                end

                // ---- a later scanline of the same mode line ------------
                S_STEP: begin
                    row   <= row + 4'd1;    // 4-bit, wraps: the vscroll bug
                    state <= S_EMIT;
                end

                // ---- hand the scanline to the renderer -----------------
                S_EMIT: begin
                    line_ready <= 1'b1;
                    line_valid <= is_display;
                    mode       <= instr[3:0];
                    scan_addr  <= memscan;
                    hscrol_en  <= hs_bit;
                    // One rule for every mode line, blank ones included.
                    dli        <= dli_bit && (row == row_last);
                    need_instr <= (row == row_last);
                    state      <= S_IDLE;
                end

                // ---- nothing to draw -----------------------------------
                S_BLANK: begin
                    line_ready <= 1'b1;
                    line_valid <= 1'b0;
                    mode       <= 4'h0;
                    dli        <= pend_dli;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // The only address this module ever drives is the DL pointer.
    always_comb dl_addr = pc;

endmodule

`default_nettype wire
