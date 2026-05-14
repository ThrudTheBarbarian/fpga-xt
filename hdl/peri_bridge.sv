// peri_bridge.sv — unified FPGA-side wrapper around peri_link
// (M25-3c POT, M25-4 SIO, M25-5 SD eventually). Owns the single
// peri-RP SPI link and arbitrates between subsystems' transaction
// streams.
//
// Subsystems today
// ----------------
//
//   POT (M25-3c):
//     potgo_pulse → CMD=POTGO write
//     STATUS poll → pot_done bit → triggers ALLPOT + POT0..7 read
//                                   chain into pot0..pot7 / allpot
//                                   shadows
//
//   SIO (M25-4):
//     serout_strobe → SIO_OUT byte write
//     STATUS poll → sio_rx bit → triggers SIO_IN + SIO_STAT read
//                                 chain → ser_in_byte_pulse +
//                                 ser_in_byte + ser_framing_err +
//                                 ser_input_overrun + ser_input_busy
//                                 + break_key_pulse
//
// Priority arbitration (highest first):
//   1. SIO byte writes (serout_strobe) — peri-RP's SIO_OUT FIFO is
//      shallow; user software writes one byte at a time but timing
//      slips can desync the SIO bus, so push these immediately.
//   2. POT POTGO writes (potgo_pulse) — kicks the scan; latency
//      tolerable up to a couple of ms, but no point delaying.
//   3. STATUS polls (poll_tick OR peri_irq_pulse short-circuit).
//   4. The post-status read chain (ALLPOT/POT0..7 or SIO_IN/SIO_STAT
//      depending on which flag fired) runs to completion uninterrupted.
//
// fast_scan (SKCTL[2]) is forwarded to peri-RP via the POT CMD byte —
// the firmware uses it to choose between 15 kHz slow scan and 1.79 MHz
// machine-clock fast scan.

`default_nettype none

module peri_bridge #(
    // Cycles between successive STATUS polls. Default 5346 ≈ 30 kHz at
    // 162 MHz clk_bus. POT scans take ~15 ms; SIO at 19.2 kbaud has
    // ~520 µs/byte so 30 kHz polling is plenty; modern fast SIO at
    // 1 Mbaud has ~10 µs/byte and would benefit from IRQ-driven
    // short-circuit (already wired via peri_irq_pulse below).
    parameter int unsigned POLL_DIV = 5346,

    // peri_link parameters — propagate down.
    parameter int unsigned LINK_CLK_DIV  = 16,
    parameter int unsigned LINK_HALF_GAP = 32,
    parameter int unsigned LINK_TAIL_GAP = 32
) (
    input  wire        clk,
    input  wire        rst,

    // ---- POT (M23-5 pokey_pot) ------------------------------------
    input  wire        potgo_pulse,           // 1-cycle: kick a scan
    input  wire        fast_scan,             // SKCTL[2] — 1.79 MHz mode

    output logic [7:0] pot0, pot1, pot2, pot3,
    output logic [7:0] pot4, pot5, pot6, pot7,
    output logic [7:0] allpot,                // bit i = 1 while scanning

    // ---- SIO (M23-6 / M25-4) --------------------------------------
    // POKEY → bridge: byte to transmit on SIO bus.
    input  wire [7:0]  serout_byte,
    input  wire        serout_strobe,         // 1-cycle: latch + send
    // bridge → POKEY: byte received from SIO bus + status flags.
    output logic [7:0] ser_in_byte,
    output logic       ser_in_byte_pulse,     // 1-cycle on each new byte
    output logic       ser_framing_err,
    output logic       ser_input_overrun,
    output logic       ser_input_busy,
    output logic       break_key_pulse,
    // bridge → POKEY: TX-side flow control.
    output logic       ser_out_ready_pulse,   // 1-cycle: SIO_OUT ack
    output logic       ser_out_complete,      // level: TX FIFO drained

    // ---- SPI pads (passes through peri_link) -----------------------
    output wire        spi_clk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    input  wire        spi_irq
);

    // ---- peri-RP register addresses (must match peri_regs.h) -------
    // Reads:
    localparam logic [6:0] R_STATUS   = 7'h03;
    localparam logic [6:0] R_ALLPOT   = 7'h04;
    localparam logic [6:0] R_POT0     = 7'h05;
    localparam logic [6:0] R_POT7     = 7'h0C;
    localparam logic [6:0] R_SIO_IN   = 7'h0D;
    localparam logic [6:0] R_SIO_STAT = 7'h0E;
    // Writes:
    localparam logic [6:0] W_CMD      = 7'h05;
    localparam logic [6:0] W_SIO_OUT  = 7'h06;

    // Command-byte values written to W_CMD:
    localparam logic [7:0] CMD_POTGO_SLOW = 8'h01;
    localparam logic [7:0] CMD_POTGO_FAST = 8'h11;   // bit 4 = fast_scan

    // STATUS bit positions (must match peri_regs.h's PERI_STATUS_*).
    localparam int STATUS_POT_DONE_BIT = 0;
    localparam int STATUS_SIO_RX_BIT   = 1;

    // SIO_STAT bit layout (peri-RP firmware fills in these flags
    // when sio_rx is also set):
    //   bit 0 = ser_framing_err
    //   bit 1 = ser_input_overrun
    //   bit 2 = ser_input_busy
    //   bit 3 = break_key (1-cycle pulse-equivalent on poll edge)
    localparam int SIO_STAT_FRAMING_BIT = 0;
    localparam int SIO_STAT_OVERRUN_BIT = 1;
    localparam int SIO_STAT_BUSY_BIT    = 2;
    localparam int SIO_STAT_BREAK_BIT   = 3;

    // ---- peri_link instance ----------------------------------------
    logic        xfer_start;
    logic [6:0]  xfer_addr;
    logic        xfer_we;
    logic [7:0]  xfer_wdata;
    wire  [7:0]  xfer_rdata;
    wire         xfer_done;
    wire         xfer_busy;
    wire         peri_irq_pulse;       // M25-3d: short-circuit poll-tick

    peri_link #(
        .CLK_DIV  (LINK_CLK_DIV),
        .HALF_GAP (LINK_HALF_GAP),
        .TAIL_GAP (LINK_TAIL_GAP)
    ) u_link (
        .clk            (clk),
        .rst            (rst),
        .xfer_start     (xfer_start),
        .xfer_addr      (xfer_addr),
        .xfer_we        (xfer_we),
        .xfer_wdata     (xfer_wdata),
        .xfer_rdata     (xfer_rdata),
        .xfer_done      (xfer_done),
        .xfer_busy      (xfer_busy),
        .spi_irq        (spi_irq),
        .peri_irq_pulse (peri_irq_pulse),
        .spi_clk        (spi_clk),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .spi_cs_n       (spi_cs_n)
    );

    // ---- Pending-write tracking ------------------------------------
    // potgo_pulse / serout_strobe can fire while another transaction
    // is in flight; latch the kick so we issue the write as soon as
    // the link is free. SIO has higher priority than POT — see header.
    logic       potgo_pending_q;
    logic       fast_pending_q;
    logic       sio_out_pending_q;
    logic [7:0] sio_out_byte_q;

    // ---- Poll tick -------------------------------------------------
    localparam int unsigned POLL_W = $clog2(POLL_DIV + 1);
    logic [POLL_W-1:0] poll_cnt_q;
    wire poll_tick = (poll_cnt_q == POLL_W'(POLL_DIV - 1));

    // Poll-chain phases. After STATUS arrives the bridge branches
    // into POT or SIO based on which flags fired (or both — POT then
    // SIO if both bits set). POLL_IDLE is also where new STATUS polls
    // get dispatched on tick / IRQ.
    typedef enum logic [3:0] {
        POLL_IDLE       = 4'd0,
        POLL_STATUS     = 4'd1,
        POLL_ALLPOT     = 4'd2,
        POLL_POT0       = 4'd3,
        POLL_POT1       = 4'd4,
        POLL_POT2       = 4'd5,
        POLL_POT3       = 4'd6,
        POLL_POT4       = 4'd7,
        POLL_POT5       = 4'd8,
        POLL_POT6       = 4'd9,
        POLL_POT7       = 4'd10,
        POLL_SIO_IN     = 4'd11,    // sio_rx → read SIO_IN
        POLL_SIO_STAT   = 4'd12,    // ... then SIO_STAT
        POLL_DONE_WAIT  = 4'd13
    } poll_phase_t;
    poll_phase_t poll_q;

    typedef enum logic [3:0] {
        A_NONE      = 4'd0,
        A_W_POTGO   = 4'd1,
        A_W_SIO_OUT = 4'd2,
        A_R_STATUS  = 4'd3,
        A_R_ALLPOT  = 4'd4,
        A_R_POT0    = 4'd5,
        A_R_POT1    = 4'd6,
        A_R_POT2    = 4'd7,
        A_R_POT3    = 4'd8,
        A_R_POT4    = 4'd9,
        A_R_POT5    = 4'd10,
        A_R_POT6    = 4'd11,
        A_R_POT7    = 4'd12,
        A_R_SIO_IN  = 4'd13,
        A_R_SIO_STAT = 4'd14
    } action_t;
    action_t in_flight_q;

    // After reading STATUS we may need to chain BOTH the POT and SIO
    // read sequences if both flags fired in the same poll. Track
    // which still need to run.
    logic pot_chain_pending_q;
    logic sio_chain_pending_q;
    logic [7:0] last_sio_in_q;   // captured raw SIO_IN value

    typedef enum logic [0:0] {
        S_IDLE = 1'b0,
        S_BUSY = 1'b1
    } state_t;
    state_t state_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            potgo_pending_q     <= 1'b0;
            fast_pending_q      <= 1'b0;
            sio_out_pending_q   <= 1'b0;
            sio_out_byte_q      <= 8'h00;
            poll_cnt_q          <= '0;
            poll_q              <= POLL_IDLE;
            in_flight_q         <= A_NONE;
            state_q             <= S_IDLE;
            xfer_start          <= 1'b0;
            xfer_addr           <= 7'h00;
            xfer_we             <= 1'b0;
            xfer_wdata          <= 8'h00;
            pot0 <= 8'h00; pot1 <= 8'h00; pot2 <= 8'h00; pot3 <= 8'h00;
            pot4 <= 8'h00; pot5 <= 8'h00; pot6 <= 8'h00; pot7 <= 8'h00;
            allpot              <= 8'h00;
            ser_in_byte         <= 8'h00;
            ser_in_byte_pulse   <= 1'b0;
            ser_framing_err     <= 1'b0;
            ser_input_overrun   <= 1'b0;
            ser_input_busy      <= 1'b0;
            break_key_pulse     <= 1'b0;
            ser_out_ready_pulse <= 1'b0;
            ser_out_complete    <= 1'b1;
            pot_chain_pending_q <= 1'b0;
            sio_chain_pending_q <= 1'b0;
            last_sio_in_q       <= 8'h00;
        end else begin
            xfer_start          <= 1'b0;
            ser_in_byte_pulse   <= 1'b0;
            break_key_pulse     <= 1'b0;
            ser_out_ready_pulse <= 1'b0;

            // Capture POTGO requests.
            if (potgo_pulse) begin
                potgo_pending_q <= 1'b1;
                fast_pending_q  <= fast_scan;
                allpot          <= 8'hFF;
            end

            // Capture SIO byte-out requests. POKEY's SIO interface
            // gives us a 1-cycle strobe + a stable byte; latch both
            // until we can push to peri-RP. ser_out_complete drops
            // while the byte is queued or in flight.
            if (serout_strobe) begin
                sio_out_pending_q <= 1'b1;
                sio_out_byte_q    <= serout_byte;
                ser_out_complete  <= 1'b0;
            end

            // Free-running poll counter.
            if (poll_cnt_q == POLL_W'(POLL_DIV - 1))
                poll_cnt_q <= '0;
            else
                poll_cnt_q <= poll_cnt_q + 1'b1;

            // poll_tick (or peri_irq_pulse short-circuit) → start
            // polling STATUS if otherwise idle. M25-3d.
            if ((poll_tick || peri_irq_pulse)
                && poll_q == POLL_IDLE
                && !potgo_pending_q && !sio_out_pending_q)
                poll_q <= POLL_STATUS;

            unique case (state_q)
                S_IDLE: if (!xfer_busy) begin
                    // Priority: SIO_OUT > POTGO > poll chain.
                    if (sio_out_pending_q) begin
                        xfer_start        <= 1'b1;
                        xfer_we           <= 1'b1;
                        xfer_addr         <= W_SIO_OUT;
                        xfer_wdata        <= sio_out_byte_q;
                        sio_out_pending_q <= 1'b0;
                        in_flight_q       <= A_W_SIO_OUT;
                        state_q           <= S_BUSY;
                    end else if (potgo_pending_q) begin
                        xfer_start      <= 1'b1;
                        xfer_we         <= 1'b1;
                        xfer_addr       <= W_CMD;
                        xfer_wdata      <= fast_pending_q ? CMD_POTGO_FAST
                                                          : CMD_POTGO_SLOW;
                        potgo_pending_q <= 1'b0;
                        in_flight_q     <= A_W_POTGO;
                        state_q         <= S_BUSY;
                        poll_q          <= POLL_STATUS;
                    end else if (poll_q == POLL_STATUS) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_STATUS;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_STATUS;
                        state_q     <= S_BUSY;
                    end else if (poll_q == POLL_ALLPOT) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_ALLPOT;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_ALLPOT;
                        state_q     <= S_BUSY;
                    end else if (poll_q >= POLL_POT0 && poll_q <= POLL_POT7) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_POT0 + 7'(poll_q - POLL_POT0);
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= action_t'(A_R_POT0 + 4'(poll_q - POLL_POT0));
                        state_q     <= S_BUSY;
                    end else if (poll_q == POLL_SIO_IN) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_SIO_IN;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_SIO_IN;
                        state_q     <= S_BUSY;
                    end else if (poll_q == POLL_SIO_STAT) begin
                        xfer_start  <= 1'b1;
                        xfer_we     <= 1'b0;
                        xfer_addr   <= R_SIO_STAT;
                        xfer_wdata  <= 8'h00;
                        in_flight_q <= A_R_SIO_STAT;
                        state_q     <= S_BUSY;
                    end
                end

                S_BUSY: if (xfer_done) begin
                    unique case (in_flight_q)
                        A_W_POTGO:    ;
                        A_W_SIO_OUT: begin
                            // Byte handed off to peri-RP — pulse ack
                            // to POKEY and drop "complete" until a
                            // future strobe.
                            ser_out_ready_pulse <= 1'b1;
                            ser_out_complete    <= 1'b1;
                        end
                        A_R_STATUS: begin
                            // Both flags can fire in one poll. Decode
                            // both; chain whichever (or both) need
                            // their follow-up reads. POT runs first,
                            // then SIO.
                            pot_chain_pending_q <= xfer_rdata[STATUS_POT_DONE_BIT];
                            sio_chain_pending_q <= xfer_rdata[STATUS_SIO_RX_BIT];
                            if (xfer_rdata[STATUS_POT_DONE_BIT]) begin
                                poll_q <= POLL_ALLPOT;
                            end else if (xfer_rdata[STATUS_SIO_RX_BIT]) begin
                                poll_q <= POLL_SIO_IN;
                            end else begin
                                poll_q <= POLL_IDLE;
                            end
                        end
                        A_R_ALLPOT: begin allpot <= xfer_rdata; poll_q <= POLL_POT0; end
                        A_R_POT0: begin pot0 <= xfer_rdata; poll_q <= POLL_POT1; end
                        A_R_POT1: begin pot1 <= xfer_rdata; poll_q <= POLL_POT2; end
                        A_R_POT2: begin pot2 <= xfer_rdata; poll_q <= POLL_POT3; end
                        A_R_POT3: begin pot3 <= xfer_rdata; poll_q <= POLL_POT4; end
                        A_R_POT4: begin pot4 <= xfer_rdata; poll_q <= POLL_POT5; end
                        A_R_POT5: begin pot5 <= xfer_rdata; poll_q <= POLL_POT6; end
                        A_R_POT6: begin pot6 <= xfer_rdata; poll_q <= POLL_POT7; end
                        A_R_POT7: begin
                            pot7                <= xfer_rdata;
                            pot_chain_pending_q <= 1'b0;
                            // Chain into SIO if it also had work.
                            if (sio_chain_pending_q) begin
                                poll_q <= POLL_SIO_IN;
                            end else begin
                                poll_q <= POLL_DONE_WAIT;
                            end
                        end
                        A_R_SIO_IN: begin
                            last_sio_in_q <= xfer_rdata;
                            poll_q        <= POLL_SIO_STAT;
                        end
                        A_R_SIO_STAT: begin
                            // Surface the captured byte + status to
                            // POKEY. ser_in_byte_pulse is a one-cycle
                            // pulse (default 0 above); ser_*_err / etc
                            // latch level-sensitively.
                            ser_in_byte         <= last_sio_in_q;
                            ser_in_byte_pulse   <= 1'b1;
                            ser_framing_err     <= xfer_rdata[SIO_STAT_FRAMING_BIT];
                            ser_input_overrun   <= xfer_rdata[SIO_STAT_OVERRUN_BIT];
                            ser_input_busy      <= xfer_rdata[SIO_STAT_BUSY_BIT];
                            break_key_pulse     <= xfer_rdata[SIO_STAT_BREAK_BIT];
                            sio_chain_pending_q <= 1'b0;
                            poll_q              <= POLL_DONE_WAIT;
                        end
                        default: ;
                    endcase
                    in_flight_q <= A_NONE;
                    state_q     <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase

            if (poll_q == POLL_DONE_WAIT && state_q == S_IDLE)
                poll_q <= POLL_IDLE;
        end
    end

endmodule

`default_nettype wire
