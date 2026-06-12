# jtag_sysdow.tcl — "real reset" ELF reload: rst -system + ps7_init + download,
# but WITHOUT re-programming the PL.
#
# Middle ground between:
#   * jtag_dow.tcl   — rst -processor only.  Leaves DDR/peripherals live, so
#                      heap/FAT/driver state accumulates across reloads and
#                      eventually "luaL_newstate failed — heap too small".
#   * jtag_load.tcl  — full cold-load incl. `fpga -file`, which re-configures
#                      the PL and unlocks the clk_pix MMCM -> needs a physical
#                      power-cycle.
#
# `rst -system` re-initialises the DDR controller + peripherals (a genuinely
# CLEAN heap every reload); skipping `fpga -file` leaves the live PL config and
# the clk_pix MMCM lock untouched, so NO power-cycle is needed.
#
# Usage:
#   xsct jtag_sysdow.tcl <elf> [host]
#   defaults: elf = vitis/workspace/xtos/build/xtos.elf,  host = TCP:127.0.0.1:3121

set this_dir  [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $this_dir .. ..]]

set elf_path [expr {$argc >= 1 ? [lindex $argv 0] :
                     [expr {[info exists ::env(ELF)] ? $::env(ELF) :
                            [file join $repo_root vitis workspace xtos build xtos.elf]}]}]
set hw_host  [expr {$argc >= 2 ? [lindex $argv 1] :
                     [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER) :
                            "TCP:127.0.0.1:3121"}]}]

# ps7_init.tcl from the BD gen tree (same search as jtag_load.tcl).
if {[info exists ::env(PS7_INIT_TCL)]} {
    set ps_init_tcl $::env(PS7_INIT_TCL)
} else {
    set cands [list \
        [file join $repo_root bd zynq_ps_bd zynq_ps_bd.gen sources_1 \
                   bd ps_bd ip ps_bd_zynq_ps_0 ps7_init.tcl] \
        [file join $repo_root vivado bd zynq_ps_bd zynq_ps_bd.gen sources_1 \
                   bd ps_bd ip ps_bd_zynq_ps_0 ps7_init.tcl]]
    set ps_init_tcl ""
    foreach c $cands { if {[file exists $c]} { set ps_init_tcl $c; break } }
    if {$ps_init_tcl eq ""} { set ps_init_tcl [lindex $cands 0] }
}

foreach {label path} [list elf $elf_path ps7_init.tcl $ps_init_tcl] {
    if {![file exists $path]} { puts stderr "ERROR: $label not found at $path"; exit 1 }
}

puts ">> REAL-RESET reload (rst -system, PL + clk_pix untouched): $elf_path"
puts ">> ps7_init.tcl: $ps_init_tcl"
puts ">> hw_server:    $hw_host"
connect -url $hw_host
catch { jtag targets }

# Full system reset to flush DDR/peripherals (clean heap), then halt the A9
# before any boot-ROM runs so ps7_init runs against a quiet core.
puts ">> rst -system (clean DDR/peripherals -> clean heap)"
catch { targets -set -filter {name =~ "APU*"} }
catch { rst -system }
after 1000
puts ">> halting A9"
catch { targets -set -filter {name =~ "ARM*#0"}; stop }
catch { stop }
after 300

# Re-init the PS (DDR3, clocks, MIO) — NOT the PL.
puts ">> running ps7_init (re-init DDR/clocks/MIO; PL bitstream left as-is)"
targets -set -filter {name =~ "ARM*#0"}
source $ps_init_tcl
ps7_init
ps7_post_config

puts ">> downloading ELF"
rst -processor
dow $elf_path
puts ">> running"
con
puts ">> done — A9 restarted via rst -system (clean heap), PL + clk_pix untouched"
