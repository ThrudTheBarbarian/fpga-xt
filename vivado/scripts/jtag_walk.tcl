# jtag_walk.tcl — READ-ONLY page-table walk. Given an L1 table base and a VA,
# walk L1->L2->physical and dump the mapped frame's content, plus the identity
# copy at the same VA (image region is identity, so VA==PA for the template).
# Resolves "process reads garbage" = bad frame (mapped phys dirty) vs stale-TLB
# (mapped phys clean, but the CPU's TLB pointed elsewhere).
#
# Usage: xsct jtag_walk.tcl <l1base_hex> <va_hex> [host]
#   e.g. xsct jtag_walk.tcl 0x00b10000 0x0292d934

set l1base [lindex $argv 0]
set va     [lindex $argv 1]
set host   [expr {$argc >= 3 ? [lindex $argv 2] : "TCP:127.0.0.1:3121"}]

connect -url $host
targets -set -filter {name =~ "ARM*#0"}

proc rd1 {a} { return [lindex [mrd -force $a 1] end] }

set l1i   [expr {($va >> 20) & 0xfff}]
set l1a   [expr {$l1base + $l1i*4}]
set l1e   0x[rd1 $l1a]
puts [format ">> VA=0x%08x  L1\[0x%x\]@0x%08x = 0x%08x" $va $l1i $l1a $l1e]

if {($l1e & 0x3) == 0x1} {
    set l2base [expr {$l1e & 0xfffffc00}]
    set l2i    [expr {($va >> 12) & 0xff}]
    set l2a    [expr {$l2base + $l2i*4}]
    set l2e    0x[rd1 $l2a]
    puts [format ">> coarse L2 base=0x%08x  L2\[0x%x\]@0x%08x = 0x%08x" $l2base $l2i $l2a $l2e]
    set phys [expr {($l2e & 0xfffff000) | ($va & 0xfff)}]
    puts [format ">> mapped PHYS = 0x%08x" $phys]
    puts ">> mapped-frame content @ [format 0x%08x [expr {$phys & 0xfffffff0}]] (8 words):"
    puts [mrd -force [expr {$phys & 0xfffffff0}] 8]
} else {
    puts [format ">> L1 is NOT coarse (type %d) — section base 0x%08x" [expr {$l1e & 3}] [expr {$l1e & 0xfff00000}]]
}
puts ">> identity/template @ [format 0x%08x [expr {$va & 0xfffffff0}]] (8 words):"
puts [mrd -force [expr {$va & 0xfffffff0}] 8]
puts ">> walk done"
