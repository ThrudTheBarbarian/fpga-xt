# Corrected per-region BRAM site query (RAMBFIFO36E1 + RAMB18E1 tiles).
open_checkpoint build/post_route.dcp

puts "==== BRAM/DSP/SLICE sites per clock region ===="
foreach cr [lsort [get_clock_regions]] {
    set b36   [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ *RAMBFIFO36* || SITE_TYPE =~ RAMB36*}]]
    set b18   [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ RAMB18* || SITE_TYPE =~ FIFO18*}]]
    set ndsp  [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ DSP48*}]]
    set nslice [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ SLICE*}]]
    puts [format "  %-8s  RAMB36tile=%-3d RAMB18=%-3d DSP=%-3d SLICE=%-5d" $cr $b36 $b18 $ndsp $nslice]
}
