# OOC-only constraints — loaded by build.tcl when $flow != "bit".
#
# These properties apply only to out-of-context synth/impl, where input
# ports are treated as partition pins (no IO buffers inferred) and the
# timer needs explicit hints to model clock-network delay.  In the bit
# flow, real IBUF + BUFG cells are inferred from board XDC and applying
# HD.CLK_SRC fails with Common 17-69 ("pin is already buffered").

# Tell the OOC timer which buffer site to model for clk_50's clock
# network.  BUFGCTRL_X0Y0 is the canonical xc7z020 pick per UG903 —
# any valid BUFGCTRL site works for skew/delay estimation purposes.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk_50]
