# zynq_io_placeholder.xdc — Placeholder I/O constraints for bitstream builds.
#
# This file provides the minimum I/O configuration needed for Vivado's
# write_bitstream to succeed when the real board-level PACKAGE_PIN +
# IOSTANDARD assignments are not yet known.
#
# Strategy: downgrade NSTD-1 (No IOSTANDARD) and UCIO-1 (Unconstrained port)
# from ERROR to WARNING so that write_bitstream proceeds with auto-placed I/Os.
# This is valid for toolchain smoke-testing only — DO NOT use this file for
# production hardware bring-up.
#
# Production constraint source (TODO):
#   - Z-Turn Z7-Lite schematic: SiI9022A RGB output pins, UART MIO, 50 MHz
#     oscillator pin, reset button pin.
#   - IOSTANDARD: LVCMOS33 for all PL I/O (bank 35, 1.8V/3.3V per bank).
#   - PACKAGE_PIN: match the SOM carrier schematic.

# ---- DRC suppression -------------------------------------------------------
# Downgrade "No IOSTANDARD" from ERROR to WARNING so write_bitstream does not
# abort when top-level ports lack IOSTANDARD properties.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]

# Downgrade "Unconstrained Logical Port" from ERROR to WARNING so that ports
# without PACKAGE_PIN assignments do not block bitstream generation.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

# Optional: set a default IOSTANDARD so Vivado doesn't need to invent one.
# This is not strictly necessary when NSTD-1 is a warning, but it suppresses
# the warning noise and gives the tools a sensible buffer standard.
set_property IOSTANDARD LVCMOS33 [get_ports]

# ---- Combinatorial loop allowance (now fixed) --------------------------------
# The SALLY RDY loop was fixed in v0.15 by registering busy_n in sally_clock.sv.
# The DRC suppression LUTLP-1 is no longer needed — keep the set_property for
# safety in case this XDC is used with an older bitstream build that lacks the
# fix, but the proper fix should always be preferred.
