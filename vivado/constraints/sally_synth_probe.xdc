# sally_synth_probe.xdc — Phase 0 fmax probe constraints for sally_synth_top.
#
# This XDC is for the *standalone SALLY synth wrapper* (sally_synth_top.sv),
# not antic_top. It sets a single virtual clock on the `clk` input at 165 MHz
# so the timing summary reports the WNS / slack against today's Ti60 target.
#
# Goal: get a clear "SALLY closes at X MHz on Zynq-7020 -2" number from the
# post-synth timing report, before any RTL changes. Compare against the
# Ti60 -3 result of ~165 MHz.
#
# Once we have real Atari I/O wiring on the carrier, the production XDC
# will have IO placements (set_property PACKAGE_PIN), IO standards, and
# real off-chip clock relationships. This file is intentionally minimal.

# Single 165 MHz target on the `clk` input. Period is in ns.
create_clock -name clk_bus -period 6.06 [get_ports clk]
