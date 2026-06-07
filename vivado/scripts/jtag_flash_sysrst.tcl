# jtag_flash_sysrst.tcl — one-off: system-reset the board (clear the DAP),
# let the PS reboot from SD, then overlay the freshly-built PL bitstream on
# the live system and re-select the compositor.
#
# For a LIVE SD-booted board where reconfiguring the PL under the running A9
# (in-flight GP0/HP AXI) would otherwise wedge the DAP.  `rst -system` quiesces
# everything first; we then wait out the SD reboot before swapping the fabric.
#
# Usage:
#   xsct jtag_flash_sysrst.tcl <bit> [host] [gp0_ctrl_hex] [boot_wait_ms]
#     bit           bitstream (required)
#     host          hw_server URL        (default TCP:127.0.0.1:3121)
#     gp0_ctrl_hex  written to 0x43C0001C after config (default 0x0 = compositor)
#     boot_wait_ms  wait after rst -system for SD boot (default 9000)

set bit_path  [lindex $argv 0]
set hw_url    [expr {$argc >= 2 ? [lindex $argv 1] : "TCP:127.0.0.1:3121"}]
set gp0_ctrl  [expr {$argc >= 3 ? [lindex $argv 2] : "0x0"}]
set boot_wait [expr {$argc >= 4 ? [lindex $argv 3] : 9000}]

if {$bit_path eq "" || ![file exists $bit_path]} {
    puts "ERROR: bitstream not found: '$bit_path'"
    exit 1
}

puts ">> connecting to hw_server at $hw_url"
connect -url $hw_url
catch {jtag targets}

# ---- System reset: clear the DAP + quiesce all AXI, clean SD reboot ------
puts ">> rst -system (clear DAP, clean SD reboot)"
catch {targets -set -filter {name =~ "APU*"}}
rst -system
puts ">> waiting ${boot_wait} ms for FSBL + xtos to boot from SD"
after $boot_wait

# ---- Overlay the new PL bitstream on the live (freshly-booted) PS --------
catch {jtag targets}
set ok [catch {targets -set -filter {name =~ "*xc7z020*"}} err]
if {$ok} { puts "ERROR: could not select xc7z020 PL target: $err"; exit 1 }
puts ">> configuring PL with $bit_path"
fpga -file $bit_path
puts ">> PL configuration done"

# ---- Re-select the compositor (fabric swap reset gp0_ctrl to its default) -
set ok [catch {targets -set -filter {name =~ "*Cortex-A9*#0"}} err]
if {$ok} { puts "ERROR: could not select A9 #0 for gp0_ctrl: $err"; exit 1 }
configparams force-mem-accesses 1
puts ">> writing gp0_ctrl: *0x43C0001C = $gp0_ctrl (via A9 #0)"
mwr 0x43C0001C $gp0_ctrl
puts ">> gp0_ctrl readback: [mrd -value 0x43C0001C]"
puts ">> DONE"
