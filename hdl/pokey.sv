// pokey.sv — POKEY top-level wrapper (M23-1 stage).
//
// Composes pokey_regs (snoop-fed register file) and pokey_audio
// (4-channel square-wave generator, no LFSR yet) into a single
// instance for antic_top to drop in alongside antic_regs / gtia_regs /
// draw_regs.
//
// Sub-milestones M23-2..M23-7 will add LFSR poly counters, AUDCTL
// features, keyboard / POT scan, IRQ aggregation, and the I2S TX
// path — each adds a sibling module instance under here without
// changing this wrapper's port list.

`default_nettype none

module pokey #(
    parameter int unsigned CLK_BUS_HZ   = 161_079_525,   // 90 × NTSC phi2 (M-cache-rework Step 5b)
    parameter int unsigned REF_HZ_M23_1 = 64_000,        // AUDCTL[0]=0 reference
    parameter int unsigned REF_HZ_LOW   = 15_700,        // AUDCTL[0]=1 reference (M23-3)
    parameter int unsigned REF_PHI2_HI  = 28,            // 64 kHz period in phi2 cycles
    parameter int unsigned REF_PHI2_LO  = 114,           // 15 kHz period in phi2 cycles
    parameter int unsigned REF_REL_HI   = 22,            // init-release phase (Altirra)
    parameter int unsigned REF_REL_LO   = 81,
    parameter int unsigned REL_SKEW     = 2              // write-commit vs phi2_tick alignment
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cold_boot,   // SALLYRST cold-boot -> power-on-clear IRQEN in pokey_regs

    // Bus phi2 strobe — 1-cycle pulse per 6502 phi2 rising edge.
    // Generated at antic_top from the bus-clock divider; consumed by
    // POKEY's high-frequency channel mode (audit fix #2) and the
    // fast pot-scan path (audit fix #3). Parametric — no fixed
    // multiplier baked in.
    input  wire        phi2_tick,

    // Snoop side (write port + combinational read port). Same shape
    // as antic_regs / gtia_regs.
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [7:0]  wdata,
    input  wire        re,                  // M23-4: read pulse for KBCODE-clears-latch
    input  wire [7:0]  re_addr,             //         and the snoop'd address
    input  wire [7:0]  raddr,
    output wire [7:0]  rdata,

    // M23-4 keyboard event ingest. Pre-packed Atari KBCODE byte
    // (scan code [5:0] + shift [6] + ctrl [7]) from the RP2354
    // USB-host translator; 1-cycle valid pulse latches it and
    // sets KEY_LATCH.
    input  wire        kbd_event_valid,
    input  wire [7:0]  kbd_event_code,
    input  wire        kbd_release,         // all-keys-up strobe (clears SKSTAT key-down)

    // M25-3c POT scan. POKEY no longer runs the discharge counter
    // in HDL — peri_pot_bridge above antic_top hands shadow values
    // back from the peri-RP, which does the actual scan in firmware
    // (PIO state machine sustains 1.79 MHz fast-scan). pokey forwards
    // potgo_pulse + fast_scan up through pokey_pot for the bridge.
    input  wire [7:0]  shadow_pot0, shadow_pot1, shadow_pot2, shadow_pot3,
    input  wire [7:0]  shadow_pot4, shadow_pot5, shadow_pot6, shadow_pot7,
    input  wire [7:0]  shadow_allpot,
    output wire        bridge_potgo_pulse,
    output wire        bridge_fast_scan,

    // Audio output — 4 × 4-bit channel samples. Sum into stereo PCM
    // happens at M23-7 (pokey_i2s_tx); M23-1 just exposes the four
    // channels for sim / inspection.
    output wire  [3:0] ch1_out,
    output wire  [3:0] ch2_out,
    output wire  [3:0] ch3_out,
    output wire  [3:0] ch4_out,

    // M23-6 IRQ + serial. ser_*_pulse / ser_in_byte drive the IRQ
    // latches and SERIN register; serout_byte / serout_strobe go out
    // to the future SIO state machine (M25). break_key_pulse is a
    // future input from the keyboard ingest path. irq_n is the
    // active-low aggregate to the SALLY core (or external 6502).
    //
    // ser_out_complete is a level (shifter idle) — bit 3 unlatched.
    // ser_out_ready_pulse is a 1-cycle pulse — bit 4 latched.
    input  wire        ser_out_complete,
    input  wire        ser_out_ready_pulse,
    input  wire        ser_in_byte_pulse,
    input  wire  [7:0] ser_in_byte,
    input  wire        break_key_pulse,
    input  wire        ser_framing_err,
    input  wire        ser_input_overrun,
    input  wire        ser_input_busy,
    output wire        irq_n,
    output wire  [7:0] serout_byte,
    output wire        serout_strobe,
    output wire  [7:0] skctl_out
);

    // Register file ↔ audio glue.
    wire [7:0] audf1, audf2, audf3, audf4;
    wire [7:0] audc1, audc2, audc3, audc4;
    wire [7:0] audctl;
    wire [7:0] random_byte;        // M23-2: 17-bit LFSR high byte → RANDOM ($D20A)

    // Register file ↔ POT scan glue (M23-5).
    wire        potgo_pulse;
    wire [7:0]  pot0, pot1, pot2, pot3, pot4, pot5, pot6, pot7;
    wire [7:0]  allpot;

    // Audio ↔ regs IRQ-source wires (M23-6).
    wire timer1_pulse_w, timer2_pulse_w, timer4_pulse_w;
    wire stimer_pulse_w;

    pokey_regs u_regs (
        .clk                  (clk),
        .rst                  (rst),
        .cold_boot            (cold_boot),
        .we                   (we),
        .waddr                (waddr),
        .wdata                (wdata),
        .re                   (re),
        .re_addr              (re_addr),
        .raddr                (raddr),
        .rdata                (rdata),
        .audf1                (audf1),  .audf2 (audf2),
        .audf3                (audf3),  .audf4 (audf4),
        .audc1                (audc1),  .audc2 (audc2),
        .audc3                (audc3),  .audc4 (audc4),
        .audctl               (audctl),
        .random_byte          (random_byte),
        .kbd_event_valid      (kbd_event_valid),
        .kbd_event_code       (kbd_event_code),
        .kbd_release          (kbd_release),
        .potgo_pulse          (potgo_pulse),
        .stimer_pulse         (stimer_pulse_w),
        .pot0                 (pot0),
        .pot1                 (pot1),
        .pot2                 (pot2),
        .pot3                 (pot3),
        .pot4                 (pot4),
        .pot5                 (pot5),
        .pot6                 (pot6),
        .pot7                 (pot7),
        .allpot               (allpot),
        .timer1_pulse         (timer1_pulse_w),
        .timer2_pulse         (timer2_pulse_w),
        .timer4_pulse         (timer4_pulse_w),
        .ser_out_complete     (ser_out_complete_eff),
        .ser_out_ready_pulse  (ser_out_ready_eff),
        .ser_in_byte_pulse    (ser_in_byte_pulse),
        .ser_in_byte          (ser_in_byte),
        .break_key_pulse      (break_key_pulse),
        .ser_framing_err      (ser_framing_err),
        .ser_input_overrun    (ser_input_overrun),
        .ser_input_busy       (ser_input_busy),
        .irq_n                (irq_n),
        .serout_byte          (serout_byte),
        .serout_strobe        (serout_strobe),
        .skctl_out            (skctl_out)
    );

    wire ref_tick_w;             // audio reference (AUDCTL[0]-selected)
    wire ref_tick_15khz_w;       // fixed 15 kHz — POT slow-scan tick

    pokey_audio #(.CLK_BUS_HZ(CLK_BUS_HZ),
                  .REF_PHI2_HI(REF_PHI2_HI), .REF_PHI2_LO(REF_PHI2_LO),
                  .REF_REL_HI(REF_REL_HI),   .REF_REL_LO(REF_REL_LO),
                  .REL_SKEW(REL_SKEW),
                  .REF_HZ_M23_1(REF_HZ_M23_1),
                  .REF_HZ_LOW(REF_HZ_LOW)) u_audio (
        .clk          (clk),
        .rst          (rst),
        .phi2_tick    (phi2_tick),
        .audf1        (audf1),  .audf2 (audf2),
        .audf3        (audf3),  .audf4 (audf4),
        .audc1        (audc1),  .audc2 (audc2),
        .audc3        (audc3),  .audc4 (audc4),
        .audctl       (audctl),
        .skctl        (skctl_out),
        .ch1_out      (ch1_out),
        .ch2_out      (ch2_out),
        .ch3_out      (ch3_out),
        .ch4_out      (ch4_out),
        .random_byte  (random_byte),
        .ref_tick_out       (ref_tick_w),
        .ref_tick_15khz_out (ref_tick_15khz_w),
        .ser_out_bit        (ser_out_bit_w),
        .stimer_pulse       (stimer_pulse_w),
        .timer1_pulse (timer1_pulse_w),
        .timer2_pulse (timer2_pulse_w),
        .timer4_pulse (timer4_pulse_w)
    );

    // ---- POKEY'S OWN TRANSMIT SHIFTER --------------------------------------
    //
    // This was written and unit-tested and then never instantiated: pokey took
    // ser_out_complete / ser_out_ready_pulse as INPUTS for a future SIO state
    // machine, and a8_core tied them to 1'b1 / 1'b0.  With the ready pulse
    // wired to a constant zero the serial-output IRQ (IRQEN bit 4) could never
    // fire at all, which is why pokey_serclock's MeasureSerOutRate returned 0
    // where it wanted 40.
    //
    // The external ports stay, because a real SIO can still drive them: idle is
    // the AND (the line is only free if both agree it is) and the ready pulse is
    // the OR.  With a8_core's tie-offs that leaves the shifter in charge.
    wire ser_out_ready_int, ser_out_complete_int, ser_out_bit_w;

    pokey_serial u_serial (
        .clk(clk), .rst(rst),
        .skctl(skctl_out),
        .timer2_pulse(timer2_pulse_w),
        .timer4_pulse(timer4_pulse_w),
        .ext_clk_tick(1'b0),
        .serout_byte(serout_byte),
        .serout_strobe(serout_strobe),
        .ser_out_ready_pulse(ser_out_ready_int),
        .ser_out_complete(ser_out_complete_int),
        .ser_out_bit(ser_out_bit_w),
        .dbg_bitcnt(), .dbg_holding_valid()
    );

    wire ser_out_complete_eff = ser_out_complete    & ser_out_complete_int;
    wire ser_out_ready_eff    = ser_out_ready_pulse | ser_out_ready_int;

    // M23-7 — pokey_i2s_tx now lives at antic_top level so it can mix
    // both POKEYs (left at $D20x, right at $D21x) into the HDMI audio
    // packet feed.

    // M25-3c shadow: pokey_pot is now a thin pass-through that
    // routes potgo_pulse + fast_scan up to peri_pot_bridge and the
    // shadow_* values back to POKEY's register file.
    pokey_pot u_pot (
        .potgo_pulse        (potgo_pulse),
        .fast_scan          (skctl_out[2]),
        .shadow_pot0        (shadow_pot0),
        .shadow_pot1        (shadow_pot1),
        .shadow_pot2        (shadow_pot2),
        .shadow_pot3        (shadow_pot3),
        .shadow_pot4        (shadow_pot4),
        .shadow_pot5        (shadow_pot5),
        .shadow_pot6        (shadow_pot6),
        .shadow_pot7        (shadow_pot7),
        .shadow_allpot      (shadow_allpot),
        .pot0               (pot0),  .pot1 (pot1),  .pot2 (pot2),  .pot3 (pot3),
        .pot4               (pot4),  .pot5 (pot5),  .pot6 (pot6),  .pot7 (pot7),
        .allpot             (allpot),
        .bridge_potgo_pulse (bridge_potgo_pulse),
        .bridge_fast_scan   (bridge_fast_scan)
    );

endmodule

`default_nettype wire
