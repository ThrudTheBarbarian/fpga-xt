`default_nettype none
//
// antic2_dl — the display-list instruction executor, transcribed from
// emu/antic.c:antic_dl_exec().
//
// THE ORDERING TRAP, and it is the first thing this module gets right.  A
// BLANK-LINE instruction (mode 0) has NO option bits except the DLI: bits 6-4
// are its LINE COUNT, plus one.  Decoding bit 6 as LMS first -- which is the
// obvious "handle the option bits, then switch on the mode" shape -- makes $70
// look like an LMS, eats TWO BYTES of the display list as its operand, and
// derails everything after it.  So mode 0 and mode 1 are decided BEFORE bit 6 is
// ever looked at.
//
// VERTICAL SCROLLING IS A ROW-COUNTER TRICK, NOT A HEIGHT ADJUSTMENT.  emu is
// explicit, and antic_vscroldli is built on it:
//
//   entering a scrolled region -- the counter STARTS at VSCROL, so the first row
//     is short by that much;
//   leaving one -- the next row starts at 0 and ends when the counter reaches
//     VSCROL, compared LIVE every scanline.
//
// "That live compare is the whole of antic_vscroldli: a VSCROL write one cycle
// either side of the comparison moves the row's end, and with it the following
// DLI.  DERIVING A FIXED HEIGHT AT FETCH TIME CANNOT EXPRESS IT."  Hence
// `row_end_live`: -1 in emu, a flag here, meaning "compare against VSCROL as it
// stands at this instant" rather than against a number latched now.
//
// The blank-line instruction takes part in that too -- the $F0 after the
// scrolled mode 8 row is what antic_vscroldli actually measures.
//
`timescale 1ns/1ps

module antic2_dl (
    input  wire        clk,
    input  wire        rst,

    input  wire        exec_req,        // fetch and execute one instruction
    input  wire  [7:0] mem_data,
    input  wire        mem_valid,
    output logic       mem_req,
    output logic [15:0] mem_addr,

    // The DL counter is loaded by a CPU write to DLISTL/H.  Without this the
    // list is fetched from $0000 -- which reads $00, a one-line blank with no
    // DLI -- so the list appears to run and nothing ever interrupts.
    input  wire        dlist_lo_stb,
    input  wire        dlist_hi_stb,
    input  wire  [7:0] dlist_val,

    input  wire  [7:0] vscrol,
    input  wire  [4:0] mode_rows,       // from antic_mode_tbl, for modes >= 2

    output logic [7:0] dl_insn,
    output logic [15:0] dl_addr,        // the display-list pointer
    output logic [15:0] pf_addr,        // the playfield scan address (LMS)
    output logic [3:0]  row_end,        // the row's last scanline...
    output logic        row_end_live,   // ...unless this is set: compare LIVE
                                        //    against VSCROL every scanline
    output logic [3:0]  row_line_load,  // entering a scrolled region: start high
    output logic        row_line_set,
    output logic        jvb_pulse,      // ONE CYCLE when a JVB is decoded.
                                       // antic2_line OWNS the parked state:
                                       // a LEVEL here re-set it every clock,
                                       // the list never unparked, nothing was
                                       // ever fetched and no DLI could fire.
    output logic        busy
);

    typedef enum logic [2:0] {
        S_IDLE, S_INSN, S_LO, S_HI, S_DONE
    } state_t;
    state_t st;

    logic       vscrol_prev;
    logic       want_operand;   // this instruction takes a 2-byte operand
    logic       is_jump;        // ...and it is a JUMP rather than an LMS
    logic [7:0] insn_r;
    logic [7:0] lo_r;

    // Decoded from the LATCHED instruction, in the order emu decides them.
    wire [3:0] mode     = insn_r[3:0];
    wire       vs       = (mode >= 4'd2) && insn_r[5];
    wire       leaving  = vscrol_prev && !vs;
    wire       entering = vs && !vscrol_prev;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            st            <= S_IDLE;
            mem_req       <= 1'b0;
            mem_addr      <= 16'h0000;
            dl_insn       <= 8'h00;
            dl_addr       <= 16'h0000;
            pf_addr       <= 16'h0000;
            row_end       <= 4'd0;
            row_end_live  <= 1'b0;
            row_line_load <= 4'd0;
            row_line_set  <= 1'b0;
            jvb_pulse     <= 1'b0;
            busy          <= 1'b0;
            vscrol_prev   <= 1'b0;
            want_operand  <= 1'b0;
            is_jump       <= 1'b0;
            insn_r        <= 8'h00;
            lo_r          <= 8'h00;
        end else begin
            row_line_set <= 1'b0;
            mem_req      <= 1'b0;
            jvb_pulse    <= 1'b0;

            case (st)
            S_IDLE: begin
                if (exec_req) begin
                    mem_req  <= 1'b1;
                    mem_addr <= dl_addr;
                    busy     <= 1'b1;
                    st       <= S_INSN;
                end
            end

            S_INSN: if (mem_valid) begin
                insn_r      <= mem_data;
                dl_insn     <= mem_data;
                dl_addr     <= dl_addr + 16'd1;
                vscrol_prev <= (mem_data[3:0] >= 4'd2) && mem_data[5];

                // MODE 0 and MODE 1 ARE DECIDED FIRST, before bit 6 means LMS.
                if (mem_data[3:0] == 4'h0) begin
                    // Blank line: bits 6-4 are the LINE COUNT, plus one.  No
                    // LMS, no operand.  `leaving` still applies -- the blank
                    // instruction takes part in the scroll compare.
                    row_end      <= {1'b0, mem_data[6:4]};
                    row_end_live <= vscrol_prev && !1'b0;   // leaving, vs=0 here
                    busy         <= 1'b0;
                    st           <= S_DONE;
                end
                else if (mem_data[3:0] == 4'h1) begin
                    // Jump: two operand bytes reload the DL pointer.  Bit 6 is
                    // JVB -- park until vertical blank ENDS, not until the frame
                    // wraps.
                    want_operand <= 1'b1;
                    is_jump      <= 1'b1;
                    mem_req      <= 1'b1;
                    mem_addr     <= dl_addr + 16'd1;
                    st           <= S_LO;
                end
                else begin
                    // Modes 2..15.  NOW bit 6 is LMS.
                    if (mem_data[6]) begin
                        want_operand <= 1'b1;
                        is_jump      <= 1'b0;
                        mem_req      <= 1'b1;
                        mem_addr     <= dl_addr + 16'd1;
                        st           <= S_LO;
                    end else begin
                        busy <= 1'b0;
                        st   <= S_DONE;
                    end
                end
            end

            S_LO: if (mem_valid) begin
                lo_r     <= mem_data;
                dl_addr  <= dl_addr + 16'd1;
                mem_req  <= 1'b1;
                mem_addr <= dl_addr + 16'd1;
                st       <= S_HI;
            end

            S_HI: if (mem_valid) begin
                dl_addr <= dl_addr + 16'd1;
                if (is_jump) begin
                    dl_addr <= {mem_data, lo_r};
                    jvb_pulse <= insn_r[6];        // JVB
                end else begin
                    // LMS: the operand fetches go through the same 1 KB-wrapping
                    // counter, which is what antic_addresswrap exploits.
                    pf_addr <= {mem_data, lo_r};
                end
                busy <= 1'b0;
                st   <= S_DONE;
            end

            S_DONE: begin
                // Resolve the row height for modes >= 2, and the scroll trick.
                if (mode >= 4'd2) begin
                    row_end      <= 4'(mode_rows - 5'd1);
                    row_end_live <= leaving;       // -1 in emu
                    if (entering) begin
                        row_line_load <= vscrol[3:0];   // start high: short row
                        row_line_set  <= 1'b1;
                    end
                end
                st <= S_IDLE;
            end
            endcase

            // AFTER the case, so a write WINS over an increment in the same
            // cycle: emu applies it straight to dl_addr at write time.
            if (dlist_lo_stb) dl_addr[7:0]  <= dlist_val;
            if (dlist_hi_stb) dl_addr[15:8] <= dlist_val;
        end
    end

endmodule

`default_nettype wire
