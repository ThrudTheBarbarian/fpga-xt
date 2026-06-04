# jtag_load.tcl — xsct script for JTAG bring-up on the Z-Turn SOM.
#
# Loads the bitstream + initialises the PS via ps7_init.tcl + downloads
# an ELF + runs it.  This is the fast iteration path: no SD card, no
# BOOT.BIN, no FSBL — just JTAG and the Digilent HS3 (or any cable
# Vivado's hw_server recognises).
#
# Usage:
#   xsct vivado/scripts/jtag_load.tcl <bit> <elf>           # local hw_server
#   xsct vivado/scripts/jtag_load.tcl <bit> <elf> <host>    # remote hw_server
#   xsct vivado/scripts/jtag_load.tcl                       # default paths
#
# Defaults (override by passing args or setting env vars):
#   bit  = $BITSTREAM   or vivado/build/fpga_xt_top.bit
#   elf  = $ELF         or vitis/workspace/xtos/build/xtos.elf
#   host = $HW_SERVER   or TCP:127.0.0.1:3121
#
# Prerequisites:
#   1. hw_server running on the target host (Vivado starts one
#      automatically on `xsct connect` if you're on the same machine
#      as the JTAG cable; otherwise `hw_server -d` on the cable host).
#   2. JTAG cable plugged into the SOM's debug header (HS3 → 14-pin
#      JTAG; the Z-Turn carrier breaks this out near the FTDI bridge).
#   3. Power on.  Optional: hold the on-board reset until xsct is
#      ready, to avoid the PS running a random old image from QSPI.
#
# What this script does NOT do:
#   * FSBL — bring-up uses ps7_init.tcl directly via xsct; FSBL is
#     for SD/QSPI boot.  Use scripts/build_boot_bin.* once that flow
#     is on the critical path.
#   * Reset cycling — if the PS is already running an old app, run
#     `rst -system` manually before re-running this script.

# ---- Resolve paths --------------------------------------------------
set this_dir   [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $this_dir .. ..]]

set bit_path   [expr {$argc >= 1 ? [lindex $argv 0] :
                       [expr {[info exists ::env(BITSTREAM)] ? $::env(BITSTREAM) :
                              [file join $repo_root vivado build fpga_xt_top.bit]}]}]
set elf_path   [expr {$argc >= 2 ? [lindex $argv 1] :
                       [expr {[info exists ::env(ELF)] ? $::env(ELF) :
                              [file join $repo_root vitis workspace xtos \
                                         build xtos.elf]}]}]
set hw_host    [expr {$argc >= 3 ? [lindex $argv 2] :
                       [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER) :
                              "TCP:127.0.0.1:3121"}]}]

# ps7_init.tcl lives under the BD's gen tree.  Anchor the search off
# the bitstream's directory (more reliable than $script_dir/../..,
# which breaks when run from the flat win10 layout where there's no
# vivado/ wrapper).  Override directly via PS7_INIT_TCL env var.
set bit_dir    [file dirname $bit_path]
set bit_parent [file dirname $bit_dir]
if {[info exists ::env(PS7_INIT_TCL)]} {
    set ps_init_tcl $::env(PS7_INIT_TCL)
} else {
    set ps_init_candidates [list \
        [file join $bit_parent bd zynq_ps_bd zynq_ps_bd.gen sources_1 \
                   bd ps_bd ip ps_bd_zynq_ps_0 ps7_init.tcl] \
        [file join $repo_root vivado bd zynq_ps_bd zynq_ps_bd.gen \
                   sources_1 bd ps_bd ip ps_bd_zynq_ps_0 ps7_init.tcl] \
        [file join $repo_root bd zynq_ps_bd zynq_ps_bd.gen sources_1 \
                   bd ps_bd ip ps_bd_zynq_ps_0 ps7_init.tcl]]
    set ps_init_tcl ""
    foreach c $ps_init_candidates {
        if {[file exists $c]} { set ps_init_tcl $c; break }
    }
    if {$ps_init_tcl eq ""} { set ps_init_tcl [lindex $ps_init_candidates 0] }
}

# ---- Sanity-check inputs --------------------------------------------
foreach {label path} [list bitstream $bit_path elf $elf_path \
                           ps7_init.tcl $ps_init_tcl] {
    if {![file exists $path]} {
        puts stderr "ERROR: $label not found at $path"
        exit 1
    }
}

puts ">> bitstream:    $bit_path"
puts ">> elf:          $elf_path"
puts ">> ps7_init.tcl: $ps_init_tcl"
puts ">> hw_server:    $hw_host"

# Set JTAG_DRY_RUN=1 to exit here, after path resolution + existence
# checks but before any JTAG action.  Useful for verifying the script
# parses without a cable attached.
if {[info exists ::env(JTAG_DRY_RUN)]} {
    puts ">> JTAG_DRY_RUN set — exiting before connect"
    exit 0
}

# ---- Connect to hw_server -------------------------------------------
puts ">> connecting to hw_server"
connect -url $hw_host

# ---- Stop + core reset first (clean slate, no SD re-boot) -----------
# Re-running over a LIVE image (A9 mid-AXI/IRQ) and then reconfiguring the PL
# under it wedges the DAP (AP transaction timeout / "no targets" -> a physical
# power-cycle).  Stop the A9 and reset just the CORE so its in-flight AXI/IRQ
# activity is cleared before fpga/ps7_init.  Crucially `rst -processor` (unlike
# `rst -system`) does NOT re-run the boot ROM, so on an SD-boot-mode board it
# won't pull a stale FSBL from the SD card over our JTAG session.
puts ">> stop + core reset (clean slate, no SD re-boot)"
catch { targets -set -filter {name =~ "ARM*#0"}; stop }
catch { rst -processor }
catch { stop }
after 300

# ---- Halt the A9 before reconfig/ps7_init ---------------------------
# So this can take over a board that's ALREADY running (e.g. an SD-booted
# image) without ps7_init re-initialising DDR under a live CPU (-> hang)
# and without the A9 driving GP0/AXI into the PL mid-reconfiguration.
# catch: the core may not be enumerated/running yet (cold JTAG-mode board).
puts ">> halting A9 (take over any running image)"
catch { targets -set -filter {name =~ "ARM*#0"}; stop }

# ---- Load bitstream into PL -----------------------------------------
# Pick the FPGA target (Zynq XC7Z020 here).  `targets -set -filter` is
# precise; if multiple devices are on the chain, narrow with "name".
puts ">> loading bitstream into PL"
targets -set -filter {name =~ "*xc7z020*"}
fpga -file $bit_path

# ---- Initialise the PS ----------------------------------------------
# ps7_init.tcl exports `ps7_init` and `ps7_post_config` as Tcl procs.
# Source it, then call them in order.  This sets up DDR3, clocks, MIO,
# and configures the PL bridges so the ARM cores can run code.
puts ">> running ps7_init"
targets -set -filter {name =~ "ARM*#0"}
source $ps_init_tcl
ps7_init
ps7_post_config

# ---- Download + run app ELF -----------------------------------------
puts ">> downloading ELF"
rst -processor
dow $elf_path
puts ">> running"
con

puts ">> done.  UART (115200 8N1) should now print:"
puts ">>    fpga-xt boot OK"
puts ">>    blitter @0x43c00000: status=0x00 seq=0"
puts ">>    tick 0"
puts ">>    ..."
