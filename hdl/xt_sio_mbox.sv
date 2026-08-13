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
//   $D5CD    R/W    byte index into the mailbox (write = set; read = current)
//   $D5CE    R/W    the byte AT that index; every access post-increments it
//   $D5C7    W      doorbell -- "a request is in the mailbox"
//            R      {5'b0, chunk_ready, busy, done}; the stub polls bit 0
//
// 448 bytes are live, so the mailbox is 512 -- one BRAM.  Offsets are unchanged
// from mathcop.h ($03 status, $04 flags, $05 magic, $40 DCB, $C0 payload), so
// the A9 service code did not move.
//
// A PORT, NOT A WINDOW -- and that is the whole point
// ---------------------------------------------------
// This mailbox used to be reached through the $D5C6.0 aperture, which overlaid
// it on the CPU's view of $4000-$5FFF.  That range is the GUEST'S RAM, so for
// as long as the stub held the map the guest's own memory was gone: an
// interrupt taken anywhere in that window -- and the window spanned the entire
// A9 round-trip, milliseconds -- ran with $4000-$5FFF replaced by a 512-byte
// mailbox aliased sixteen times.  ElektraGlide, which streams its image
// through $0400-$B9FF, derailed into it and died executing the DCB's $52
// (DCOMND) as a KIL.  A two-register port has no window, so there is no
// interval during which the guest's RAM is not its own.
//
// Address-space cost: $D5CD/$D5CE, two bytes inside the $D5C0-$D5CF block
// sally_mem already decodes.  $D6xx/$D7xx were considered and rejected -- PBI
// space, contested by VBXE's D6/D7 install windows (docs/Zynq/register-map.md).
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
    parameter int unsigned MBOX_LOG2     = 9,        // 512 B mailbox = one BRAM
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
    // Reached through two CCTL registers, NOT through a memory aperture — see
    // the port-not-a-window note in the header.
    input  wire                     clk_cpu,
    input  wire                     rst_cpu,
    input  wire                     cpu_idx_we,   // $D5CD write: set the byte index
    input  wire                     cpu_dat_we,   // $D5CE write: store at index, index++
    input  wire                     cpu_dat_re,   // $D5CE read  strobe (EXACTLY once): index++
    input  wire [7:0]               cpu_reg_wdata,
    output wire [7:0]               cpu_idx_rdata,
    output wire [7:0]               cpu_dat_rdata,
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

    // ---- port A: the 6502, through $D5CD (index) / $D5CE (data) ---------
    // The index moves ONLY on an explicit $D5CD write or a $D5CE access, so
    // unlike the old aperture port it never chases the address bus while the
    // CPU stalls — the rden gate that existed purely to stop that is gone.
    //
    // The index is MBOX_LOG2 bits but is SET 8 bits at a time (a $D5CD write
    // zeroes the top bit).  Auto-increment carries into it, so the stub sets
    // the index once per phase and walks a payload straight across $FF -> $100
    // without touching $D5CD again — which is what lets the mailbox keep its
    // existing mathcop.h layout (DCB $40, payload $C0) unchanged.
    logic [MBOX_LOG2-1:0] idx_q;

    wire [WORD_AW-1:0] a_word = idx_q[MBOX_LOG2-1:2];
    wire [1:0]         a_boff = idx_q[1:0];
    wire [3:0]         a_be   = cpu_dat_we ? (4'd1 << a_boff) : 4'd0;

    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu)                      idx_q <= '0;
        else if (cpu_idx_we)              idx_q <= {{(MBOX_LOG2-8){1'b0}}, cpu_reg_wdata};
        else if (cpu_dat_we | cpu_dat_re) idx_q <= idx_q + 1'b1;
    end

    logic [31:0] a_rd_q;
    logic [1:0]  a_boff_q;

    // READ TIMING.  a_rd_q/a_boff_q track idx_q one clk_cpu behind, and idx_q
    // only moves on an access strobe — at most once per machine cycle (~56
    // clk_sally).  sally_mem latches the CCTL read-back at its EARLY read step
    // (fid_mem_step, SUB=2) while the strobe that advances the index lands at
    // SUB_DATA=49, so the value sally_mem captures is always the byte at the
    // PRE-increment index, and the new index has ~8 clks to settle before the
    // next cycle's capture.  No rden gate, no race.
    always_ff @(posedge clk_cpu) begin
        for (int b = 0; b < 4; b = b + 1)
            if (a_be[b]) mbox[a_word][b*8 +: 8] <= cpu_reg_wdata;
        a_rd_q   <= mbox[a_word];
        a_boff_q <= a_boff;
    end
    assign cpu_dat_rdata = a_rd_q[a_boff_q*8 +: 8];
    assign cpu_idx_rdata = idx_q[7:0];

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
