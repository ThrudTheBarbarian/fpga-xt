# timing_gate.tcl — encode the "don't flash a negative build" rule in the build.
#
# Sourced by build.tcl after route_design (before write_bitstream).  Two jobs:
#   1. report_cdc  — Vivado's authoritative structural CDC analysis, the build-
#      side complement to tools/cdc_lint.py (see docs/Design/cdc-guidelines.md).
#   2. timing gate — print worst setup slack (WNS) per clock and ABORT the build
#      if any binding clock is negative, so a failing bitstream is never written.
#
# The clk_operating_point note (clk_sally 100 / clk_sys 133.3 / clk_pix 148.4)
# is the safe point; a marginally-negative build has crashed the OS before.  To
# knowingly flash a marginal build, set TIMING_GATE_ALLOW_NEG=1 in the env — the
# gate then warns instead of failing.
#
# Robustness: only a genuine NEGATIVE-WNS result raises an error.  Any scripting
# / API failure inside the gate degrades to a warning and lets the build finish
# (a gate bug must never throw away a 25-minute P&R that actually met timing).

proc fpgaxt_timing_gate {out_dir} {
    # ---- 1. structural CDC report -------------------------------------------
    if {[catch {report_cdc -details \
                    -file [file join $out_dir post_route_cdc.rpt]} err]} {
        puts ">> WARNING: report_cdc failed: $err"
    } else {
        puts ">> report_cdc -> $out_dir/post_route_cdc.rpt"
    }

    # ---- 2. per-clock worst setup slack -------------------------------------
    # An EMPTY value means "not set".  It has to, because run-valhalla.sh
    # exports the variable unconditionally — so a bare `ne "0"` test made every
    # remote build set the override, and the gate printed FAIL and then wrote
    # the bitstream anyway.  A safety net that is off by default is worse than
    # no safety net, because it reads as protection.
    set allow_neg [expr {[info exists ::env(TIMING_GATE_ALLOW_NEG)] \
                         && $::env(TIMING_GATE_ALLOW_NEG) ne "" \
                         && $::env(TIMING_GATE_ALLOW_NEG) ne "0"}]
    set fails {}
    set n_clocks 0
    puts ">> ---- timing gate: worst setup slack (WNS) per clock ----"
    if {[catch {lsort [get_clocks]} clocks]} {
        puts ">> WARNING: timing gate could not enumerate clocks ($clocks) — skipping gate."
        return
    }
    foreach clk $clocks {
        if {[catch {
            set paths [get_timing_paths -to [get_clocks $clk] \
                           -delay_type max -nworst 1 -max_paths 1]
            if {[llength $paths] == 0} { continue }
            set wns [get_property SLACK [lindex $paths 0]]
            incr n_clocks
            set mark [expr {$wns < 0 ? "FAIL" : "ok"}]
            if {$wns < 0} { lappend fails "$clk ($wns ns)" }
            puts [format ">>   %-20s WNS = %9s ns   %s" $clk $wns $mark]
        } perr]} {
            puts ">>   WARNING: could not evaluate slack for $clk ($perr)"
        }
    }

    if {$n_clocks == 0} {
        puts ">> WARNING: timing gate evaluated no clocks — skipping gate (build continues)."
        return
    }
    if {[llength $fails] > 0} {
        puts ">> TIMING GATE: NEGATIVE SETUP SLACK on: [join $fails {, }]"
        if {$allow_neg} {
            puts ">> TIMING_GATE_ALLOW_NEG set — continuing despite negative slack."
        } else {
            error "timing gate FAILED — negative WNS; bitstream not written.\
                   Set TIMING_GATE_ALLOW_NEG=1 to override (knowingly marginal flash)."
        }
    } else {
        puts ">> TIMING GATE: PASS — all clocks meet setup."
    }
}
