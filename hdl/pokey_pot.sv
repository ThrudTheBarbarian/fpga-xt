// pokey_pot.sv — POT scan shadow for POKEY (M23-5 → M25-3c).
//
// Originally ran the full discharge-counter loop in HDL with pot_oe /
// pot_in pads driving real paddle GPIO. M25-3c moved that loop onto
// the peri-RP2354B (its PIO state machine can sustain the 1.79 MHz
// fast-scan sample rate that SPI polling can't). pokey_pot is now a
// thin shadow: it forwards `potgo_pulse` + `fast_scan` upward to
// peri_pot_bridge and exposes `pot0..7` + `allpot` from the bridge's
// captured shadow.
//
// The module is kept (instead of inlining its inputs into pokey.sv)
// so the bridge wiring stays a single connection in pokey.sv: pokey
// hands {potgo_pulse, fast_scan, pot0..7, allpot} to one neighbour.
// The actual POT-related state lives in peri_pot_bridge above
// antic_top.

`default_nettype none

module pokey_pot (
    // ---- POKEY-side: live signals from POKEY's register file -----
    input  wire        potgo_pulse,    // 1-cycle pulse on $D20B write
    input  wire        fast_scan,      // SKCTL[2]: 1 = 1.79 MHz mode

    // ---- Bridge-side: shadow values from peri_pot_bridge ----------
    input  wire  [7:0] shadow_pot0, shadow_pot1, shadow_pot2, shadow_pot3,
    input  wire  [7:0] shadow_pot4, shadow_pot5, shadow_pot6, shadow_pot7,
    input  wire  [7:0] shadow_allpot,

    // ---- POKEY-visible read ports ($D200..$D208) -----------------
    output wire  [7:0] pot0, pot1, pot2, pot3,
    output wire  [7:0] pot4, pot5, pot6, pot7,
    output wire  [7:0] allpot,

    // ---- Bridge-side: forwarded kick + scan-mode signal -----------
    output wire        bridge_potgo_pulse,
    output wire        bridge_fast_scan
);

    // Pure pass-through. potgo_pulse / fast_scan / shadow_* travel
    // around antic_top via this module so the pokey ↔ bridge wiring
    // is a single hop.
    assign pot0 = shadow_pot0;
    assign pot1 = shadow_pot1;
    assign pot2 = shadow_pot2;
    assign pot3 = shadow_pot3;
    assign pot4 = shadow_pot4;
    assign pot5 = shadow_pot5;
    assign pot6 = shadow_pot6;
    assign pot7 = shadow_pot7;
    assign allpot = shadow_allpot;

    assign bridge_potgo_pulse = potgo_pulse;
    assign bridge_fast_scan   = fast_scan;

endmodule

`default_nettype wire
