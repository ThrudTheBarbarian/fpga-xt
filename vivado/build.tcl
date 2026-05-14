# build.tcl — non-project-mode Vivado build for fpga-xt on Zynq-7020.
#
# Invoked by vivado/run.sh:
#   vivado -mode batch -source build.tcl -tclargs <flow> <top> <part>
#
# Flow ∈ {synth, impl, bit}:
#   synth — run synthesis only; write post-synth checkpoint + utilisation
#   impl  — synth, then opt/place/route; write post-route checkpoint
#   bit   — full flow including bitstream generation
#
# Top module: Phase 1 default is fpga_xt_top (SALLY + ANTIC integrated).
# Phase 0 used sally_synth_top (SALLY stack only, standalone fmax probe).
# Override via -tclargs <flow> <top> <part>.
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
# Phase 1 source-list strategy: pull in every .sv from hdl/ that isn't a
# sim-only mock, an Efinix-specific vendor IP (HyperRAM PHY, TMDS
# serializers), or a v1 HyperRAM-era cache module (replaced by
# banked_axi_reader + bram_shim per sally-mem-v2.md).
set hdl_dir [file join [pwd] hdl]

# SystemVerilog files — exclude:
#   *_mock.sv                   — simulation-only mocks
#   hyperram_phy.sv             — Efinix HyperRAM PHY (vendor primitive)
#   tmds_serializer.sv          — Efinix OSER10 serializer (vendor primitive)
#   hdmi_out.sv                 — replaced by hdmi_out_zynq.sv (same module name,
#                                 Zynq-compatible: keeps vbeam, no TMDS serializer)
#   bank_cache.sv, cache_line_ram.sv — v1 HyperRAM cache (deleted per v2a)
#   prefetch.sv                 — v1 cache support module (unused on Zynq)
#   cache_regs.sv               — v1 cache register file (unused on Zynq)
#   bank_translator.sv          — v1 cache address translator (unused on Zynq)
#   pssi_tx.sv, pssi_bytes.sv   — N6 PSSI serial link (Efinix-era, no N6 on Zynq)
#   rp_tx.sv, rp_rx.sv         — FPGA⇄RP serial link (Efinix-era, no RP on Zynq)
#   sally_synth_top.sv          — Phase 0 standalone SALLY fmax probe top
#   cache_line_ram_synth_top.sv — Phase 0 standalone cache-bram fmax probe top
set sv_files {}
foreach f [glob -nocomplain [file join $hdl_dir *.sv]] {
    set name [file tail $f]
    if {[string match "*_mock.sv" $name]}          { continue }
    if {$name eq "hyperram_phy.sv"}                { continue }
    if {$name eq "tmds_serializer.sv"}             { continue }
    if {$name eq "hdmi_out.sv"}                    { continue }
    if {$name eq "bank_cache.sv"}                  { continue }
    if {$name eq "cache_line_ram.sv"}              { continue }
    if {$name eq "prefetch.sv"}                    { continue }
    if {$name eq "cache_regs.sv"}                  { continue }
    if {$name eq "bank_translator.sv"}             { continue }
    if {$name eq "pssi_tx.sv"}                     { continue }
    if {$name eq "pssi_bytes.sv"}                  { continue }
    if {$name eq "rp_tx.sv"}                       { continue }
    if {$name eq "rp_rx.sv"}                       { continue }
    if {$name eq "sally_synth_top.sv"}             { continue }
    if {$name eq "cache_line_ram_synth_top.sv"}    { continue }
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
