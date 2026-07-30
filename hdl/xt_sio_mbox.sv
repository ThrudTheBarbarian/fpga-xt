// xt_sio_mbox.sv — paravirtual SIO mailbox: the 6502 asks, the A9 answers.
//
// WHY THIS EXISTS
// ---------------
// The XL OS boots D1: through a stub patched into ROM padding (xl_boot.c
// sio_stub[]).  The stub copies the 12-byte DCB into a shared page, rings a
// doorbell, spins on a "done" bit, then copies the sector back out.  That page
// and that doorbell used to be BORROWED from math_cop -- the $D5C6/$D5C7/$D5C8
// register trio and the $4000-$5FFF aperture overlay are math_cop's, and
// xl_sio_service() ran in the maths worker task off the maths doorbell IRQ.
//
// So dropping math_cop from the build (it exists for the turbo core, which is
// also gone) silently took paravirtual SIO with it: `math_done` tied to 1'b0 is
// the bit the stub polls, so every cold boot wedged at $CB8A -- LDA $D5C7 /
// AND #$01 / BEQ -7 -- and no .xex or .atr could be launched at all.
//
// This module is that mailbox, and nothing else.  Same 6502-facing contract, so
// the ROM stub is UNCHANGED; ~1/20th of the logic, because serving a disk
// sector needs a buffer and a handshake, not a DDR-backed 8 KB paged engine
// with an AXI master and an opcode interpreter.
//
// THE CONTRACT (6502 side, all of it already decoded by sally_mem)
// ----------------------------------------------------------------
//   $D5C6.0  MAP    overlay this mailbox on the CPU's $4000-$5FFF view
//   $D5C7    W      doorbell -- "a request is in the page"
//            R      {5'b0, chunk_ready, busy, done}; the stub polls bit 0
//   $D5C8    chunk  select (the stub writes $FF; we are always resident)
//   $4000+   the mailbox itself: $4003 status, $4004 flags, $4005 magic,
//            $4040 DCB (12 B), $40C0 payload (<=256 B)  [mathcop.h offsets]
//
// 448 bytes are live, so the mailbox is 512 -- one BRAM.  Reads above it return
// $00 rather than aliasing, so a stray access to the rest of the 8 KB aperture
// cannot look like data.
//
// THE HANDSHAKE IS TWO TOGGLE BITS, AND THAT IS DELIBERATE
// --------------------------------------------------------
// The 6502 is in clk_sally, the A9 in clk_sys.  The recurring bug class in this
// project is MULTI-bit crossings sampled mid-change, so nothing multi-bit
// crosses here: the payload lives in a true dual-port BRAM (each port entirely
// in its own domain) and only two SINGLE-bit toggles cross.
//
//   clk_sally  req  toggles on the $D5C7 doorbell write
//   clk_sys    ack  toggles when the A9 writes MATH_DONE ("answer is in")
//   done = (ack seen in clk_sally) == req      -- the answer has caught up
//
// Level-safe by construction: a toggle cannot be missed the way a pulse can,
// and `done` needs no clear-vs-set arbitration between the domains, so there is
// no flop written from two clocks.  At reset req == ack == 0, so done reads 1;
// the stub's FIRST act is the doorbell, which flips req and drops done before
// it ever polls (a machine cycle is ~56 clk_sally, so the 2-FF sync and the one
// pipeline stage are invisible).
//
// The 6502 never touches the page while it spins, and the A9 only touches it
// between doorbell and MATH_DONE, so the two ports are strictly alternating and
// need no arbitration beyond the dual-port BRAM itself.
//
// CLOCK BUDGET: none to state -- this is not in the raster path.  The CPU port
// is one BRAM read per machine cycle (~56 clk_sally available), the A9 port one
// per AXI transaction.
//
// A9 SIDE
// -------
// Reuses the GP0 MATH block's event/done/stat legs unchanged (so IRQ_F2P[1] and
// the worker-task wiring are untouched) plus a small indirect data window:
// write SIO_PTR, then read or write SIO_DAT, which auto-increments.  The BRAM
// read register tracks the pointer continuously, and consecutive AXI
// transactions are tens of clocks apart, so the registered read has always
// settled before the A9 can collect it.
`ifndef XT_SIO_MBOX_SV
`define XT_SIO_MBOX_SV

module xt_sio_mbox #(
    parameter int unsigned APERTURE_LOG2 = 13,       // $4000-$5FFF CPU aperture
    parameter int unsigned MBOX_LOG2     = 9,        // 512 B of it is the mailbox
    parameter logic [7:0]  SIO_CHUNK     = 8'hFF     // chunk id the A9 sees on the event
) (
    // ---- clk_sys: the A9 side -------------------------------------------
    input  wire                     clk,
    input  wire                     rst,

    // GP0 MATH-block legs, same shape math_cop presented
    output wire [8:0]               evt_data,     // R MATH_EVT {valid, chunk}
    input  wire                     evt_pop,      // 1-cycle strobe on that read
    output wire                     evt_irq,      // -> IRQ_F2P[1] (GIC 62)
    input  wire                     done_we,      // W MATH_DONE: the answer is in the page
    output wire [31:0]              stat_word,    // R MATH_STAT

    // GP0 SIO-block data window
    input  wire [MBOX_LOG2-1:0]     a9_ptr,       // W SIO_PTR: byte pointer (word-aligned)
    input  wire                     a9_ptr_we,
    input  wire [31:0]              a9_wdata,     // W SIO_DAT
    input  wire                     a9_we,
    input  wire                     a9_rd,        // R SIO_DAT (strobe: auto-increment)
    output wire [31:0]              a9_rdata,

    // ---- clk_sally: the 6502 side ---------------------------------------
    input  wire                     clk_cpu,
    input  wire                     rst_cpu,
    input  wire [APERTURE_LOG2-1:0] cpu_addr,     // byte address within the aperture
    input  wire                     cpu_we,       // aperture write (sally_mem math_cpu_we)
    input  wire [7:0]               cpu_wdata,
    input  wire                     cpu_rden,     // = SALLY rdy; see the freeze note below
    output wire [7:0]               cpu_rdata,
    input  wire                     exec_we,      // $D5C7 write: the doorbell
    output wire                     done,         // $D5C7.0
    output wire                     busy,         // $D5C7.1
    output wire                     chunk_ready   // $D5C7.2
);

    localparam int WORDS   = (1 << MBOX_LOG2) / 4;   // 128 x 32 bit = 512 B
    localparam int WORD_AW = MBOX_LOG2 - 2;          // 7

    // ====================================================================
    // The mailbox — true dual port.  Port A = 6502 (clk_cpu, byte lanes),
    // port B = A9 (clk, whole words).  Two separate always_ff blocks with no
    // shared signals is the shape that infers a real TDP BRAM (same as
    // math_cop's page and screen_bank).
    // ====================================================================
    (* ram_style = "block" *) logic [31:0] mbox [0:WORDS-1];

    // ---- port A: the 6502 ----------------------------------------------
    // Only the low MBOX_LOG2 bytes of the aperture are ours.
    wire in_range = (cpu_addr[APERTURE_LOG2-1:MBOX_LOG2] == '0);

    wire [WORD_AW-1:0] cpu_word = cpu_addr[MBOX_LOG2-1:2];
    wire [1:0]         cpu_boff = cpu_addr[1:0];
    wire [3:0]         cpu_be   = (cpu_we && in_range) ? (4'd1 << cpu_boff) : 4'd0;

    logic [31:0] cpu_rd_word_q;
    logic [1:0]  cpu_boff_q;
    logic        cpu_inr_q;

    // cpu_rden (= sally_mem's rdy) gates the READ register for the same reason
    // math_cop's did: sally_mem's was_math_q select and its BRAM shadow are both
    // rdy-gated and FREEZE while the CPU is stalled.  A free-running read
    // register would chase the address bus as the MAR advances during the stall
    // and hand back a neighbouring word.  The write leg needs no such gate --
    // cpu_we only asserts on an rdy=1 bus cycle.
    always_ff @(posedge clk_cpu) begin
        for (int b = 0; b < 4; b = b + 1)
            if (cpu_be[b]) mbox[cpu_word][b*8 +: 8] <= cpu_wdata;
        if (cpu_rden) begin
            cpu_rd_word_q <= mbox[cpu_word];
            cpu_boff_q    <= cpu_boff;
            cpu_inr_q     <= in_range;
        end
    end
    // Above the mailbox the aperture reads $00 — never an alias of the mailbox.
    assign cpu_rdata = cpu_inr_q ? cpu_rd_word_q[cpu_boff_q*8 +: 8] : 8'h00;

    // ---- port B: the A9 -------------------------------------------------
    logic [WORD_AW-1:0] ptr_q;
    logic [31:0]        a9_rd_q;

    // The RAM access carries NO reset, and must not: a block sensitive to an
    // asynchronous reset is not a dual-port BRAM template, and with
    // ram_style="block" Vivado rejects it outright rather than falling back to
    // registers ("Unsupported Dual Port Block-RAM template", 2026-07-30).  The
    // pointer keeps its reset in a separate block below — same split math_cop
    // and screen_bank use.
    always_ff @(posedge clk) begin
        if (a9_we)
            for (int b = 0; b < 4; b = b + 1)
                mbox[ptr_q][b*8 +: 8] <= a9_wdata[b*8 +: 8];
        // Read-first on a same-cycle hit; the A9 never does both at once.
        a9_rd_q <= mbox[ptr_q];
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)                    ptr_q <= '0;
        else if (a9_ptr_we)         ptr_q <= a9_ptr[MBOX_LOG2-1:2];
        else if (a9_we | a9_rd)     ptr_q <= ptr_q + 1'b1;   // auto-increment
    end
    assign a9_rdata = a9_rd_q;

    // ====================================================================
    // The handshake — two single-bit toggles, one each way.
    // ====================================================================

    // ---- clk_sally: raise a request on the doorbell ---------------------
    logic req_tgl;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu)      req_tgl <= 1'b0;
        else if (exec_we) req_tgl <= ~req_tgl;
    end

    // ---- clk_sys: see the request, hold it until the worker takes it ----
    logic req_s1, req_s2, req_s3;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) {req_s3, req_s2, req_s1} <= 3'b000;
        else     {req_s3, req_s2, req_s1} <= {req_s2, req_s1, req_tgl};
    end
    wire req_edge = req_s3 ^ req_s2;          // a doorbell arrived

    logic pending;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)           pending <= 1'b0;
        else if (req_edge) pending <= 1'b1;   // set wins: never lose a request
        else if (evt_pop)  pending <= 1'b0;   // the worker has taken it
    end

    // ---- clk_sys: acknowledge when the A9 says the answer is in ---------
    logic ack_tgl;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)          ack_tgl <= 1'b0;
        else if (done_we) ack_tgl <= ~ack_tgl;
    end

    // ---- clk_sally: done when the ack has caught up with the request ----
    logic ack_s1, ack_s2;
    logic done_q;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) begin
            {ack_s2, ack_s1} <= 2'b00;
            done_q           <= 1'b1;         // idle: nothing outstanding
        end else begin
            {ack_s2, ack_s1} <= {ack_s1, ack_tgl};
            // Registered rather than combinational: $D5C7 sits at the tail of
            // the CPU read cone and a diagnostic-grade path there has gated a
            // build before (sally_mem's latency counter, 2026-07-15).  One
            // clk_sally of lag on a bit polled once per machine cycle is noise.
            done_q           <= (ack_s2 == req_tgl);
        end
    end

    assign done        = done_q;
    assign busy        = ~done_q;
    assign chunk_ready = 1'b1;                // a fixed BRAM is always resident

    assign evt_data  = {pending, SIO_CHUNK};
    assign evt_irq   = pending;
    // {ptr, chunk, ack, req, pending} — enough to tell a stuck doorbell from a
    // stuck worker from the A9 side alone.
    assign stat_word = {9'd0, ptr_q, SIO_CHUNK,
                        5'd0, ack_tgl, req_s2, pending};

endmodule

`endif // XT_SIO_MBOX_SV
