# jtag_dapfix.tcl — unwedge the debug access port.
#
# Symptom this exists for: `dow` fails with "Memory write error at 0x100000.
# AP transaction timeout" — the DAP cannot reach DDR, so no ELF can be loaded
# and the ordinary reset path cannot recover it either.
#
# The sequence is the one recorded in the jtag-dap-wedge-recovery note: select a
# target explicitly (the filter can fail when the DAP is confused), pulse the
# SYSTEM reset line, then a full system reset to re-init DDR and peripherals.
# usbreset on the FTDI cable does NOT fix this — it is the DAP, not the cable.
set host [expr {$argc >= 1 ? [lindex $argv 0] : "TCP:127.0.0.1:3121"}]
connect -url $host
puts ">> targets:"
catch { puts [targets] }
puts ">> selecting target 1"
catch { targets 1 }
puts ">> rst -srst"
catch { rst -srst }
after 1500
puts ">> rst -system"
catch { rst -system }
after 3000
puts ">> targets after recovery:"
catch { puts [targets] }
puts ">> dapfix done"
