# jtag_por.tcl — POWER-ON reset via JTAG.
# `rst -system` does not re-initialise the PLLs. After a bad ARM_PLL programming
# (e.g. an FDIV the part would not lock at), ps7_init runs against a PS that is
# already in a state it does not expect, and every subsequent load fails with no
# console output. -por is the strongest reset the DAP offers and is the JTAG
# equivalent of pulling power, so try it before touching the hardware.
set host [expr {$argc >= 1 ? [lindex $argv 0] : "TCP:127.0.0.1:3121"}]
connect -url $host
targets -set -filter {name =~ "APU*"}
puts ">> rst -por"
if {[catch { rst -por } e]} { puts ">> rst -por failed: $e" }
after 2000
puts ">> targets after POR:"
puts [targets]
