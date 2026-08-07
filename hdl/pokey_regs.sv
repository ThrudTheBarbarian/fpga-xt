// pokey_regs.sv — POKEY register file (M23-6).
//
// Snoops $D2xx writes from bus_snoop (we + waddr[7:0] + wdata) and
// implements the full POKEY register-port semantics through M23-6.
//
// Address layout (low 4 bits of waddr — POKEY mirrors every 16 bytes
// within $D200-$D2FF):
//
//   write side:                        read side:
//     $D200 AUDF1                        $D200 POT0
//     $D201 AUDC1                        $D201 POT1
//     $D202 AUDF2                        $D202 POT2
//     $D203 AUDC2                        $D203 POT3
//     $D204 AUDF3                        $D204 POT4
//     $D205 AUDC3                        $D205 POT5
//     $D206 AUDF4                        $D206 POT6
//     $D207 AUDC4                        $D207 POT7
//     $D208 AUDCTL                       $D208 ALLPOT
//     $D209 STIMER (strobe)              $D209 KBCODE
//     $D20A SKRES  (strobe — clears      $D20A RANDOM
//                  serial IRQ flags)
//     $D20B POTGO  (strobe)              $D20B (reserved)
//     $D20C (reserved)                   $D20C (reserved)
//     $D20D SEROUT                       $D20D SERIN
//     $D20E IRQEN                        $D20E IRQST
//     $D20F SKCTL                        $D20F SKSTAT
//
// IRQEN / IRQST mask layout (per Altirra Hardware Reference Manual §5.7):
//     bit 0  TIMER 1  (channel 1 wrap)                      latched
//     bit 1  TIMER 2  (channel 2 wrap)                      latched
//     bit 2  TIMER 4  (channel 4 wrap — POKEY has no TIMER 3)  latched
//     bit 3  SER OUT COMPLETE — output shift register idle  *unlatched*
//     bit 4  SER OUT READY    — SEROUT loaded into shifter  latched
//     bit 5  SER IN BYTE      — SERIN holds a fresh byte    latched
//     bit 6  KEYBOARD         — KBCODE event valid          latched
//     bit 7  BREAK KEY        — Atari BREAK key down        latched
//
// IRQ semantics (per Altirra §5.7 + Atari Hardware Manual):
//   - For latched bits: irq_latch_q[i] is set when the source pulses
//     AND irqen_q[i]=1; once set the latch sticks until IRQEN-cleared.
//   - For bit 3 (special, not latched): the bit is simply active
//     whenever the serial output shift register is idle and
//     deasserts automatically when a new byte begins to shift out —
//     IRQEN[3] still gates the IRQ line contribution.
//   - IRQST returns ~(latches | live[3]) — bit=0 means "this source
//     pending".
//   - IRQ_n (output) is asserted (low) while any IRQEN-enabled source
//     bit is high.
//   - Writing IRQEN with a bit cleared also clears the corresponding
//     latch bit (software acks an IRQ by clearing IRQEN bit, then
//     re-enabling). Bit 3 has no latch to clear.
//   - SKRES write clears the two latched serial bits (4, 5) but
//     does not affect bit 3 (no latch).

`default_nettype none

module pokey_regs (
    input  wire        clk,
    // Machine-cycle strobe -- clocks the IRQST in-flight countdown.
    input  wire        phi2_tick,
    input  wire        rst,
    input  wire        cold_boot,   // SALLYRST cold-boot: power-on-clear IRQEN (+ latches)

    // Write port from bus_snoop.
    input  wire        we,                 // snoop_we_pokey
    input  wire [7:0]  waddr,              // snoop_addr[7:0]
    input  wire [7:0]  wdata,

    // Read pulse (1 cycle, registered) + the snoop'd read address —
    // M23-4 uses this to clear KEY_LATCH on a KBCODE read (read-clears
    // semantics).
    input  wire        re,                 // snoop_re_pokey
    input  wire [7:0]  re_addr,            // snoop_addr at time of read

    // Read port (combinational, off live bus).
    input  wire [7:0]  raddr,
    output logic [7:0] rdata,

    // Audio control — to pokey_audio.
    output wire  [7:0] audf1, audf2, audf3, audf4,
    output wire  [7:0] audc1, audc2, audc3, audc4,
    output wire  [7:0] audctl,

    // M23-2: RANDOM source (17-bit LFSR high byte) — read at $D20A.
    input  wire  [7:0] random_byte,

    // M23-4: keyboard event ingest. The full Atari KBCODE byte
    // (scan code in [5:0] + shift in [6] + ctrl in [7]) arrives
    // pre-packed from the RP2354 USB-host translator. A 1-cycle
    // `kbd_event_valid` latches `kbd_event_code` into KBCODE and
    // sets KEY_LATCH (cleared on a KBCODE read).
    input  wire        kbd_event_valid,
    input  wire  [7:0] kbd_event_code,

    // Key-release strobe (1 cycle): clears the SKSTAT "key still pressed"
    // bit so the OS auto-repeat stops.  kbd_event_valid sets it (key down);
    // kbd_release clears it (all keys up) — driven from the USB-host PS.
    input  wire        kbd_release,

    // M23-5: POT scan. potgo_pulse pulses for one cycle on a $D20B
    // write, kicking off a new scan inside pokey_pot. The POTn /
    // ALLPOT reads come back through this register file's read mux.
    output wire        potgo_pulse,

    // STIMER ($D209) — 1-cycle pulse, reloads all four channel
    // counters from AUDFn and forces the audio output flip-flops
    // to 1. Consumed by pokey_audio (Altirra §5.3).
    output wire        stimer_pulse,
    input  wire  [7:0] pot0, pot1, pot2, pot3,
    input  wire  [7:0] pot4, pot5, pot6, pot7,
    input  wire  [7:0] allpot,

    // M23-6: IRQ source pulses (1-cycle high on event).
    // timer{1,2,4}_pulse come from pokey_audio (channel-wrap edges).
    // The serial pulses come from the SIO state machine (M25); for
    // sim they're driven directly by the testbench. break_key is a
    // future input from the keyboard ingest path.
    //
    // ser_out_complete is a *level* signal (not a 1-cycle pulse) —
    // bit 3's "shifter idle" semantics. ser_out_ready_pulse is the
    // 1-cycle pulse that fires when SEROUT loads into the shifter
    // (bit 4 latches on this).
    input  wire        timer1_pulse,
    input  wire        timer2_pulse,
    input  wire        timer4_pulse,
    input  wire        ser_out_complete,        // level — bit 3, unlatched
    input  wire        ser_out_ready_pulse,     // pulse — bit 4, latched
    input  wire        ser_in_byte_pulse,
    input  wire  [7:0] ser_in_byte,
    input  wire        break_key_pulse,

    // M23-6: IRQ output (active-low, asserted while any latch bit set).
    output wire        irq_n,

    // M23-6: SEROUT shadow + 1-cycle write strobe — drives the future
    // SIO state machine (M25). serout_byte holds the last $D20D write.
    output wire  [7:0] serout_byte,
    output wire        serout_strobe,

    // M23-6: SKCTL pass-through to pokey_pot (bit 2 selects
    // continuous-scan POT mode). Other SKCTL bits stay internal —
    // serial framing/clocking lands with M25.
    output wire  [7:0] skctl_out,

    // M23-6: SKSTAT serial-flag inputs — framing=bit4, overrun=bit3,
    // busy=bit1 (bit2 is KEY-still-pressed, not serial; see the SKSTAT read).
    // Tied 0 here in the chiplet build until M25's SIO state machine drives them.
    input  wire        ser_framing_err,
    input  wire        ser_input_overrun,
    input  wire        ser_input_busy
);

    // ---- Storage -----------------------------------------------------
    logic [7:0] audf1_q, audf2_q, audf3_q, audf4_q;
    logic [7:0] audc1_q, audc2_q, audc3_q, audc4_q;
    logic [7:0] audctl_q;

    // M23-4 keyboard
    logic [7:0] kbcode_q;        // last received scan code (+ shift / ctrl)
    logic       key_latch_q;     // SKSTAT[5] — set on event, cleared on KBCODE read
    logic       key_down_q;      // SKSTAT[2] (active-low) — a key is currently held
    // SKSTAT error latches (active-LOW: 1 = no error).  Set low on the
    // event, returned high by an SKRES ($D20A) write — real POKEY / Altirra
    // semantics (SKRES: mSKSTAT |= 0xE0; it does NOT touch IRQST).
    logic       frame_err_n_q;   // SKSTAT[7] serial input framing error
    logic       ser_ovr_n_q;     // SKSTAT[6] serial input overrun
    logic       kbd_ovr_n_q;     // SKSTAT[5] keyboard overrun
    logic [7:0] skctl_q;         // $D20F write — debounce / scan rate / serial mode

    // M23-6 IRQ + serial
    logic [7:0] irqen_q;         // $D20E write — IRQ enable mask
    logic [7:0] irq_latch_q;     // internal IRQ latches (set on enabled pulse)
    logic [7:0] serout_q;        // $D20D write — last SEROUT byte
    logic [7:0] serin_q;         // $D20D read  — last shifted-in byte

    // Write strobes — combinational 1-cycle pulses on the relevant
    // $D20x writes. Consumers latch on `we && waddr[3:0] == ...`.
    assign potgo_pulse   = we && (waddr[3:0] == 4'hB);
    assign stimer_pulse  = we && (waddr[3:0] == 4'h9);
    assign serout_strobe = we && (waddr[3:0] == 4'hD);
    // BYPASS THE REGISTER ON THE STROBE CYCLE.  serout_strobe is combinational
    // on the write, but serout_q only takes wdata at the END of that cycle --
    // so a consumer that latches on the strobe (pokey_serial does) sees the
    // PREVIOUS byte.  pokey_twotone writes $fc and the shifter loaded $00, so
    // its frame was all spaces and the two-tone hold had no marks to act on.
    assign serout_byte   = serout_strobe ? wdata : serout_q;
    assign skctl_out     = skctl_q;

    // IRQ status: bit 3 is unlatched (live ser_out_complete level);
    // all other bits come from the latches. The IRQ-pending vector
    // (1 = pending) is the OR of those.
    wire [7:0] irq_pending;
    assign irq_pending = {irq_latch_q[7],     // BREAK KEY
                          irq_latch_q[6],     // KEYBOARD
                          irq_latch_q[5],     // SER IN BYTE
                          irq_latch_q[4],     // SER OUT READY
                          ser_out_complete,   // SER OUT COMPLETE (live)
                          irq_latch_q[2],     // TIMER 4
                          irq_latch_q[1],     // TIMER 2
                          irq_latch_q[0]};    // TIMER 1
    // IRQ_n active low whenever any IRQEN-enabled pending bit is high --
    // but the LINE runs IRQ_LINE_LAG behind the STATUS BIT.  emu raise()
    // (pokey_timer.c:541) arms it as IRQ_LINE_LAG + lag, so a fast timer's
    // bit is readable at +24 and its /IRQ follows at +25; pokey_irqtiming
    // measures the line, pokey_timertiming the bit.  Only the ASSERTING edge
    // is delayed -- an acknowledge clears the line at once.
    localparam int IRQ_LINE_LAG = 1;
    wire  irq_now = |(irq_pending & irqen_q);
    logic irq_dly_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)            irq_dly_q <= 1'b0;
        else if (phi2_tick) irq_dly_q <= irq_now;
    end
    assign irq_n         = ~(irq_now & irq_dly_q);

    // ---- IRQST delivery lag (emu pokey_timer.c:467, 505-545) ---------------
    // fast_for_bit(): timer 4 follows AUDCTL[5] ($20), timers 1 and 2 follow
    // AUDCTL[6] ($40).
    localparam int IRQST_LAG = 4;
    logic [2:0] st_lag_q   [0:2];
    logic       st_armed_q [0:2];
    wire [2:0]  tmr_pulse = {timer4_pulse, timer2_pulse, timer1_pulse};
    wire [2:0]  tmr_fast  = {audctl_q[5], audctl_q[6], audctl_q[6]};

    assign audf1  = audf1_q;
    assign audf2  = audf2_q;
    assign audf3  = audf3_q;
    assign audf4  = audf4_q;
    assign audc1  = audc1_q;
    assign audc2  = audc2_q;
    assign audc3  = audc3_q;
    assign audc4  = audc4_q;
    assign audctl = audctl_q;

    // ---- Write side --------------------------------------------------
    // POKEY is at $D2xx; bus_snoop only fires `we` for that page.
    // Sub-decode by the low 4 bits (POKEY mirrors every 16 bytes).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            audf1_q     <= 8'h00;
            audf2_q     <= 8'h00;
            audf3_q     <= 8'h00;
            audf4_q     <= 8'h00;
            audc1_q     <= 8'h00;
            audc2_q     <= 8'h00;
            audc3_q     <= 8'h00;
            audc4_q     <= 8'h00;
            audctl_q    <= 8'h00;
            for (int i = 0; i < 3; i++) begin
                st_lag_q[i]   <= 3'd0;
                st_armed_q[i] <= 1'b0;
            end
            kbcode_q    <= 8'h00;
            key_latch_q <= 1'b0;
            key_down_q  <= 1'b0;
            frame_err_n_q <= 1'b1;
            ser_ovr_n_q   <= 1'b1;
            kbd_ovr_n_q   <= 1'b1;
            skctl_q     <= 8'h00;
            irqen_q     <= 8'h00;
            irq_latch_q <= 8'h00;
            serout_q    <= 8'h00;
            serin_q     <= 8'h00;
        end else if (cold_boot) begin
            // SALLYRST cold-boot mimics a POKEY power-on reset: clear IRQEN and the
            // IRQ latches so a freshly launched OS never inherits the previous
            // session's IRQEN — which (with a pending source) holds IRQ_n low and
            // derails the guest's reset before coldstart masks it. The 6502 is held
            // during cold-boot, so this never races a real $D20E write. Pairs with
            // the ANTIC NMIEN clear. See xl-coldstart-nmi-derail.
            irqen_q     <= 8'h00;
            irq_latch_q <= 8'h00;
        end else begin
            // ---- Keyboard event ingest (M23-4) -----
            if (kbd_event_valid) begin
                kbcode_q    <= kbd_event_code;
                key_latch_q <= 1'b1;
            end
            // KBCODE read clears KEY_LATCH (1 cycle after the read).
            if (re && (re_addr[3:0] == 4'h9)) begin
                key_latch_q <= 1'b0;
            end
            // SKSTAT "key still pressed" (bit 2, active-low): a key-down event
            // sets it; the PS clears it when all keys are released, so the OS
            // auto-repeat runs only while a key is genuinely held.
            if (kbd_event_valid)  key_down_q <= 1'b1;
            else if (kbd_release) key_down_q <= 1'b0;
            // Keyboard overrun: a new key event while KBCODE is still unread.
            if (kbd_event_valid && key_latch_q) kbd_ovr_n_q <= 1'b0;
            if (ser_framing_err)   frame_err_n_q <= 1'b0;
            if (ser_input_overrun) ser_ovr_n_q   <= 1'b0;

            // ---- Serial input byte capture (M23-6) -----
            if (ser_in_byte_pulse) serin_q <= ser_in_byte;

            // ---- IRQ source latching (M23-6) -----
            // Each latched source sets its bit when pulsed AND
            // IRQEN[bit]=1. Bit 3 (SER OUT COMPLETE) is *not*
            // latched — its IRQST contribution is the live
            // ser_out_complete input (see irq_pending above).
            // A FAST-CLOCKED TIMER'S STATUS BIT IS NOT READABLE THE CYCLE IT
            // UNDERFLOWS -- IT IS IN FLIGHT FOR IRQST_LAG MACHINE CYCLES.
            // emu pokey_timer.c:505-523 pins it from pokey_timertiming's two
            // tables of the SAME timer: the STIMER-preemption table measures the
            // UNDERFLOW (AUDF1=0 at 4, AUDF1=8 at 12, i.e. AUDF+4 with nothing
            // extra on the first period) and the IRQST table measures when the
            // BIT CAN BE READ (AUDF1=0 at 8, AUDF1=16 at 24) -- four later on
            // every row they share.
            //
            // It belongs to the DELIVERY path, not the period: emu tried it as a
            // longer first period and recorded that this "also delayed the
            // underflow the preemption test strobes against -- and no value
            // could then satisfy both tables."
            //
            // And it is a property of the 1.79 MHz tap alone (fast_for_bit):
            // a base-clocked channel takes no lag at all, which is what keeps
            // pokey_inittiming's 15 kHz acknowledge where it always was.
            for (int i = 0; i < 3; i++) begin
                if (tmr_pulse[i]) begin
                    if (tmr_fast[i]) begin
                        // In flight. Arming is sampled now; a masked raise still
                        // flies (emu's st_armed / IRQEN_ARMS_INFLIGHT).
                        // The full IRQST_LAG.  The CPU latches read data at the
                        // END of the read cycle, so a bit that becomes visible on
                        // the cycle the test samples reads as ALREADY PENDING --
                        // pokey_timertiming's "triggered too early (loop #1)"
                        // with d1=$00.  Do not shorten this to match a probe that
                        // prints the latch's own set cycle; d1 is the ground truth.
                        st_lag_q[i]   <= 3'(IRQST_LAG);
                        st_armed_q[i] <= irqen_q[i];
                    end else if (irqen_q[i]) begin
                        // No lag, so no flight to be armed during: a masked
                        // raise on a base-clocked channel is simply lost.
                        irq_latch_q[i] <= 1'b1;
                    end
                end else if (stimer_pulse && st_lag_q[i] == 3'(IRQST_LAG - 1)) begin
                    // A STIMER STROBE CANCELS AN INTERRUPT THAT HAS ONLY JUST
                    // UNDERFLOWED.  emu pokey_timer.c:1005-1024 tabulates the
                    // boundary and finds it is a ONE-CYCLE window, not the four
                    // the bit is in flight for: "STIMER reaches the counter and
                    // the first stage of the delay that carries the underflow to
                    // IRQST, and nothing further along it."  A bit raised on the
                    // last tick still has its full lag standing, so "st_lag still
                    // at its maximum" IS "raised this tick", and dropping the
                    // countdown is the whole cancellation -- IRQST is active low
                    // and the bit has not been cleared yet.
                    st_lag_q[i]   <= 3'd0;
                    st_armed_q[i] <= 1'b0;
                end else if (phi2_tick && st_lag_q[i] != 3'd0) begin
                    st_lag_q[i] <= st_lag_q[i] - 3'd1;
                    if (st_lag_q[i] == 3'd1 && st_armed_q[i]) irq_latch_q[i] <= 1'b1;
                end
            end
            if (ser_out_ready_pulse  && irqen_q[4]) irq_latch_q[4] <= 1'b1;
            if (ser_in_byte_pulse    && irqen_q[5]) irq_latch_q[5] <= 1'b1;
            if (kbd_event_valid      && irqen_q[6]) irq_latch_q[6] <= 1'b1;
            if (break_key_pulse      && irqen_q[7]) irq_latch_q[7] <= 1'b1;

            // ---- Register writes -----
            if (we) begin
                case (waddr[3:0])
                    4'h0: audf1_q  <= wdata;
                    4'h1: audc1_q  <= wdata;
                    4'h2: audf2_q  <= wdata;
                    4'h3: audc2_q  <= wdata;
                    4'h4: audf3_q  <= wdata;
                    4'h5: audc3_q  <= wdata;
                    4'h6: audf4_q  <= wdata;
                    4'h7: audc4_q  <= wdata;
                    4'h8: audctl_q <= wdata;
                    4'hA: begin
                        // SKRES — returns the three SKSTAT error latches
                        // (framing / serial overrun / keyboard overrun) to
                        // the no-error state.  Real POKEY's SKRES does NOT
                        // touch the IRQ latches (Altirra: mSKSTAT |= 0xE0
                        // only; ACID800 pokey_skstat) — IRQ acks go through
                        // the IRQEN write path.
                        frame_err_n_q <= 1'b1;
                        ser_ovr_n_q   <= 1'b1;
                        kbd_ovr_n_q   <= 1'b1;
                    end
                    4'hD: serout_q <= wdata;       // SEROUT
                    4'hE: begin
                        // IRQEN — store mask AND clear any latch bits
                        // whose enable bit is being cleared (per
                        // Atari hardware-manual ack semantics).
                        irqen_q     <= wdata;
                        irq_latch_q <= irq_latch_q & wdata;
                    end
                    4'hF: skctl_q  <= wdata;       // SKCTL
                    // $D209 STIMER / $D20B POTGO — strobes (no state
                    // change here; observed via potgo_pulse / future
                    // STIMER reset wiring).
                    default: ;
                endcase
            end
        end
    end

    // ---- Read side --------------------------------------------------
    // POKEY's read addresses are completely distinct from its write
    // addresses (POKEY uses R/W to disambiguate same-address reads
    // and writes — e.g. $D20F = SKCTL on write, SKSTAT on read).
    //
    // M23-5: POT0..POT7 at $D200..$D207, ALLPOT at $D208.
    // M23-2: RANDOM at $D20A.
    // M23-4: KBCODE at $D209; SKSTAT at $D20F.
    // M23-6: SERIN at $D20D, IRQST at $D20E, SKSTAT serial bits 4..2.
    always_comb begin
        case (raddr[3:0])
            4'h0: rdata = pot0;
            4'h1: rdata = pot1;
            4'h2: rdata = pot2;
            4'h3: rdata = pot3;
            4'h4: rdata = pot4;
            4'h5: rdata = pot5;
            4'h6: rdata = pot6;
            4'h7: rdata = pot7;
            4'h8: rdata = allpot;       // ALLPOT
            4'h9: rdata = kbcode_q;     // KBCODE
            4'hA: rdata = random_byte;  // RANDOM
            4'hD: rdata = serin_q;       // SERIN
            4'hE: rdata = ~irq_pending;  // IRQST (0 = pending; bit 3 live)
            // SKSTAT layout (Atari):
            //   bit 7 = SHIFT key live (kbcode_q[6])
            //   bit 6 = KEY_DOWN live   (0 — covered by bit 2 below)
            //   bit 5 = KEY_LATCH       (1 = event waiting; cleared on
            //                            KBCODE read)
            //   bit 4 = SER FRAMING ERR (from SIO state machine)
            //   bit 3 = SER INPUT OVERRUN
            //   bit 2 = KEY still pressed (active-low: 0 = a key is held).
            //           The OS auto-repeat reads this bit; it must release
            //           between taps or every key repeats forever.
            //   bit 1 = SER INPUT SHIFT-REGISTER IDLE (active-low busy):
            //           1 = idle (not shifting a byte in), 0 = a byte is
            //           being received.  POKEY reports this bit *inverted*
            //           vs. the internal `ser_input_busy` level — ACID800
            //           pokey_skstat reads it as 1 while the port is idle
            //           ("Serial input active bit was asserted when idle"
            //           fires when it reads 0).  See Altirra §5.10.
            //   bit 0 = unused (always 0)
            4'hF: rdata = {frame_err_n_q,       // b7 framing error (0=err)
                           ser_ovr_n_q,         // b6 serial input overrun (0=err)
                           kbd_ovr_n_q,         // b5 keyboard overrun (0=err)
                           1'b1,                // b4 direct serial in (idle mark)
                           1'b1,                // b3 shift held (0=held; live state
                                                //    not plumbed — KBCODE b6 carries
                                                //    shift for typed keys)
                           ~key_down_q,         // b2 key still pressed (0=held)
                           ~ser_input_busy,     // b1 serial input busy (0=busy)
                           1'b1};               // b0 unused, reads 1
            // $D20B / $D20C are unused POKEY read addresses; the chip
            // does not drive the data bus for them, so the Atari reads
            // the pulled-up bus as $FF.  ACID800 pokey_default reads
            // $D20C and asserts $FF ("POKEY default value wrong").
            default: rdata = 8'hFF;
        endcase
    end

endmodule

`default_nettype wire
