# jtag_reconfig_pl.tcl — reconfigure ONLY the PL on a LIVE, SD-booted board.
#
# Unlike jtag_load.tcl (cold-board: ps7_init + ELF download), this touches
# nothing in the PS: no ps7_init (which would re-init the DDR controller and
# wipe live DRAM), no core halt, no reset.  It just streams a new bitstream
# into the PL of a running system — the fast "swap the fabric, keep Linux/the
# app alive" iteration path for display/RTL changes.
#
# Usage (run on the JTAG-cable host, e.g. win10):
#   xsdb jtag_reconfig_pl.tcl <bit> [host] [gp0_ctrl_hex]
#     bit          bitstream to load (required)
#     host         hw_server URL           (default TCP:127.0.0.1:3121)
#     gp0_ctrl_hex if given, written to 0x43C0001C after config.  bit0: 0 =
#                  compositor, 1 = test-pattern bars (gp0_ctrl resets to 1 = bars),
#                  so pass 0x0 to show the compositor.  Omit to leave the PL at
#                  its reset default (bars).
#
# Recovery if the PS wedges: `xsdb` -> connect -> `rst -system` (clean SD reboot).

set bit_path [lindex $argv 0]
set hw_url   [expr {$argc >= 2 ? [lindex $argv 1] : "TCP:127.0.0.1:3121"}]
set gp0_ctrl [expr {$argc >= 3 ? [lindex $argv 2] : ""}]

if {$bit_path eq "" || ![file exists $bit_path]} {
    puts "ERROR: bitstream not found: '$bit_path'"
    exit 1
}

puts ">> connecting to hw_server at $hw_url"
connect -url $hw_url

# Enumerate the JTAG scan chain first (the debug `targets` list is populated
# lazily — it can come back empty if queried before the chain is scanned).
catch {jtag targets}

# Select the PL (FPGA) device target — the xc7z020 fabric, NOT an A9 core.
puts ">> targets:"
targets
set ok [catch {targets -set -filter {name =~ "*xc7z020*"}} err]
if {$ok} {
    puts "ERROR: could not select xc7z020 PL target: $err"
    exit 1
}
puts ">> selected PL target (xc7z020)"

puts ">> configuring PL with $bit_path (PS untouched — no ps7_init)"
fpga -file $bit_path
puts ">> PL configuration done"

if {$gp0_ctrl ne ""} {
    # gp0_ctrl @ 0x43C0001C bit0: 1 = compositor path, 0 = test bars.
    # The AXI write must go through an A9's memory view (GP0 @ 0x43C00000),
    # not the FPGA target.  A running core is fine — mwr through the DAP
    # AXI-AP is non-intrusive (no halt).
    set ok [catch {targets -set -filter {name =~ "*Cortex-A9*#0"}} err]
    if {$ok} { puts "ERROR: could not select A9 core for gp0_ctrl write: $err"; exit 1 }
    # xsdb guards PL AXI slave addresses by default ("access is not allowed");
    # this lifts the guard so the single register poke through the A9's AXI view
    # is permitted.
    configparams force-mem-accesses 1
    puts ">> writing gp0_ctrl: *0x43C0001C = $gp0_ctrl (via A9 #0)"
    mwr 0x43C0001C $gp0_ctrl
    puts ">> gp0_ctrl readback: [mrd -value 0x43C0001C]"
}
puts ">> DONE"
