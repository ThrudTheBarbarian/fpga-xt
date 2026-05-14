# build.tcl — non-project-mode Vivado build for fpga-antic on Zynq-7020.
#
# Invoked by vivado/run.sh:
#   vivado -mode batch -source build.tcl -tclargs <flow> <top> <part>
#
# Flow ∈ {synth, impl, bit}:
#   synth — run synthesis only; write post-synth checkpoint + utilisation
#   impl  — synth, then opt/place/route; write post-route checkpoint
#   bit   — full flow including bitstream generation
#
# Top module: Phase 0 default is sally_synth_top (SALLY stack only —
# probes fmax in isolation, no antic_top / no Atari I/O / no peripheral
# pads). Later phases extend the top to include antic_top and the new
# Zynq-specific Atari-I/O wrapper.
#
# Part: xc7z020-2clg400 (Z-Turn full SOM). Override via -tclargs.

if {[llength $argv] < 3} {
    puts "Usage: vivado -mode batch -source build.tcl -tclargs <flow> <top> <part>"
    exit 1
}

set flow [lindex $argv 0]
set top  [lindex $argv 1]
set part [lindex $argv 2]

set out_dir [file join [pwd] build]
file mkdir $out_dir

puts ">> flow=$flow top=$top part=$part"

# ---- Read sources -------------------------------------------------------
# Phase 0 source-list strategy: pull in every .sv from hdl/ that isn't a
# sim-only mock or an Efinix-specific vendor IP (HyperRAM PHY, etc.).
# Synthesis will complain about anything that doesn't elaborate cleanly;
# we use the error log to identify what needs porting next.
set hdl_dir [file join [pwd] hdl]

# SystemVerilog files — exclude sim-only mocks, Efinix-specific
# vendor cores (HyperRAM PHY), and the v1 HyperRAM-era cache modules
# (replaced by banked_axi_reader per sally-mem-v2.md).
set sv_files {}
foreach f [glob -nocomplain [file join $hdl_dir *.sv]] {
    set name [file tail $f]
    if {[string match "*_mock.sv" $name]} { continue }
    if {[string match "hyperram_*" $name]} { continue }
    if {$name eq "bank_cache.sv"}      { continue }
    if {$name eq "cache_line_ram.sv"}  { continue }
    if {$name eq "mem_read_mux.sv"}    { continue }
    lappend sv_files $f
}
# Also pick up sally_core.sv (and any other .sv) under hdl/sally/.
foreach f [glob -nocomplain [file join $hdl_dir sally *.sv]] {
    lappend sv_files $f
}

# Verilog files (sally ALU + cpu, etc.)
set v_files [glob -nocomplain [file join $hdl_dir *.v]]
foreach f [glob -nocomplain [file join $hdl_dir sally *.v]] {
    lappend v_files $f
}

# Includes (bus_opcodes.vh)
set include_dirs [list $hdl_dir]

puts ">> reading [llength $sv_files] .sv files, [llength $v_files] .v files"

foreach f $sv_files { read_verilog -sv $f }
foreach f $v_files  { read_verilog     $f }

# Constraints — XDC files in vivado/constraints/. Optional in Phase 0.
foreach f [glob -nocomplain [file join [pwd] constraints *.xdc]] {
    puts ">> reading constraints: $f"
    read_xdc $f
}

# ---- Synthesis ----------------------------------------------------------
# Out-of-context mode: standalone synth probe doesn't need IO placement
# (sally_synth_top has 173 top-level pads with the v2a AXI port; CLG400
# only has 125 user IO). OOC skips IO buf inference + IO placement, so
# the timing report measures internal logic delay only — exactly what
# we want for an fmax probe.
synth_design -mode out_of_context \
             -top $top -part $part -include_dirs $include_dirs
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $out_dir post_synth_util.rpt]
report_timing_summary -file [file join $out_dir post_synth_timing.rpt]
puts ">> synth complete"

# ---- Implementation -----------------------------------------------------
if {$flow eq "impl" || $flow eq "bit"} {
    opt_design
    place_design
    route_design
    write_checkpoint -force [file join $out_dir post_route.dcp]
    report_utilization -file [file join $out_dir post_route_util.rpt]
    report_timing_summary -file [file join $out_dir post_route_timing.rpt]
    report_drc -file [file join $out_dir post_route_drc.rpt]
    puts ">> impl complete"
}

# ---- Bitstream ----------------------------------------------------------
if {$flow eq "bit"} {
    write_bitstream -force [file join $out_dir $top.bit]
    puts ">> bitstream written: $out_dir/$top.bit"
}

puts ">> done"
