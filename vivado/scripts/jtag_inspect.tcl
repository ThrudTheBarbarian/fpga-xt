# jtag_inspect.tcl — READ-ONLY attach to the running board. No reload, no reset.
# Validates the JTAG memory-read path (mrd) so a live GOT/page-table inspection
# goes smoothly. xsct script mode: every value must go through `puts` to appear.
#
# Usage: xsct jtag_inspect.tcl [addr] [count] [host]
#   addr  = hex word address to dump (default 0x00106f40 = fault_report, a fixed
#           kernel text symbol whose bytes we can cross-check against the ELF)
#   count = words to dump (default 8)
#   host  = hw_server url (default TCP:127.0.0.1:3121)

set addr  [expr {$argc >= 1 ? [lindex $argv 0] : 0x00106f40}]
set count [expr {$argc >= 2 ? [lindex $argv 1] : 8}]
set host  [expr {$argc >= 3 ? [lindex $argv 2] : "TCP:127.0.0.1:3121"}]

puts ">> connect $host"
connect -url $host
targets -set -filter {name =~ "ARM*#0"}
puts ">> target: [lindex [targets] 0]"

# mrd on the A9 DAP; -force lets it read without halting the core where supported.
if {[catch {set v [mrd -force $addr $count]} err]} {
    puts ">> mrd -force failed ($err); retrying plain mrd"
    set v [mrd $addr $count]
}
puts ">> DUMP @ [format 0x%08x $addr] ($count words):"
puts $v
puts ">> done"
