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

# ---- Suppress structural noise warnings ---------------------------------
# These come from intentional design choices, not real issues:
#   Synth 8-7129 — unconnected ports on zynq_ps_hp_stub (it's an OOC
#                  responder; doesn't model unused AXI HP signals).
#                  Real PS BD replaces it for the bit flow.
#   Synth 8-7071 — unconnected complement (*B) outputs of MMCME2_BASE
#                  (CLKFBOUTB, CLKOUT0B, ...).  Vendor primitive ports
#                  we don't need.
#   Synth 8-7023 — "N connections declared, M given" — same MMCM
#                  unused-port story, just a different message.
#   Synth 8-3917 — top-level port driven by constant.  uart_tx is tied
#                  high (PL UART vestigial, real UART through PS MIO),
#                  dbg[3] tied low (no carrier-board pin).  Both are
#                  intentional, not bugs.
set_msg_config -id "Synth 8-7129" -suppress
set_msg_config -id "Synth 8-7071" -suppress
set_msg_config -id "Synth 8-7023" -suppress
set_msg_config -id "Synth 8-3917" -suppress

# ---- Helper: append a file to an .xsa archive (which is just a zip) -----
# Linux/macOS use `zip -j` (junk paths so files land at the archive root).
# Windows has no `zip` binary by default; 7-Zip is available — run it
# from the file's parent dir with just the basename so only the leaf
# name is stored in the archive (matches `zip -j` semantics).
proc xsa_inject {xsa_path src} {
    if {$::tcl_platform(platform) eq "windows"} {
        # Vivado bundles an Info-ZIP at <vivado>/../tps/win64/zip/bin/zip.exe.
        # We use it rather than the WindowsApps `7z` stub or PowerShell's
        # Compress-Archive: the former isn't on Vivado's `exec` PATH and
        # the latter is awkward to drive through Tcl's quoting.
        set zip_exe [file normalize \
            [file join $::env(XILINX_VIVADO) .. tps win64 zip bin zip.exe]]
        if {![file exists $zip_exe]} {
            error "xsa_inject: bundled zip.exe not found at $zip_exe"
        }
        set rc [catch {exec $zip_exe -j $xsa_path $src} result]
        if {$rc != 0} {
            error "xsa_inject: zip failed for [file tail $src] -- $result"
        }
    } else {
        exec zip -j $xsa_path $src
    }
}

# ---- Read sources -------------------------------------------------------
# Pull in every .sv from hdl/ that isn't a sim-only mock.  The Efinix-
# era HyperRAM / HDMI chains are gone from hdl/ entirely (commits
# 2f3f03e + 614f2f9 + this commit's Phase B), so no explicit module
# exclusions are needed any more.
set hdl_dir [file join [pwd] hdl]

set sv_files {}
foreach f [glob -nocomplain [file join $hdl_dir *.sv]] {
    set name [file tail $f]
    if {[string match "*_mock.sv" $name]} { continue }
    lappend sv_files $f
}
# The xt6502 core (the only CPU) lives in hdl/xt6502/.
foreach f [glob -nocomplain [file join $hdl_dir xt6502 *.sv]] {
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
    if {$flow eq "bit" && $name eq "ooc_only.xdc"} {
        puts ">> skipping OOC-only constraints (bit flow): $name"
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
# Verilog define: USE_PS_BD (real PS BD, bit flow only).
set synth_defines {}
if {$flow eq "bit"} { lappend synth_defines USE_PS_BD }
lappend synth_defines TRNG_SYNTH   ;# xt_trng: real ring oscillators (sim uses the LFSR stand-in)
if {$flow eq "bit"} {
    synth_design -top $top -part $part -include_dirs $include_dirs \
                 -verilog_define $synth_defines
} elseif {[llength $synth_defines] > 0} {
    synth_design -mode out_of_context \
                 -top $top -part $part -include_dirs $include_dirs \
                 -verilog_define $synth_defines
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

    # ---- Incremental implementation (opt-in) --------------------------------
    # Reuse a prior routed checkpoint as the placement/routing reference so that
    # only the changed logic re-places/re-routes — deterministic ~minutes builds
    # instead of a fresh full-die dice-roll (architecture-review §1.2).  Off by
    # default (a fresh build ignores it); enable by pointing INCR_REF_DCP at a
    # known-good post_route.dcp (typically build/post_route.dcp from the last
    # green build).  Must run after opt_design, before place_design.
    if {[info exists ::env(INCR_REF_DCP)] && $::env(INCR_REF_DCP) ne ""} {
        set ref_dcp $::env(INCR_REF_DCP)
        if {[file exists $ref_dcp]} {
            # -directive TimingClosure: the incremental flow otherwise substitutes its own
            # RuntimeOptimized effort for the whole implementation — it reuses placement but
            # optimises the changed/re-routed portion lightly, which is exactly how a 3 ps
            # inherited margin dies (clk_sally +0.003 reference -> -0.371 incremental,
            # measured 2026-07-15 with 98.8% cell reuse).
            set incr_dir TimingClosure
            if {[info exists ::env(INCR_DIRECTIVE)] && $::env(INCR_DIRECTIVE) ne ""} {
                set incr_dir $::env(INCR_DIRECTIVE)
            }
            puts ">> incremental impl: reference checkpoint $ref_dcp (directive $incr_dir)"
            read_checkpoint -incremental -directive $incr_dir $ref_dcp
        } else {
            puts ">> WARNING: INCR_REF_DCP=$ref_dcp not found — full (non-incremental) build"
        }
    }

    # ExtraTimingOpt: extra timing-driven placement effort.  The clk_sally
    # critical path (sally_mem BRAM -> CPU bank/ALU) is route-bound after the
    # cascade fix — the BRAMs drift away from their consuming logic inside the
    # pblock.  ExtraTimingOpt pulls them tighter; pure placement, no RTL.
    # Overridable (PLACE_DIRECTIVE env) to retry a different placement when
    # clk_sally lands on the marginal side at 120 MHz (e.g. Explore) — the
    # non-project flow's "different seed".
    set place_dir ExtraTimingOpt
    if {[info exists ::env(PLACE_DIRECTIVE)] && $::env(PLACE_DIRECTIVE) ne ""} {
        set place_dir $::env(PLACE_DIRECTIVE)
    }
    puts ">> place_design -directive $place_dir"
    place_design -directive $place_dir
    # phys_opt_design runs after placement and applies physical optimisations
    # (e.g., replicating high-fanout drivers near their loads, retiming small
    # bits of logic across registers).  Often recovers 0.1-0.3 ns on marginal
    # paths with zero RTL cost — added 2026-05-16 when xt_blitter's cx_reg
    # CARRY4 chain flipped negative after adding the sally_mem stack BRAM.
    phys_opt_design
    route_design
    # Post-route phys_opt — recovers sub-ns slack on routing-bound paths
    # that survive route_design (e.g., the sprite compositor's BRAM→tree
    # path where the logic levels are small but routing dominates).
    phys_opt_design -directive AggressiveExplore
    # Re-run route_design after phys_opt so routing — and its hold-fix pass —
    # is the LAST step.  This only re-routes (placement/netlist from phys_opt
    # are preserved), so the setup gains stay while hold is cleaned up.
    # (Added 2026-05-22 after the sally_mem defrag exposed a clk_sys hold
    # violation in xt_blitter.)
    route_design
    # Setup recovery.  After cascade_height + HP-on-clk_sys + ExtraTimingOpt,
    # the residual clk_sys/clk_sally misses are sub-0.05 ns on paths whose DATA
    # delay is already under budget — i.e. routing/clock-skew, placer-variance
    # sized.  Iterate setup-focused phys_opt + route a few more times to squeeze
    # them positive.  Hold is met by this point, so this runs before (and does
    # not fight) the hold loop below.
    proc _worst_setup_ns {} {
        set p [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
        if {[llength $p] == 0} { return 999.0 }
        return [get_property SLACK [lindex $p 0]]
    }
    set wns [_worst_setup_ns]
    for {set sp 0} {$sp < 3 && $wns < 0} {incr sp} {
        puts ">> setup recovery pass [expr {$sp + 1}] (WNS = $wns ns) — phys_opt + route"
        phys_opt_design -directive AggressiveExplore
        route_design
        set wns [_worst_setup_ns]
    }
    puts ">> final worst setup slack: $wns ns"
    # Hold recovery.  The AggressiveExplore phys_opt above is setup-focused
    # and can leave residual hold (min-delay) violations that the single
    # route pass doesn't fully clean up.  If hold is still negative, run
    # balanced phys_opt (which includes hold fixing) + route again, up to
    # 5 times.  (Note: xt_blitter's LUT2 AND buffers on pat_mem/font_mem DI
    # handle the worst 0-logic-level FF→BRAM paths; the loop cleans up
    # any remaining cmd_fifo or other BRAM DI paths.)
    proc _worst_hold_ns {} {
        set p [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
        if {[llength $p] == 0} { return 999.0 }
        return [get_property SLACK [lindex $p 0]]
    }
    set whs [_worst_hold_ns]
    for {set hp 0} {$hp < 5 && $whs < 0} {incr hp} {
        puts ">> hold recovery pass [expr {$hp + 1}] (WHS = $whs ns) — phys_opt + route"
        phys_opt_design
        route_design
        set whs [_worst_hold_ns]
    }
    puts ">> final worst hold slack: $whs ns"
    # Final setup re-recovery.  On the xt6502 netlist the hold loop's balanced
    # phys_opt + route can drag setup back negative after the setup loop had
    # recovered it (the two fight on the CPU's cycle-locked addr path).  Re-run
    # setup-focused phys_opt + route a couple more times so the achieved setup
    # sticks.
    set wns [_worst_setup_ns]
    for {set fp 0} {$fp < 3 && $wns < 0} {incr fp} {
        puts ">> final setup re-recovery pass [expr {$fp + 1}] (WNS = $wns ns) — phys_opt + route"
        phys_opt_design -directive AggressiveExplore
        route_design
        set wns [_worst_setup_ns]
    }
    puts ">> post-hold final worst setup slack: $wns ns"
    write_checkpoint -force [file join $out_dir post_route.dcp]
    report_utilization -file [file join $out_dir post_route_util.rpt]
    report_timing_summary -file [file join $out_dir post_route_timing.rpt]
    report_drc -file [file join $out_dir post_route_drc.rpt]

    # CDC report + timing gate: abort before write_bitstream on negative WNS
    # (override with TIMING_GATE_ALLOW_NEG=1).  See vivado/scripts/timing_gate.tcl.
    # A genuine negative-WNS result re-throws to fail the build; a missing/broken
    # gate script only warns (never discard a routed design over gate plumbing).
    set gate_tcl [file join [pwd] scripts timing_gate.tcl]
    if {[file exists $gate_tcl]} {
        source $gate_tcl
        if {[catch {fpgaxt_timing_gate $out_dir} gate_err]} {
            if {[string match {*timing gate FAILED*} $gate_err]} { error $gate_err }
            puts ">> WARNING: timing gate plumbing error (ignored): $gate_err"
        }
    } else {
        puts ">> WARNING: $gate_tcl not found — timing gate skipped."
    }

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
    # See xsa flow below for the same `-minimal` justification — Vivado
    # 2025.2.1's auto write_mem_info trips on our sub-BD PS layout.
    write_hw_platform -fixed -force -minimal $xsa_path
    puts ">> hw_platform written: $xsa_path"

    # ---- ps7_init.* post-injection ------------------------------------
    # Vitis 2025.x's zynq_fsbl template wants ps7_init.c at the XSA root,
    # but `write_hw_platform -fixed` doesn't pull the files into the
    # archive even though the BD has them on disk in its .gen tree.
    # Inject them by hand — the XSA is just a zip archive, so `zip -j`
    # appends the files at the root with no path prefix.
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
            xsa_inject $xsa_path $src
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
    # `-minimal` skips Vivado 2025.2.1's auto write_mem_info step, which
    # otherwise blows up with Common 17-69 when the PS lives inside a
    # sub-BD rather than at top level.  We don't use updatemem (Zynq
    # code runs from DDR3, not BRAM), so the .mmi is irrelevant; the
    # tradeoff is that the bitstream is no longer bundled in the XSA
    # — Vitis flows that need it load <build>/fpga_xt_top.bit directly
    # via JTAG / bootgen.
    write_hw_platform -fixed -force -minimal $xsa_path
    puts ">> hw_platform written: $xsa_path"

    # Same ps7_init.* injection as the bit flow above.
    set ps_ip_dir [file join [pwd] bd zynq_ps_bd zynq_ps_bd.gen \
                              sources_1 bd ps_bd ip ps_bd_zynq_ps_0]
    foreach f {ps7_init.c ps7_init.h ps7_init_gpl.c ps7_init_gpl.h
               ps7_init.tcl ps7_init.html} {
        set src [file join $ps_ip_dir $f]
        if {[file exists $src]} {
            xsa_inject $xsa_path $src
        }
    }
    puts ">> ps7_init.* injection complete"
}

puts ">> done"
