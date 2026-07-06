# jtag_catch.tcl — arm a HW breakpoint at fault_report and BLOCK until a fault
# halts the board, then dump core regs. Non-intrusive wait: poll xTickCount via
# mrd -force; when it stops advancing the core has halted at the breakpoint.
# Leaves the core HALTED (so dropbear's COW frame is intact for the walk script).
#
# Usage: xsct jtag_catch.tcl [host]

set host [expr {$argc >= 1 ? [lindex $argv 0] : "TCP:127.0.0.1:3121"}]
set FAULT_REPORT 0x00106f40
set XTICK        0x00700120

puts ">> connect $host"
connect -url $host
targets -set -filter {name =~ "ARM*#0"}

bpadd -addr $FAULT_REPORT -type hw
puts ">> breakpoint armed at fault_report ($FAULT_REPORT). REPRODUCE THE CRASH NOW."

# poll xTickCount; two equal consecutive reads => core halted at the bp
set prev "x"; set stable 0; set i 0
while {$i < 1800} {
    after 500
    if {[catch {set cur [lindex [mrd -force $XTICK 1] end]} e]} {
        # mrd may fail transiently while the core stops — treat as "maybe halted"
        incr stable
    } else {
        if {$cur eq $prev} { incr stable } else { set stable 0; set prev $cur }
    }
    if {$stable >= 3} { break }
    incr i
}

# make sure it's actually stopped
catch { stop }
after 200
puts ">> ===== HALTED (tick frozen at $prev) ====="
puts ">> core regs:"
puts [rrd]
puts ">> r0(code) r1(PC) r2(caller):"
catch { puts [rrd r0] }; catch { puts [rrd r1] }; catch { puts [rrd r2] }
puts ">> TTBR0 (cp15):"
if {[catch {puts [rrd ttbr0]} e]} { puts ">> (rrd ttbr0 unavailable: $e — use TTBR0 from the console banner)" }
puts ">> CATCH done — core left HALTED for the walk script"
