# jtag_klog.tcl — dump the kernel message ring over JTAG (no UART on this rig).
set host [expr {$argc >= 1 ? [lindex $argv 0] : "TCP:127.0.0.1:3121"}]
set base [expr {$argc >= 2 ? [lindex $argv 1] : 0x01109480}]
set head [expr {$argc >= 3 ? [lindex $argv 2] : 0x01100fa8}]
set nw   [expr {$argc >= 4 ? [lindex $argv 3] : 2048}]
connect -url $host
targets -set -filter {name =~ "ARM*#0"}
puts ">> head/wrapped:"
catch { puts [mrd $head 2] }
puts ">> klog:"
set out ""
for {set off 0} {$off < $nw} {incr off 256} {
    if {[catch {set w [mrd -value [expr {$base + $off*4}] 256]} e]} { puts ">> mrd failed: $e"; break }
    foreach v $w {
        for {set b 0} {$b < 4} {incr b} {
            set c [expr {($v >> ($b*8)) & 0xFF}]
            if {$c == 10} { append out "\n" } elseif {$c >= 32 && $c < 127} { append out [format %c $c] }
        }
    }
}
puts $out
puts ">> klog done"
