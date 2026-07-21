// dma_arbiter.sv — fold two mem_read_mux DMA-side ports onto the
// single dma_master.
//
// dl_parser and compositor each have their own mem_read_mux instance
// (so the snoop-mode read path stays parallel via cpu_shadow's
// dual-port BRAM), but share one dma_master because the FPGA only
// has one set of A/D pins to drive. The arbiter resolves contention
// with simple priority — port 0 (dl_parser) wins over port 1
// (compositor) on simultaneous req. dl_parser finishes its DL walk
// before compositor's row walk normally starts, so contention is
// rare in practice.
//
// Once a port wins, the arbiter holds the grant until that port's
// dma_data_valid lands; the other port's mem_read_mux just keeps
// stalling in BUSY until its grant comes around.

`default_nettype none

module dma_arbiter (
    input  wire        clk,
    input  wire        rst,

    // Port 0 (dl_parser).
    input  wire        p0_req,
    input  wire [15:0] p0_addr,
    output wire        p0_ack,
    output wire        p0_data_valid,
    output wire  [7:0] p0_rdata,

    // Port 1 (compositor).
    input  wire        p1_req,
    input  wire [15:0] p1_addr,
    output wire        p1_ack,
    output wire        p1_data_valid,
    output wire  [7:0] p1_rdata,

    // Combined dma_master interface.
    output logic       dma_req,
    output logic [15:0] dma_addr,
    input  wire        dma_ack,
    input  wire        dma_data_valid,
    input  wire  [7:0] dma_rdata,
    input  wire        dma_busy
);

    // Active grantee selected by FSM. While IDLE we route either
    // port's req → dma_master (priority: p0). We only commit to A_BUSY
    // once dma_master ACCEPTS the request (dma_ack) — NOT merely on
    // seeing a req.  The old code went A_BUSY the cycle it saw a req and
    // assumed dma_master had taken it; if dma_master was not yet in its
    // IDLE state (e.g. finishing the previous fetch's release cycle) it
    // ignored that req, and — because the port's dma_req was a one-cycle
    // pulse — the request was lost forever and the arbiter deadlocked
    // waiting for a data_valid that never arrived.  The mem_read_mux
    // ports now HOLD their req until acked, and this FSM waits for the
    // ack, so no request can be dropped and a losing port is simply
    // granted on the next round.
    typedef enum logic {A_IDLE = 1'b0, A_BUSY = 1'b1} arb_state_t;
    arb_state_t arb_state;
    logic       grant;          // 0 = port 0, 1 = port 1

    // Priority pick among the (level-held) requests.
    wire        want_p0    = p0_req;
    wire        want_p1    = !p0_req && p1_req;
    wire        any_req    = p0_req || p1_req;
    wire        grant_sel  = want_p1;    // 0 = p0, 1 = p1

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            arb_state <= A_IDLE;
            grant     <= 1'b0;
        end else begin
            case (arb_state)
                A_IDLE: begin
                    // Track the current winner while we drive the request and
                    // wait for dma_master to accept it.  We must FREEZE the
                    // grant at the value from the cycle we DROVE the accepted
                    // request (dma_master latches its address on the same edge
                    // it raises ack, one cycle later), so on the ack cycle we
                    // do NOT re-sample grant_sel — we commit the value tracked
                    // on the prior (drive) cycle.  Otherwise the grant could
                    // route the fetched byte to the wrong port if the winner
                    // changed between drive and ack.
                    if (dma_ack) begin
                        arb_state <= A_BUSY;
                    end else if (any_req) begin
                        grant <= grant_sel;
                    end
                end
                A_BUSY: begin
                    if (dma_data_valid) arb_state <= A_IDLE;
                end
                default: arb_state <= A_IDLE;
            endcase
        end
    end

    // Drive dma_master from whichever port wins.  While IDLE we route the
    // winner's req + address combinationally and HOLD it (the port keeps
    // req asserted) until dma_master acks.  Once BUSY, dma_master has
    // latched the address, so we drop req.
    always_comb begin
        if (arb_state == A_IDLE && any_req) begin
            dma_req  = 1'b1;
            dma_addr = want_p0 ? p0_addr : p1_addr;
        end else begin
            dma_req  = 1'b0;
            dma_addr = 16'h0;
        end
    end

    // ack to the granted port; data_valid + rdata likewise routed.  The ack
    // must reflect the COMMITTED winner (`grant`, frozen from the drive cycle),
    // NOT the live want_* — on the ack cycle the requester that lost priority
    // may momentarily satisfy want_*, and acking it would falsely tell that
    // port its (never-issued) fetch was accepted, deadlocking it.  `grant`
    // holds grant_sel captured on the drive cycle, matching the address
    // dma_master latched.
    assign p0_ack         = (arb_state == A_IDLE) && dma_ack && (grant == 1'b0);
    assign p1_ack         = (arb_state == A_IDLE) && dma_ack && (grant == 1'b1);
    assign p0_data_valid  = (arb_state == A_BUSY) && (grant == 1'b0) && dma_data_valid;
    assign p1_data_valid  = (arb_state == A_BUSY) && (grant == 1'b1) && dma_data_valid;
    assign p0_rdata       = dma_rdata;
    assign p1_rdata       = dma_rdata;

endmodule

`default_nettype wire
