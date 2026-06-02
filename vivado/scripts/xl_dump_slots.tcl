# xl_dump_slots.tcl — dump the READY-cell rows of all 3 XL triple-buffer slots
# from DDR over JTAG, for offline comparison (writeback-vs-scanout triage).
#
# This is the GENTLE diagnostic: a single mrd pass per slot, no fpga -file, no
# ps7_init, no gp0 write.  Safe on a live SD-booted board.  (The PS-REPL wedge
# seen earlier came from *repeated* A9 reads of the diag counters, not from a
# one-shot DDR dump like this.)
#
# Reads buffer rows 8..15 (the READY character cell): offset 8*1280 = 0x2800,
# 8 rows * 320 words = 2560 words per slot.  Slots at 0x3100/3110/3120_0000.
#
# Result (2026-06-02): in THIS sample all 3 slots were byte-identical with
# glyphs at the correct rows.  That is one arbitrary instant (the JTAG read is
# async to the frame and only sees whichever frames are resident in the 3
# slots) — for an INTERMITTENT fault it shows "no error captured here", NOT
# "the writeback never misses".  It cannot exonerate the writeback.  To catch
# an intermittent miss you need an accumulating detector (the overrun/abort
# counters) or an ILA triggered on the event — not a one-shot dump.
#
# Usage:  xsdb xl_dump_slots.tcl   (then scp C:/Users/user/fpga/xl_dump3.txt back)

connect -url TCP:127.0.0.1:3121
configparams force-mem-accesses 1
catch {jtag targets}
targets -set -filter {name =~ "*Cortex-A9*#0"}
set f [open "C:/Users/user/fpga/xl_dump3.txt" w]
foreach base {0x31002800 0x31102800 0x31202800} {
    puts $f "SLOT $base"
    foreach v [mrd -force -value $base 2560] { puts $f $v }
}
close $f
puts ">> dumped 3 slots x 2560 words to xl_dump3.txt"
