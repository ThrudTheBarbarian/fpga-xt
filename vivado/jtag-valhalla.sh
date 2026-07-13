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
#   ./jtag-valhalla.sh load    # FULL cold-load: bitstream + ps7_init + kernel  <-- the one you want
#   ./jtag-valhalla.sh reset   # rst -system + reload the kernel (no bitstream push)
#
#   Aliases (old names, same behaviour — muscle memory keeps working):
#     testbed = load     treset = reset
#
# ⚠ THIS SCRIPT ONLY EVER BOOTS THE LIVE KERNEL: loader/build/freertos-hw.elf
#
#   It used to have THREE MORE modes — load/reset/dow — which booted
#   vitis/workspace/xtos/build/xtos.elf, the RETIRED bare-metal XTOS. `load` was also the
#   DEFAULT. So the obvious-sounding command silently booted the dead OS, and the live
#   kernel was the odd one out called `testbed`. That is exactly the sort of trap that
#   sends a reader (or an agent) days down the wrong tree, and it has now been removed:
#   there is ONE OS in this script, and it is the one in loader/.
#
# ⚠ WHAT ACTUALLY WORKS ON THIS BOARD (measured, not inferred):
#
#     ./jtag-valhalla.sh reset && ./jtag-valhalla.sh load
#
#   reset — every xsct step succeeds (rst -system -> ps7_init -> dow -> running), so the
#           download is NOT the problem. But the board still needs a `load` afterwards,
#           which means `rst -system` WIPES THE PL CONFIGURATION. jtag_sysdow.tcl's header
#           claims it leaves "the live PL config and the clk_pix MMCM lock untouched" —
#           that is FALSE on this board.
#   load  — jtag_load.tcl: fpga -file + ps7_init + dow. A full cold-load, and the only
#           mode observed to leave a working board.
#
#   `dow`/`tdow` (rst -processor, no ps7_init) HUNG THE BOARD every time: DDR/peripherals
#   keep the dying kernel's state and the new one wedges. It has been DELETED rather than
#   documented — a mode whose only behaviour is to hang the board is a trap, not a
#   convenience, and leaving it in means someone eventually types it.
#
# NOT YET TRIED: `load` ON ITS OWN. It is a complete cold-load, so it may well be the
# single command, making the `reset` chaser pointless. Worth one experiment.
#
# Env: REMOTE=valhalla  REMOTE_DIR=fpga-xt-build  VITIS_PATH=/opt/xilinx/2025.2/Vitis

set -euo pipefail
MODE="${1:-load}"
# Normalise the aliases up front so everything below sees the canonical name.
case "$MODE" in
  testbed) MODE=load  ;;
  treset)  MODE=reset ;;
  dow|tdow) echo "jtag: '$MODE' is GONE — it hung the board every time (rst -processor, no ps7_init). Use: load" >&2; exit 1 ;;
esac
REMOTE="${REMOTE:-valhalla}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VITIS_PATH="${VITIS_PATH:-/opt/xilinx/2025.2/Vitis}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">> pushing jtag scripts + ELF + bitstream"
ssh "$REMOTE" "mkdir -p $REMOTE_DIR/vivado/scripts $REMOTE_DIR/vitis/workspace/xtos/build $REMOTE_DIR/loader/build $REMOTE_DIR/build"
rsync -az "$REPO_ROOT/vivado/scripts/" "$REMOTE:$REMOTE_DIR/vivado/scripts/"
rsync -az "$REPO_ROOT/loader/build/freertos-hw.elf" "$REMOTE:$REMOTE_DIR/loader/build/freertos-hw.elf"
# Only the full `load` reprograms the PL, so only it needs the bitstream pushed.
[ "$MODE" = "load" ] && rsync -az "$REPO_ROOT/vivado/build/fpga_xt_top.bit" "$REMOTE:$REMOTE_DIR/build/fpga_xt_top.bit"

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
  load)  xvfb-run -a xsct vivado/scripts/jtag_load.tcl build/fpga_xt_top.bit loader/build/freertos-hw.elf ;;  # FULL cold-load: reprograms the PL
  reset) xvfb-run -a xsct vivado/scripts/jtag_sysdow.tcl loader/build/freertos-hw.elf ;;                      # rst -system + reload; clean DDR, no power-cycle
  *)     echo "usage: $0 [load|reset]   (aliases: testbed=load, treset=reset)" >&2; exit 1 ;;
esac
EOF
echo ">> done."
