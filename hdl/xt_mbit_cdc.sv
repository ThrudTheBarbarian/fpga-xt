// xt_mbit_cdc.sv — carry a SLOW-CHANGING multi-bit value across clock domains
// without ever handing the far side a torn word.
//
// WHY THIS EXISTS
// ---------------
// The recurring defect class in this project is the multi-bit crossing: N flops
// 2-FF synchronised independently, sampled while several of them are changing,
// so the reader occasionally sees a word that never existed.  It presents as a
// position-pinned display artefact or a "non-deterministic" test, and it has
// cost days more than once.  A plain `(* ASYNC_REG *) reg [7:0]` pair is NOT a
// multi-bit crossing primitive, however many times it appears to work.
//
// The fix is the standard one: never synchronise the DATA at all.  Park it in a
// register that is provably stable, cross a SINGLE bit that says "it changed",
// and let the far side latch the parked copy once that bit has arrived.
//
//   src:  data lands in `hold`            (cycle N)
//         `tgl` flips one cycle LATER     (cycle N+1)   <-- the separation
//   dst:  `tgl` arrives through 2 FFs     (+2 dst clks)
//         the edge latches `hold`         (+3 dst clks)
//
// So `hold` has been stable for at least one source clock plus three
// destination clocks before anybody reads it.  Only `tgl` crosses
// asynchronously, and a toggle cannot be missed the way a pulse can.
//
// THE CONSTRAINT, STATED PLAINLY
// ------------------------------
// `src_data` must hold each new value for at least (2 src + 3 dst) clocks.
// This is a SLOW-signal primitive: it is for things that change once a scanline
// or once a frame, not for a bus.  If the source can change faster than the
// handshake completes, `hold` may move while the destination is latching it and
// the tearing this module exists to prevent comes straight back.  Nothing here
// detects that, because detecting it costs a full four-phase ack and the users
// this was written for (ANTIC's VCOUNT, ~6,400 clk_sys apart; NMIST, a few
// events a frame) clear the bar by three orders of magnitude.
//
// Intermediate values are DROPPED, not queued: if the source changes twice in
// quick succession the destination may only ever see the second.  That is the
// right behaviour for a state value ("what is VCOUNT now?") and the wrong
// behaviour for an event stream.  Do not use this for events.
`ifndef XT_MBIT_CDC_SV
`define XT_MBIT_CDC_SV

module xt_mbit_cdc #(
    parameter int W = 8
) (
    // ---- source domain ----
    input  wire          src_clk,
    input  wire          src_rst,      // active-high, src domain
    input  wire [W-1:0]  src_data,

    // ---- destination domain ----
    input  wire          dst_clk,
    input  wire          dst_rst,      // active-high, dst domain
    output reg  [W-1:0]  dst_data
);

    // ---- source: park the value, then announce it -----------------------
    // The `else if` is what separates them: on the cycle `hold` is written,
    // `pending` goes up and `tgl` does NOT move.  It moves on the NEXT cycle,
    // by which time `hold` is settled.  Collapsing these into one cycle would
    // let the flag race its own data across the boundary.
    reg [W-1:0] hold;
    reg         pending, tgl;

    always_ff @(posedge src_clk or posedge src_rst) begin
        if (src_rst) begin
            hold    <= {W{1'b0}};
            pending <= 1'b0;
            tgl     <= 1'b0;
        end else if (src_data != hold) begin
            hold    <= src_data;
            pending <= 1'b1;
        end else if (pending) begin
            pending <= 1'b0;
            tgl     <= ~tgl;
        end
    end

    // ---- destination: latch the parked copy on the announcement ---------
    (* ASYNC_REG = "TRUE" *) reg [2:0] tgl_s;

    always_ff @(posedge dst_clk or posedge dst_rst) begin
        if (dst_rst) begin
            tgl_s    <= 3'b000;
            dst_data <= {W{1'b0}};
        end else begin
            tgl_s <= {tgl_s[1:0], tgl};
            // tgl_s[2] vs tgl_s[1]: both are past the 2-FF synchroniser, so the
            // edge is metastability-resolved before it gates the latch.
            if (tgl_s[2] ^ tgl_s[1])
                dst_data <= hold;
        end
    end

endmodule

`endif // XT_MBIT_CDC_SV
