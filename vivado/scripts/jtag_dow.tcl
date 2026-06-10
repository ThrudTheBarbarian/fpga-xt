# jtag_dow.tcl — ELF-only reload (no PL reconfig, NO power-cycle needed).
#
# Use this for software-only iteration once a bitstream is already up (from a
# prior jtag_load).  It halts the A9, resets just the processor, downloads a new
# ELF, and runs it — leaving the PL configuration and the clock MMCMs untouched.
# That avoids the pixel-clock MMCM losing lock (the reason a bitstream reload via
# jtag_load needs a power-cycle); an ELF swap doesn't touch the PL at all.
#
# Usage:
#   xsct vivado/scripts/jtag_dow.tcl <elf>            # local/default hw_server
#   xsct vivado/scripts/jtag_dow.tcl <elf> <host>
#   xsct vivado/scripts/jtag_dow.tcl                  # default ELF path
#
# Defaults (override by arg or env):
#   elf  = $ELF        or vitis/workspace/xtos/build/xtos.elf  (win10 flat layout)
#   host = $HW_SERVER  or TCP:127.0.0.1:3121

set this_dir  [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $this_dir .. ..]]

set elf_path [expr {$argc >= 1 ? [lindex $argv 0] :
                     [expr {[info exists ::env(ELF)] ? $::env(ELF) :
                            [file join $repo_root vitis workspace xtos build xtos.elf]}]}]
set hw_host  [expr {$argc >= 2 ? [lindex $argv 1] :
                     [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER) :
                            "TCP:127.0.0.1:3121"}]}]

if {![file exists $elf_path]} { puts stderr "ERROR: elf not found at $elf_path"; exit 1 }

puts ">> ELF-only reload (PL untouched): $elf_path"
puts ">> hw_server: $hw_host"
connect -url $hw_host
catch { jtag targets }

# Target the A9, halt the running image, reset just the core, load + run.
# No rst -system / fpga -file / ps7_init — the PL + DDR + clocks stay configured.
targets -set -filter {name =~ "ARM*#0"}
stop
rst -processor
dow $elf_path
con
puts ">> done — A9 restarted on the new ELF, PL + clocks untouched"
