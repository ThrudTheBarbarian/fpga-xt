# floorplan_probe.tcl — read-only placement-landscape report over a routed dcp.
# Usage: vivado -mode batch -source floorplan_probe.tcl -tclargs <post_route.dcp>
# Answers: which clock regions hold how much BRAM/SLICE, and where each major
# subsystem actually landed + its LUT/FF/BRAM/DSP footprint.  No design change.

set dcp [lindex $argv 0]
open_checkpoint $dcp

puts "================ CLOCK REGION CAPACITY ================"
foreach cr [lsort [get_clock_regions]] {
    set sl [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ SLICE*}]]
    set br [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ RAMB36*}]]
    set ds [llength [get_sites -quiet -of_objects [get_clock_regions $cr] -filter {SITE_TYPE =~ DSP*}]]
    puts [format "  %-8s SLICE=%4d  RAMB36=%3d  DSP=%3d" $cr $sl $br $ds]
}

proc fp {inst} {
    set leaves [get_cells -quiet -hier -filter "PRIMITIVE_LEVEL == LEAF && NAME =~ ${inst}/*"]
    set n [llength $leaves]
    if {$n == 0} { return "  (no cells)" }
    set lut [llength [filter $leaves {REF_NAME =~ LUT*}]]
    set ff  [llength [filter $leaves {REF_NAME =~ FD*}]]
    set br  [llength [filter $leaves {REF_NAME =~ RAMB*}]]
    set ds  [llength [filter $leaves {REF_NAME =~ DSP*}]]
    set crs [lsort -unique [get_property -quiet CLOCK_REGION [get_sites -quiet -of_objects $leaves]]]
    return [format "leaves=%5d LUT=%5d FF=%5d BRAM=%3d DSP=%2d  regions={%s}" $n $lut $ff $br $ds $crs]
}

puts "================ TOP-LEVEL INSTANCES ================"
foreach inst [lsort [get_cells -quiet -filter {PRIMITIVE_LEVEL != LEAF}]] {
    puts [format "%-26s %s" $inst [fp $inst]]
}

puts "================ ANTIC INTERNALS ================"
foreach inst {u_antic_top/u_compositor u_antic_top/u_color_resolver \
              u_antic_top/u_dl_parser u_antic_top/u_vbeam} {
    puts [format "%-30s %s" $inst [fp $inst]]
}

puts "================ EXISTING PBLOCKS ================"
foreach pb [get_pblocks -quiet] {
    set cells [get_cells -quiet -of_objects [get_pblocks $pb]]
    puts "  $pb : grid=[get_property -quiet GRID_RANGES [get_pblocks $pb]]  cells={$cells}"
}

puts "================ clk_sally CRITICAL CELLS -> region ================"
# where the worst clk_sally path endpoints sit
foreach c {u_sally_mem/stack_mem_reg u_sally_mem/g_page_cache.u_page_cache/state_q_reg[0]} {
    set cc [get_cells -quiet $c]
    if {[llength $cc]} {
        puts "  $c -> [get_property -quiet CLOCK_REGION [get_sites -quiet -of_objects $cc]]"
    }
}
puts ">> probe done"
