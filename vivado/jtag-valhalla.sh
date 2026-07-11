#!/usr/bin/env bash
# JTAG load for fpga-xt on 'valhalla' (Linux FTDI host).  Encapsulates the
# headless dance:
#   * a DETACHED hw_server (setsid + </dev/null + redirect) so it never wedges
#     the ssh channel (xsct auto-starting one keeps the channel open forever);
#   * xsct under `xvfb-run` (the 2025.2 xsct needs a headless X server);
#   * NEVER `pkill -f hw_server` — the -f pattern matches this very ssh shell
#     (its args contain "hw_server") and kills the session.  Use `pkill -x`.
#
# Usage:
#   ./jtag-valhalla.sh load     # full cold-load: bitstream + ps7_init + ELF
#   ./jtag-valhalla.sh dow      # ELF-only reload (PL + clocks untouched)
#   ./jtag-valhalla.sh testbed  # tier-2 testbed (loader/build/freertos-hw.elf), FULL load (re-programs the PL)
#   ./jtag-valhalla.sh treset   # tier-2 testbed: HARD reset + reload, NO POWER-CYCLE   <-- use this to iterate
#   ./jtag-valhalla.sh tdow     # tier-2 testbed: fastest reload (rst -processor; heap accumulates)
#
# Iterating on the kernel?  Use `treset`, not `testbed`.  `testbed` runs
# jtag_load.tcl, whose `fpga -file` re-programs the PL and unlocks the clk_pix
# MMCM — which is what forces a physical power-cycle (i.e. crawling under the
# desk).  `treset` runs jtag_sysdow.tcl: `rst -system` (clean DDR/peripherals ->
# clean heap, a genuine hard reset) + ps7_init + download, while leaving the PL
# config and the MMCM lock ALONE.  The bitstream doesn't change between kernel
# builds, so there is no reason to reprogram it.  Only run `testbed` when the
# BITSTREAM itself changed.
#
# Env: REMOTE=valhalla  REMOTE_DIR=fpga-xt-build  VITIS_PATH=/opt/xilinx/2025.2/Vitis

set -euo pipefail
MODE="${1:-load}"
REMOTE="${REMOTE:-valhalla}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VITIS_PATH="${VITIS_PATH:-/opt/xilinx/2025.2/Vitis}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">> pushing jtag scripts + ELF + bitstream"
ssh "$REMOTE" "mkdir -p $REMOTE_DIR/vivado/scripts $REMOTE_DIR/vitis/workspace/xtos/build $REMOTE_DIR/loader/build $REMOTE_DIR/build"
rsync -az "$REPO_ROOT/vivado/scripts/" "$REMOTE:$REMOTE_DIR/vivado/scripts/"
case "$MODE" in
  testbed|treset|tdow)
    rsync -az "$REPO_ROOT/loader/build/freertos-hw.elf" "$REMOTE:$REMOTE_DIR/loader/build/freertos-hw.elf"
    # ONLY the full `testbed` load needs the bitstream — treset/tdow leave the PL alone.
    [ "$MODE" = "testbed" ] && rsync -az "$REPO_ROOT/vivado/build/fpga_xt_top.bit" "$REMOTE:$REMOTE_DIR/build/fpga_xt_top.bit"
    ;;
  *)
    rsync -az "$REPO_ROOT/vitis/workspace/xtos/build/xtos.elf" "$REMOTE:$REMOTE_DIR/vitis/workspace/xtos/build/xtos.elf"
    [ "$MODE" = "load" ] && rsync -az "$REPO_ROOT/vivado/build/fpga_xt_top.bit" "$REMOTE:$REMOTE_DIR/build/fpga_xt_top.bit"
    ;;
esac

echo ">> jtag $MODE on $REMOTE"
ssh "$REMOTE" bash -l <<EOF
set -eo pipefail
set +u
source $VITIS_PATH/settings64.sh
set -u
cd ~/$REMOTE_DIR
# Detached hw_server if one isn't already listening on 3121 (hw_server is a
# CLI server and needs no X — only the xsct CLIENT needs xvfb-run).
if ! ss -ltn 2>/dev/null | grep -q ':3121 '; then
    setsid bash -c "exec hw_server" >/tmp/hw.log 2>&1 </dev/null &
    sleep 6
fi
case "$MODE" in
  load)    xvfb-run -a xsct vivado/scripts/jtag_load.tcl build/fpga_xt_top.bit vitis/workspace/xtos/build/xtos.elf ;;
  reset)   xvfb-run -a xsct vivado/scripts/jtag_sysdow.tcl vitis/workspace/xtos/build/xtos.elf ;;  # rst -system, clean heap, no power-cycle
  dow)     xvfb-run -a xsct vivado/scripts/jtag_dow.tcl vitis/workspace/xtos/build/xtos.elf ;;       # rst -processor (fast, may accumulate heap)
  testbed) xvfb-run -a xsct vivado/scripts/jtag_load.tcl build/fpga_xt_top.bit loader/build/freertos-hw.elf ;;  # FULL load: reprograms the PL -> needs a power-cycle
  treset)  xvfb-run -a xsct vivado/scripts/jtag_sysdow.tcl loader/build/freertos-hw.elf ;;  # rst -system + reload, clean heap, NO power-cycle
  tdow)    xvfb-run -a xsct vivado/scripts/jtag_dow.tcl    loader/build/freertos-hw.elf ;;  # rst -processor only (fastest; heap accumulates)
  *)       echo "usage: $0 [load|reset|dow|testbed|treset|tdow]" >&2; exit 1 ;;
esac
EOF
echo ">> done."
