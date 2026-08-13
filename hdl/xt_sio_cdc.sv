`default_nettype none
//
// xt_sio_cdc — the clock crossing between the virtual SIO drive (clk_sally,
// the 6502's domain) and the A9 that services it (clk_sys).
//
// The recurring bug class in this project is a MULTI-BIT crossing sampled
// mid-change, so nothing multi-bit crosses on its own here.  Same discipline as
// xt_sio_mbox: a single-bit TOGGLE crosses, and the payload it refers to is
// written before the toggle flips and held until the far side has consumed it.
// A toggle cannot be missed the way a pulse can.
//
//   clk_sally  req_tgl  flips when the drive validates a command frame;
//                       {dev,cmd,aux1,aux2} are latched in the same cycle and
//                       then held, so by the time clk_sys sees the flip through
//                       two flops the data has been stable for two clk_sally.
//   clk_sys    rsp_tgl  flips when the A9 writes SIO_RSP; {ok,len} likewise.
//
// req_pending (what the A9 polls in SIO_DSTAT) is simply "the request toggle
// has moved but the response toggle has not caught up" — no flag written from
// two clocks, so there is nothing to arbitrate.
//
// own_dev is deliberately NOT toggle-crossed.  It is quasi-static: the A9 sets
// the ownership table once per session, between transactions, and a plain 2-FF
// sync is the right tool.  Its RESET VALUE is 0 = every device unclaimed, which
// is also the fail-safe: if the A9 never writes it, the drive stays silent and
// a real peripheral on the DIN port owns the bus unopposed (sio-bridge.md §13.3).
//
`ifndef XT_SIO_CDC_SV
`define XT_SIO_CDC_SV

module xt_sio_cdc (
    // ---- clk_sally: the drive ------------------------------------------
    input  wire        clk_cpu,
    input  wire        rst_cpu,
    input  wire        req_valid,        // 1-clk from xt_sio_drive
    input  wire [7:0]  req_dev,
    input  wire [7:0]  req_cmd,
    input  wire [7:0]  req_aux1,
    input  wire [7:0]  req_aux2,
    input  wire        drv_busy,
    input  wire [7:0]  dbg_frames,
    input  wire [7:0]  dbg_bytes,
    input  wire [7:0]  dbg_accepted,
    input  wire [7:0]  dbg_replies,
    input  wire        dbg_irqen5_at_ack,
    output wire        rsp_valid,        // LEVEL to xt_sio_drive
    output wire        rsp_ok,
    output wire [8:0]  rsp_len,
    output wire [7:0]  own_dev,

    // ---- clk_sys: the A9 -----------------------------------------------
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] sio_req_word,     // SIO_REQ   {aux2,aux1,cmd,dev}
    output wire [31:0] sio_dstat_word,   // SIO_DSTAT {.., busy, req_pending}
    input  wire [31:0] sio_rsp_word,     // SIO_RSP   {len[24:16], ok[0]}
    input  wire        sio_rsp_we,
    input  wire [7:0]  sio_own,
    output wire        sio_req_irq       // level: a frame is waiting
);

    // ---- clk_sally -> clk_sys: the request ------------------------------
    logic        req_tgl;
    logic [31:0] req_word_q;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) begin
            req_tgl <= 1'b0; req_word_q <= 32'd0;
        end else if (req_valid) begin
            req_word_q <= {req_aux2, req_aux1, req_cmd, req_dev};
            req_tgl    <= ~req_tgl;      // data written the SAME cycle, then held
        end
    end

    (* ASYNC_REG = "TRUE" *) logic req_s1, req_s2;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) {req_s2, req_s1} <= 2'b00;
        else     {req_s2, req_s1} <= {req_s1, req_tgl};
    end

    // busy is a slow level; a 2-FF sync is all it needs.
    (* ASYNC_REG = "TRUE" *) logic busy_s1, busy_s2;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) {busy_s2, busy_s1} <= 2'b00;
        else     {busy_s2, busy_s1} <= {busy_s1, drv_busy};
    end

    // ---- clk_sys -> clk_sally: the response -----------------------------
    logic        rsp_tgl;
    logic [31:0] rsp_word_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rsp_tgl <= 1'b0; rsp_word_q <= 32'd0;
        end else if (sio_rsp_we) begin
            rsp_word_q <= sio_rsp_word;
            rsp_tgl    <= ~rsp_tgl;
        end
    end

    (* ASYNC_REG = "TRUE" *) logic rsp_s1, rsp_s2;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) {rsp_s2, rsp_s1} <= 2'b00;
        else         {rsp_s2, rsp_s1} <= {rsp_s1, rsp_tgl};
    end

    // "the A9's answer has caught up with my request".  At reset both toggles
    // are 0 so this reads 1, which is harmless: the drive only consults it in
    // S_WORK, i.e. after it has already flipped req_tgl.
    assign rsp_valid = (rsp_s2 == req_tgl);
    assign rsp_ok    = rsp_word_q[0];
    assign rsp_len   = rsp_word_q[24:16];

    // req_pending: the request toggle moved, the response has not caught up.
    // Derived, so no flag is written from two clocks.
    // rsp_tgl is generated HERE in clk_sys, so it needs no sync on this side.
    wire req_pending = (req_s2 != rsp_tgl);

    assign sio_req_word   = req_word_q;              // stable while pending
    // Counters are free-running and only ever READ by the A9 for diagnosis, so
    // they cross without a handshake: a torn byte costs one confusing sample,
    // never correctness.  Called out because everything else here is toggled.
    (* ASYNC_REG = "TRUE" *) logic [23:0] dbg_s1, dbg_s2;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin dbg_s1 <= 24'd0; dbg_s2 <= 24'd0; end
        else     begin dbg_s1 <= {dbg_replies, dbg_accepted, dbg_frames}; dbg_s2 <= dbg_s1; end
    end
    (* ASYNC_REG = "TRUE" *) logic irq5_s1, irq5_s2;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) {irq5_s2, irq5_s1} <= 2'b00;
        else     {irq5_s2, irq5_s1} <= {irq5_s1, dbg_irqen5_at_ack};
    end
    assign sio_dstat_word = {dbg_s2, 5'd0, irq5_s2, busy_s2, req_pending};
    assign sio_req_irq    = req_pending;

    // ---- quasi-static: the ownership table ------------------------------
    (* ASYNC_REG = "TRUE" *) logic [7:0] own_s1, own_s2;
    always_ff @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) begin own_s1 <= 8'h00; own_s2 <= 8'h00; end
        else         begin own_s1 <= sio_own; own_s2 <= own_s1; end
    end
    assign own_dev = own_s2;

endmodule

`endif // XT_SIO_CDC_SV
`default_nettype wire
