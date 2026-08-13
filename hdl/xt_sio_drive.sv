`default_nettype none
//
// xt_sio_drive — a disk drive answering on the SIO serial bus.
//
// WHY THIS EXISTS
// ---------------
// Disk images are served today by patching SIOV (xl_boot.c + tools/xl_sio_stub.s):
// the OS's SIO entry point is redirected and the A9 hands back a sector.  That
// covers every title that loads through the OS, and cannot cover a FAST LOADER,
// which is most protected disks.  BallBlazer is the worked example: it boots 17
// sectors through the OS, then programs POKEY ch3/4 as its own bit-rate
// generator, asserts /COMMAND through PIA PBCTL, clocks a command frame out of
// SEROUT and waits on its own serial IRQ.  It never calls SIOV again, so the
// stub never sees it.  The answer is a device that answers ON THE BUS, which is
// this module.  Full design: docs/OS/sio-bridge.md §13.
//
// BYTE LEVEL, NOT BIT LEVEL
// -------------------------
// We own both ends, so there is no bit-level receiver here (sio-bridge.md §2,
// §13.9).  The guest's command frame arrives as BYTES (serout_strobe/serout_byte
// — POKEY's own shifter has already deserialized it) and replies are injected as
// BYTES (ser_in_byte + ser_in_byte_pulse, which pokey_regs latches into SERIN
// and turns into IRQST bit 5).  What we must get right is the CADENCE: a reply
// arriving instantly is as much a tell as one with the wrong bytes.
//
// So every reply byte is spaced by one frame time, counted in POKEY's OWN shift
// ticks (`shift_tick`, 20 per frame — two per bit, ten bits).  That means the
// drive automatically runs at whatever rate the guest programmed, including the
// high-speed rates a US-Doubler negotiates: we never hardcode a baud rate.
//
// THE PROTOCOL WE SPEAK
// ---------------------
//   1. host pulls /COMMAND low
//   2. host sends 5 bytes: device, command, aux1, aux2, checksum
//   3. host releases /COMMAND
//   4. drive answers ACK ($41) — or stays SILENT if the frame is not ours
//   5. drive does the work
//   6. drive answers COMPLETE ($43) or ERROR ($45)
//   7. for a read: N data bytes, then their checksum
//
// Checksum is an 8-bit sum with END-AROUND CARRY (the carry folds back into
// bit 0), which is not a plain truncating sum — get that wrong and every frame
// is rejected.
//
// SILENCE IS A VALID ANSWER, and it is what makes coexistence work.  If the
// frame addresses a device we do not own — because a REAL peripheral is plugged
// into the DIN port and claimed that ID (the ownership table, §13.3) — we say
// nothing at all and let the real device answer.  Two devices answering one ID
// is a bus collision, so `own_dev` must be settled before the first ACK window,
// never discovered afterwards.
//
`ifndef XT_SIO_DRIVE_SV
`define XT_SIO_DRIVE_SV

module xt_sio_drive #(
    // Frame times to wait before ACK.  A real drive takes ~800 us to answer;
    // the exact figure is not load-bearing (no loader measures the ACK gap that
    // tightly) but it must not be ZERO, or a guest that arms its receive IRQ
    // after releasing /COMMAND misses the byte entirely.
    parameter int unsigned ACK_FRAMES = 3,
    // ACK turnaround, in clk_sally cycles -- ABSOLUTE TIME, not frame times.
    // A real drive takes ~1 ms to answer because that is how long its
    // controller needs; the figure does NOT shrink when the host picks a faster
    // bit rate.  Pacing it in frame times (as ACK_FRAMES did) made the
    // turnaround collapse for a fast loader, and we answered before the guest
    // had re-enabled its receive IRQ -- so IRQST bit 5 never latched and the
    // reply vanished.  Measured on HW: a complete 131-byte reply sent with
    // irqen5_at_ack = 0 (2026-08-13).  100_000 cycles = 1 ms at 100 MHz.
    parameter int unsigned ACK_DELAY_CLK = 100_000
) (
    input  wire        clk,              // clk_sally — the 6502's own domain
    input  wire        rst,

    // ---- guest side ------------------------------------------------------
    input  wire        cmd_n,            // /COMMAND (PIA CB2), ACTIVE LOW
    input  wire [7:0]  serout_byte,      // guest wrote $D20D ...
    input  wire        serout_strobe,    // ... 1-clk strobe
    input  wire        shift_tick,       // POKEY's own shift clock, 20 per frame
    input  wire [7:0]  guest_irqen,      // POKEY IRQEN, to see if the guest is listening

    output logic [7:0] ser_in_byte,      // -> pokey_regs SERIN
    output logic       ser_in_byte_pulse,

    // ---- which device IDs are ours (the ownership table, §13.3) ----------
    // Bit i = device $31+i is VIRTUAL and we answer for it.  0 = not ours:
    // stay silent so a real peripheral, or nothing, can answer.
    input  wire [7:0]  own_dev,

    // ---- service side (the A9 does the actual disk work) -----------------
    output logic       req_valid,        // 1-clk: a validated frame for US
    output logic [7:0] req_dev,
    output logic [7:0] req_cmd,
    output logic [7:0] req_aux1,
    output logic [7:0] req_aux2,

    input  wire        rsp_valid,        // LEVEL: response is ready
    input  wire        rsp_ok,           // 1 = COMPLETE ($43), 0 = ERROR ($45)
    input  wire [8:0]  rsp_len,          // payload bytes, 0..256
    output logic [8:0] rsp_idx,          // which payload byte we want
    input  wire [7:0]  rsp_byte,         // ... and it, combinationally

    output logic       busy,             // a transaction is in flight
    // Asserted ONLY while the payload is actually being walked.  The mailbox's
    // port A is shared with the 6502's $D5CD/$D5CE register port, and holding
    // that for a whole transaction starves the SIOV stub -- which matters
    // because both front ends stay live (§13.7).  Narrow is safer.
    output logic       reading,
    // ---- instrumentation ------------------------------------------------
    // Deducing why no frame arrives is guesswork without these.  Cheap, and
    // they answer the only three questions that matter: is /COMMAND framing at
    // all, are the frame bytes arriving, and are we REJECTING them (wrong
    // device / bad checksum) rather than never seeing them.
    output logic [7:0] dbg_frames,      // /COMMAND assertions seen
    output logic [7:0] dbg_bytes,       // SEROUT bytes captured in S_CMD
    output logic [7:0] dbg_accepted,    // frames that passed device+checksum
    output logic [7:0] dbg_replies,     // reply bytes actually injected
    // Sampled at the instant the ACK is injected.  IRQST bit 5 only latches
    // while IRQEN[5] is set, so a reply sent before the guest re-arms its
    // receive interrupt is swallowed without trace -- and BallBlazer toggles
    // $D20E at six sites, so this is not hypothetical.
    output logic       dbg_irqen5_at_ack
);

    // ---- end-around-carry checksum ---------------------------------------
    // sum = sum + b; if it carried, sum = sum + 1.  Used for both the frame we
    // receive and the data frame we send.
    function automatic [7:0] csum_add(input [7:0] acc, input [7:0] b);
        logic [8:0] t;
        begin
            t = {1'b0, acc} + {1'b0, b};
            csum_add = t[7:0] + {7'b0, t[8]};
        end
    endfunction

    // ---- /COMMAND edge detect --------------------------------------------
    logic cmd_n_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) cmd_n_q <= 1'b1; else cmd_n_q <= cmd_n;
    wire cmd_assert = cmd_n_q & ~cmd_n;      // falling: frame starts
    wire cmd_release = ~cmd_n_q & cmd_n;     // rising:  frame ends

    // ---- frame time, in POKEY's own shift ticks --------------------------
    // The counter is driven ONLY from the FSM block below -- a second always_ff
    // decrementing it would be a multiple-driver conflict.  Ordering inside the
    // one block is what makes it work: the decrement runs first, and a pace()
    // later in the same evaluation overwrites it (last assignment wins), so
    // loading a new interval on the tick that retires the old one is safe.
    // PACING MUST NOT DEPEND ON A CLOCK THE GUEST MAY HAVE STOPPED.
    // Tracking shift_tick keeps us at the guest's rate while it is running,
    // which is what we want -- but a guest reprograms its POKEY timers between
    // transmitting the command and receiving the reply, so the tick can simply
    // STOP.  The first cut stalled forever there: hardware showed 12 frames
    // accepted and exactly 12 reply bytes, one ACK each and nothing after
    // (2026-08-13).  A real drive has its OWN baud generator and does not care
    // what the host's divisor is doing, so fall back to an absolute period.
    localparam int unsigned TICKS_PER_FRAME = 20;
    localparam int unsigned FALLBACK_CLK    = 52_000;   // ~520 us at 100 MHz
    logic [9:0]  tick_cnt;
    logic [16:0] fallback_cnt;
    logic        pace_run;
    wire         pace_done = pace_run &&
                             ((tick_cnt == 10'd0) || (fallback_cnt == 17'd0));

    // ---- the state machine ------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_CMD, S_CHECK, S_ACKWAIT, S_ACK,
        S_WORK, S_COMPWAIT, S_COMP, S_DATA, S_DCSUM
    } state_e;
    state_e st;

    logic [7:0] frame [0:4];
    logic [2:0] fidx;
    // A guest that asserts /COMMAND and never releases it -- or a decode of the
    // PIA that is wrong -- must not leave the drive BUSY for ever.  Seen on HW
    // (2026-08-13): busy stuck, req_pending clear, and because port A followed
    // busy it starved the SIOV stub too.  Bound the command phase.
    // WIDTH MATTERS.  A command frame is not quick: the host asserts /COMMAND,
    // waits ~750 us, then clocks 5 bytes at ~520 us each at 19200 baud -- about
    // 4 ms end to end, and slower still if a guest picks a lower rate.  The
    // first cut used 16 bits = 655 us at 100 MHz clk_sally, so the drive gave up
    // BEFORE the first byte was even written: hardware showed 95 frames seen and
    // ZERO bytes captured (2026-08-13).  24 bits is 167 ms -- comfortably longer
    // than any frame, still short enough to recover from a wedged guest.
    logic [23:0] cmd_wd;
    logic [19:0] ack_wait, ack_hold;
    logic [7:0] dcsum;                 // checksum of the data frame we send

    wire [7:0] dev_in  = frame[0];
    wire       dev_ok  = (dev_in >= 8'h31) && (dev_in <= 8'h38)
                      && own_dev[dev_in[2:0] - 3'd1];
    wire [7:0] fcsum   = csum_add(csum_add(csum_add(csum_add(8'h00,
                             frame[0]), frame[1]), frame[2]), frame[3]);
    wire       csum_ok = (fcsum == frame[4]);

    task automatic pace(input int unsigned frames);
        tick_cnt     <= 10'(frames * TICKS_PER_FRAME);
        fallback_cnt <= 17'(FALLBACK_CLK);
        pace_run     <= 1'b1;
    endtask

    task automatic emit(input [7:0] b);
        ser_in_byte       <= b;
        ser_in_byte_pulse <= 1'b1;
        dbg_replies       <= dbg_replies + 8'd1;
    endtask

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= S_IDLE; fidx <= 3'd0; req_valid <= 1'b0; reading <= 1'b0;
            dbg_frames <= 8'd0; dbg_bytes <= 8'd0; dbg_accepted <= 8'd0;
            dbg_replies <= 8'd0; dbg_irqen5_at_ack <= 1'b0;
            ack_wait <= 20'd0; ack_hold <= 20'd0;
            ser_in_byte <= 8'h00; ser_in_byte_pulse <= 1'b0;
            rsp_idx <= 9'd0; dcsum <= 8'h00; busy <= 1'b0;
            tick_cnt <= 10'd0; pace_run <= 1'b0;
        end else begin
            ser_in_byte_pulse <= 1'b0;      // 1-clk pulse
            req_valid         <= 1'b0;
            if (pace_run && shift_tick && tick_cnt != 10'd0)
                tick_cnt <= tick_cnt - 10'd1;
            if (pace_run && fallback_cnt != 17'd0)
                fallback_cnt <= fallback_cnt - 17'd1;

            // /COMMAND asserting ALWAYS restarts framing, whatever we were
            // doing.  A guest that gives up mid-transaction and re-commands
            // must not find us still replying to the previous frame.
            if (cmd_assert) begin
                st <= S_CMD; fidx <= 3'd0; busy <= 1'b1; pace_run <= 1'b0;
                cmd_wd <= 24'd0; dbg_frames <= dbg_frames + 8'd1;
                ack_hold <= 20'd0;
            end else case (st)

            S_IDLE: begin busy <= 1'b0; reading <= 1'b0; end

            S_CMD: begin
                cmd_wd <= cmd_wd + 24'd1;
                if (cmd_wd == 24'hFFFFFF) st <= S_IDLE;  // give up, stay silent
                if (serout_strobe && fidx < 3'd5) begin
                    frame[fidx] <= serout_byte;
                    fidx        <= fidx + 3'd1;
                    dbg_bytes   <= dbg_bytes + 8'd1;
                end
                if (cmd_release) st <= S_CHECK;
            end

            S_CHECK: begin
                // Not ours, short frame, or a bad checksum -> SILENCE.  A real
                // drive that is not addressed does not NAK, it says nothing,
                // and something else on the bus may be about to answer.
                if (fidx == 3'd5 && dev_ok && csum_ok) begin
                    req_dev <= frame[0]; req_cmd  <= frame[1];
                    req_aux1 <= frame[2]; req_aux2 <= frame[3];
                    req_valid    <= 1'b1;
                    dbg_accepted <= dbg_accepted + 8'd1;
                    ack_wait     <= ACK_DELAY_CLK[19:0];
                    st <= S_ACKWAIT;
                end else begin
                    st <= S_IDLE;
                end
            end

            // Hold off until BOTH the fixed turnaround has elapsed AND the
            // guest has actually armed its receive interrupt.  The second
            // condition is belt-and-braces -- a real drive cannot see IRQEN --
            // but it costs nothing and makes the reply impossible to lose to a
            // guest that is slower than our timer.  Bounded so a guest that
            // never arms cannot wedge us.
            S_ACKWAIT: begin
                if (ack_wait != 20'd0) ack_wait <= ack_wait - 20'd1;
                else if (guest_irqen[5] || ack_hold == 20'hFFFFF) st <= S_ACK;
                else ack_hold <= ack_hold + 20'd1;
            end
            S_ACK:     begin emit(8'h41); pace(1); st <= S_WORK;        // 'A'
                             dbg_irqen5_at_ack <= guest_irqen[5]; end

            // The A9 is doing the disk work.  Its latency IS the rotational
            // latency as far as the guest can tell, which is the point: a
            // reply that arrives too fast is a tell (§13.5).
            S_WORK: if (rsp_valid && pace_done) begin
                        pace_run <= 1'b0; pace(1); st <= S_COMPWAIT;
                    end

            S_COMPWAIT: if (pace_done) begin pace_run <= 1'b0; st <= S_COMP; end

            S_COMP: begin
                emit(rsp_ok ? 8'h43 : 8'h45);            // 'C' / 'E'
                dcsum   <= 8'h00;
                rsp_idx <= 9'd0;
                pace(1);
                if (rsp_ok && rsp_len != 9'd0) begin st <= S_DATA; reading <= 1'b1; end
                else                                 st <= S_IDLE;
            end

            S_DATA: if (pace_done) begin
                emit(rsp_byte);
                dcsum   <= csum_add(dcsum, rsp_byte);
                pace(1);
                if (rsp_idx + 9'd1 == rsp_len) st <= S_DCSUM;
                else                           rsp_idx <= rsp_idx + 9'd1;
            end

            S_DCSUM: if (pace_done) begin
                emit(dcsum);
                pace_run <= 1'b0;
                st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`endif // XT_SIO_DRIVE_SV
`default_nettype wire
