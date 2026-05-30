// hwreg_rd_cdc.sv — register-READ bridge across the SALLY <-> ANTIC CDC.
//
// Boot-to-BASIC blocker #3.  The SALLY->ANTIC register
// bus is write-only (a fire-and-forget async FIFO in fpga_xt_top); reads of
// $D0xx/$D2xx/$D3xx/$D4xx returned a hardcoded stub.  The OS reads these
// hardware registers constantly (CONSOL, IRQST, KBCODE, PORTA, VCOUNT, ...),
// so it needs the real values.
//
// The register state lives in clk_sys (inside antic_top) and antic_top's
// read mux (bus_data_out) is combinational on bus_addr.  This module gives
// SALLY a coherent read by:
//   1. capturing the read address on clk_sally and stalling SALLY (rd_busy),
//   2. handing the address to clk_sys, where the caller drives it onto
//      antic_top's bus (with bus_rw=read) and the combinational read mux
//      produces the data,
//   3. sampling that data and returning it across the CDC,
//   4. releasing the stall and presenting the byte.
//
// CDC method: a toggle handshake.  req_tog flips per request and crosses to
// clk_sys; ack_tog follows and crosses back.  The address and the response
// byte are plain registers that are STABLE for the whole transfer, so they
// are carried with simple 2-FF synchronisers (cdc_sync_bit) and only sampled
// in the window after the handshake flag has crossed — the standard
// "synchronise the flag, the data bus is already stable" pattern.
//
// Latency is a few clk_sys + clk_sally cycles.  At CLOCK_MULT=68 that is far
// inside one emulated 6502 cycle, so the stall is invisible to software.
//
// Contract / assumptions:
//   * rd_addr is stable while rd_req is asserted (SALLY presents one bus
//     access at a time; an instruction/operand fetch — a non-hwreg address —
//     always intervenes between two register reads, so rd_req pulses cleanly
//     per read).  The FSM issues exactly once per rd_req episode.
//   * The reads served here are side-effect free at the register level
//     (status/port/counter reads), so presenting the address to the read mux
//     does not disturb chip state.

`default_nettype none

module hwreg_rd_cdc (
    // ---- Request side (clk_sally) ---------------------------------------
    input  wire        clk_sally,
    input  wire        rst_sally,
    input  wire        rd_req,        // level: SALLY presenting an ANTIC-served hwreg read
    input  wire [15:0] rd_addr,       // read address (stable while rd_req)
    output wire        rd_busy,       // 1 = stall SALLY (response not yet valid)
    output reg  [7:0]  rd_data,       // captured register byte (valid when rd_busy=0)

    // ---- Responder side (clk_sys) ---------------------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        bus_idle,      // 1 = write path quiescent; gate read start to avoid bus contention
    output reg  [15:0] bus_addr,      // drive onto antic_top bus_addr for the read
    output reg         bus_read,      // 1 while presenting the read transaction
    input  wire [7:0]  bus_rdata      // = antic_top bus_data_out (combinational on bus_addr)
);

    // ====================================================================
    // clk_sally request FSM
    // ====================================================================
    reg        req_tog;
    reg        armed;        // request kicked off for the current rd_req episode
    reg        captured;     // response latched for the current episode
    reg [15:0] rd_addr_q;    // read address LATCHED at kick-off.  rd_addr (= live
                             // cpu_addr) moves off the target one cycle after the
                             // read is presented (the core advances to its data-
                             // consume state), BEFORE the 2-FF address synchroniser
                             // settles — so the responder must use the latched
                             // address, not the live one, or it reads the wrong
                             // location (caused the $C30B PORTB read to miss).

    // clk_sys-domain registers — declared here so the clk_sally
    // synchronisers below can reference them; driven in the clk_sys FSM.
    reg        ack_tog;
    reg  [7:0] resp_data;

    wire       ack_tog_s;    // ack toggle, synchronised into clk_sally
    wire [7:0] resp_data_s;  // response byte, synchronised into clk_sally

    cdc_sync_bit #(.WIDTH(1)) u_ack_sync (
        .dst_clk (clk_sally), .src_sig (ack_tog),   .dst_sig (ack_tog_s));
    cdc_sync_bit #(.WIDTH(8)) u_data_sync (
        .dst_clk (clk_sally), .src_sig (resp_data), .dst_sig (resp_data_s));

    always_ff @(posedge clk_sally or posedge rst_sally) begin
        if (rst_sally) begin
            req_tog   <= 1'b0;
            armed     <= 1'b0;
            captured  <= 1'b0;
            rd_data   <= 8'h00;
            rd_addr_q <= 16'h0000;
        end else if (!armed) begin
            // Idle: kick off one transaction when SALLY first presents the read.
            if (rd_req) begin
                req_tog   <= ~req_tog;
                armed     <= 1'b1;
                captured  <= 1'b0;
                rd_addr_q <= rd_addr;   // freeze the target for the whole transfer
            end
        end else if (!captured) begin
            // IN FLIGHT — wait for the responder, IGNORING rd_req.  The xt6502
            // core uses a 1-cycle sync-memory model and only holds the read
            // address (AB) for a single cycle; busy_n is registered one cycle
            // downstream, so the CPU advances off the address (AB -> PC) before
            // the stall engages and rd_req drops almost immediately.  The
            // latched req_tog/armed keep the transaction ALIVE (and rd_busy
            // asserted) regardless, so the read finishes and the now-stalled
            // core consumes the right byte.  (Pre-fix this branch was
            // `!rd_req -> disarm`, which ABORTED every register read: the CDC
            // never delivered, the CPU read stale, and e.g. the XL OS PMI1
            // `LDA PORTB` got $00 instead of $FF -> OS ROM off -> crash.)
            if (ack_tog_s == req_tog) begin
                rd_data  <= resp_data_s;
                captured <= 1'b1;
            end
        end else if (!rd_req) begin
            // Captured AND the core has moved off this read: disarm so the next
            // register read re-issues a fresh transaction.
            armed    <= 1'b0;
            captured <= 1'b0;
        end
    end

    // Busy from the cycle SALLY presents the read until the response is
    // captured — held across the core advancing off the address via `armed`
    // (not just the live rd_req).  rd_req is combinational but busy_n is
    // registered in sally_clock, so this closes no combinational RDY loop.
    assign rd_busy = (rd_req | armed) & ~captured;

    // ====================================================================
    // clk_sys responder FSM
    // ====================================================================
    wire        req_tog_s;
    wire [15:0] req_addr_s;
    cdc_sync_bit #(.WIDTH(1))  u_req_sync (
        .dst_clk (clk_sys), .src_sig (req_tog), .dst_sig (req_tog_s));
    cdc_sync_bit #(.WIDTH(16)) u_addr_sync (
        .dst_clk (clk_sys), .src_sig (rd_addr_q), .dst_sig (req_addr_s));

    localparam [1:0] S_IDLE = 2'd0, S_DRIVE = 2'd1, S_CAP = 2'd2;
    reg [1:0] state;

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            ack_tog   <= 1'b0;
            resp_data <= 8'h00;
            state     <= S_IDLE;
            bus_addr  <= 16'h0000;
            bus_read  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    bus_read <= 1'b0;
                    // Only take the bus when the write path is quiescent
                    // (bus_idle) so a draining register write can't collide
                    // with the read transaction.
                    if ((req_tog_s != ack_tog) && bus_idle) begin
                        // req_addr_s is stable (rd_addr held since before
                        // req_tog flipped, ≥2 clk_sys cycles ago).
                        bus_addr <= req_addr_s;
                        bus_read <= 1'b1;
                        state    <= S_DRIVE;
                    end
                end
                S_DRIVE: begin
                    // Hold bus_addr/bus_read one cycle so antic_top's
                    // combinational read mux settles on the new address.
                    state <= S_CAP;
                end
                S_CAP: begin
                    resp_data <= bus_rdata;     // sample the settled read data
                    ack_tog   <= req_tog_s;     // signal completion to clk_sally
                    bus_read  <= 1'b0;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
