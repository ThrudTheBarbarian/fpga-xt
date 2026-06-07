# jtag_dow_xtos.tcl — download + run a fresh xtos ELF over JTAG on a board
# whose DDR is ALREADY initialised (SD-booted).  No ps7_init (DDR is live),
# no PL reconfig (so no DAP-wedge risk) — just halt the A9, core-reset, load
# the new app, and run.  Use to swap the PS app (e.g. pick up a new Lua/VDI
# binding) without reflashing the SD card.
#
# Usage: xsct jtag_dow_xtos.tcl <elf> [host]
set elf_path [lindex $argv 0]
set hw_url   [expr {$argc >= 2 ? [lindex $argv 1] : "TCP:127.0.0.1:3121"}]

if {$elf_path eq "" || ![file exists $elf_path]} {
    puts "ERROR: ELF not found: '$elf_path'"; exit 1
}

puts ">> connecting to hw_server at $hw_url"
connect -url $hw_url
catch {jtag targets}

puts ">> selecting A9 #0 + halting the running app"
set ok [catch {targets -set -filter {name =~ "*Cortex-A9*#0"}} err]
if {$ok} { puts "ERROR: could not select A9 #0: $err"; exit 1 }
catch {stop}

puts ">> core reset (no -system: keeps DDR + PL intact)"
catch {rst -processor}
catch {stop}
after 200

puts ">> downloading $elf_path"
dow $elf_path
puts ">> running"
con
puts ">> DONE — new xtos should re-print its boot banner on UART"
