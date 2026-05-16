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

# Constraints — XDC files in vivado/constraints/.
# For bitstream flow, load all XDC files including board pin constraints.
# For OOC synth/impl flows (no IO buffers), skip board-level XDC to avoid
# Place 30-188 (UnBuffered IOs) errors.
foreach f [glob -nocomplain [file join [pwd] constraints *.xdc]] {
    set name [file tail $f]
    if {$flow ne "bit" && $name eq "zturn_board.xdc"} {
        puts ">> skipping board constraints (OOC): $name"
        continue
    }
    puts ">> reading constraints: $f"
    read_xdc $f
}

# ---- PS block design sources (bitstream flow only) --------------------------
# The pre-generated Zynq PS BD provides DDR3, MIO (UART, SD, etc.), and HP
# AXI3 slave ports that our PL masters (fb_scanout, xt_blitter) connect to.
# For OOC synth/impl flows the zynq_ps_hp_stub.sv AXI responder is used
# instead — no PS BD required.
#
# We read the pre-generated synthesis netlists directly instead of using
# read_bd + generate_target.  This avoids IP-locking issues that occur when
# a BD created in a prior Vivado session is read in non-project mode.
if {$flow eq "bit"} {
    # Two-pronged BD ingest for non-project-mode synthesis:
    #
    #   1. read_verilog on the BD's pre-generated *.v files — gives
    #      the synth elaborator concrete module bodies (the BD's
    #      out-of-context cached netlists).  Without this, synth
    #      hits 'module ps_bd_zynq_ps_0 not found'.
    #
    #   2. read_bd on the .bd file — adds the BD-level metadata
    #      (PS register config, address map, HWH file) to the
    #      design.  Required for write_hw_platform to emit a
    #      Vitis-consumable XSA; without it the XSA is just the
    #      bitstream with empty handoff data.
    #
    # Both BD and build run Vivado 2025.2.x so the IP-locking risk
    # that originally motivated reading source files directly no
    # longer applies.
    set bd_gen  [file join [pwd] bd zynq_ps_bd zynq_ps_bd.gen sources_1 bd ps_bd]
    set bd_path [file join [pwd] bd zynq_ps_bd zynq_ps_bd.srcs sources_1 bd ps_bd ps_bd.bd]

    set ps_files {}
    lappend ps_files [file join $bd_gen ipshared 4b52 hdl verilog processing_system7_v5_5_trace_buffer.v]
    lappend ps_files [file join $bd_gen ipshared 4b52 hdl verilog processing_system7_v5_5_w_atc.v]
    lappend ps_files [file join $bd_gen ipshared 4b52 hdl verilog processing_system7_v5_5_b_atc.v]
    lappend ps_files [file join $bd_gen ipshared 4b52 hdl verilog processing_system7_v5_5_aw_atc.v]
    lappend ps_files [file join $bd_gen ipshared 4b52 hdl verilog processing_system7_v5_5_atc.v]
    lappend ps_files [file join $bd_gen ip ps_bd_zynq_ps_0 hdl verilog processing_system7_v5_5_processing_system7.v]
    lappend ps_files [file join $bd_gen ip ps_bd_zynq_ps_0 synth ps_bd_zynq_ps_0.v]
    lappend ps_files [file join $bd_gen synth ps_bd.v]

    set ps_ok 1
    foreach f $ps_files {
        if {[file exists $f]} {
            puts ">> reading PS source: $f"
            read_verilog $f
        } else {
            puts ">> WARNING: missing PS source: $f"
            set ps_ok 0
        }
    }

    if {[file exists $bd_path]} {
        puts ">> read_bd (for handoff metadata): $bd_path"
        read_bd $bd_path
    } else {
        puts ">> WARNING: $bd_path missing — XSA will lack HWH metadata."
        set ps_ok 0
    }

    if {$ps_ok} {
        puts ">> PS BD ready for synthesis + handoff."
    } else {
        puts ">> WARNING: some PS BD ingest steps failed."
        puts ">> Run vivado/bd/gen_ps_bd.tcl to regenerate the BD."
        puts ">> Bitstream build will proceed without PS block — DDR and"
        puts ">> FIXED_IO ports will be unconnected."
    }
}

# Parallel threads: default 8 (good for 16-core / 64 GB win10 build host).
# Override via MAX_THREADS env var when running on a smaller box — the old
# ubuntu host had 15 GB RAM and needed MAX_THREADS=2 to avoid swapping
# (7+ workers × 1.3 GB RSS).
set max_threads 8
if {[info exists ::env(MAX_THREADS)]} { set max_threads $::env(MAX_THREADS) }
puts ">> maxThreads=$max_threads"
set_param general.maxThreads $max_threads

# ---- Synthesis ----------------------------------------------------------
# Out-of-context mode for synth/impl flows: standalone fmax probe doesn't
# need IO placement (OOC skips IO buf inference + IO placement, so timing
# measures internal logic delay only).
#
# For the bit flow we use full (non-OOC) synthesis so I/O buffers are
# inferred and the design can be packaged into a bitstream.  We also pass
# -verilog_define USE_PS_BD so fpga_xt_top selects the real ps_bd_wrapper
# over the OOC AXI stub.
if {$flow eq "bit"} {
    synth_design -top $top -part $part -include_dirs $include_dirs \
                 -verilog_define USE_PS_BD
} else {
    synth_design -mode out_of_context \
                 -top $top -part $part -include_dirs $include_dirs
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $out_dir post_synth_util.rpt]
report_timing_summary -file [file join $out_dir post_synth_timing.rpt]
puts ">> synth complete"

# ---- Implementation -----------------------------------------------------
if {$flow eq "impl" || $flow eq "bit"} {
    opt_design
    place_design
    # phys_opt_design runs after placement and applies physical optimisations
    # (e.g., replicating high-fanout drivers near their loads, retiming small
    # bits of logic across registers).  Often recovers 0.1-0.3 ns on marginal
    # paths with zero RTL cost — added 2026-05-16 when xt_blitter's cx_reg
    # CARRY4 chain flipped negative after adding the sally_mem stack BRAM.
    phys_opt_design
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

    # ---- Hardware handoff for Vitis ------------------------------------
    # `.xsa` (Xilinx Shell Archive) is the artefact Vitis consumes to
    # generate the BSP / FSBL / platform.  `-fixed` says "no DFX, no
    # PR regions" — appropriate for a plain Zynq-7000 bare-metal flow.
    # `-include_bit` bundles the bitstream so a single .xsa fully
    # describes the hardware platform.  The filename argument is
    # positional (UG835 — no `-file` switch).  See docs/bring-up.md.
    set xsa_path [file join $out_dir $top.xsa]
    write_hw_platform -fixed -force -include_bit $xsa_path
    puts ">> hw_platform written: $xsa_path"

    # ---- ps7_init.* post-injection ------------------------------------
    # Vitis 2025.x's zynq_fsbl template wants ps7_init.c at the XSA root,
    # but `write_hw_platform -fixed -include_bit` doesn't pull the file
    # into the archive even though the BD has it on disk in its .gen
    # tree.  Inject them by hand — the XSA is just a zip archive, so
    # `zip -j` appends the files at the root with no path prefix.
    set ps_ip_dir [file join [pwd] bd zynq_ps_bd zynq_ps_bd.gen \
                              sources_1 bd ps_bd ip ps_bd_zynq_ps_0]
    set ps_init_files [list \
        ps7_init.c   ps7_init.h \
        ps7_init_gpl.c ps7_init_gpl.h \
        ps7_init.tcl ps7_init.html]
    set added 0
    foreach f $ps_init_files {
        set src [file join $ps_ip_dir $f]
        if {[file exists $src]} {
            exec zip -j $xsa_path $src
            incr added
        } else {
            puts ">> WARNING: ps_init source missing: $src"
        }
    }
    puts ">> injected $added ps7_init.* files into $xsa_path"
}

# ---- XSA-only flow -----------------------------------------------------
# Quick re-emit of the .xsa from an existing post_route checkpoint.
# Avoids re-running place+route just to refresh the Vitis handoff
# after a script tweak.  Requires that a previous "bit" flow ran
# (otherwise post_route.dcp doesn't exist).  Wall time: ~30 s.
if {$flow eq "xsa"} {
    set dcp_path [file join $out_dir post_route.dcp]
    if {![file exists $dcp_path]} {
        puts stderr "ERROR: $dcp_path missing — run the 'bit' flow first."
        exit 1
    }
    open_checkpoint $dcp_path
    set xsa_path [file join $out_dir $top.xsa]
    write_hw_platform -fixed -force -include_bit $xsa_path
    puts ">> hw_platform written: $xsa_path"

    # Same ps7_init.* injection as the bit flow above.
    set ps_ip_dir [file join [pwd] bd zynq_ps_bd zynq_ps_bd.gen \
                              sources_1 bd ps_bd ip ps_bd_zynq_ps_0]
    foreach f {ps7_init.c ps7_init.h ps7_init_gpl.c ps7_init_gpl.h
               ps7_init.tcl ps7_init.html} {
        set src [file join $ps_ip_dir $f]
        if {[file exists $src]} {
            exec zip -j $xsa_path $src
        }
    }
    puts ">> ps7_init.* injection complete"
}

puts ">> done"
