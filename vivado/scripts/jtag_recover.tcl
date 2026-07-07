# jtag_recover.tcl — reconnect, capture state if halted, clear breakpoints, RESUME.
set host [expr {$argc >= 1 ? [lindex $argv 0] : "TCP:127.0.0.1:3121"}]
connect -url $host
targets -set -filter {name =~ "ARM*#0"}
puts ">> state before recovery:"
if {[catch {puts [rrd pc]} e]} { puts ">> rrd pc failed: $e" }
catch { puts [rrd r0]; puts [rrd r1]; puts [rrd r2] }
puts ">> clearing breakpoints"
catch { bpremove -all }
puts ">> resuming core"
catch { con }
after 300
puts ">> recover done"
