# dap-recover.tcl — unwedge the board's DAP.
#
# Symptom: `targets` lists only "DAP (APB/AHB AP transaction error, DAP status
# 0x30000021)" and the ARM cores do not enumerate, so both jtag-valhalla.sh
# `reset` and `load` die at their target filter, or `load` fails at `dow` with
# "Memory write error at 0x100000. AP transaction timeout".
#
# This is the BOARD's DAP, not the cable and not the host: usbreset and
# restarting hw_server are wasted time here (they are the right first move for
# an EMPTY chain, which is a different fault).
#
# After recovering, run `load` with NO reset leg — the reset leg boots the
# kernel, and reprogramming the PL under a running image is what wedges it.
connect -url TCP:127.0.0.1:3121
catch { jtag targets }
targets 1                  ;# the APU entry: rst needs a selected target
catch { rst -srst }
after 2000
catch { rst -system }       ;# both are needed; -srst alone sometimes leaves it wedged
after 2000
puts ">> targets after recovery:"
puts [targets]
