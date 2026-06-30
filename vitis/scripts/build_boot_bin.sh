#!/usr/bin/env bash
# build_boot_bin.sh — package FSBL + bitstream + app ELF into a bootable BOOT.BIN
# on valhalla (Vitis 2025.2 bootgen), then pull it back. Default app = the loader
# (xtos: loader/build/freertos-hw.elf) — the merge target that boots standalone.
#
# Usage:
#   ./build_boot_bin.sh                          # loader -> vitis/BOOT.BIN
#   ./build_boot_bin.sh <local_out_path>         # custom output location
#   APP=vitis/workspace/xtos/build/xtos.elf ./build_boot_bin.sh   # boot legacy xtos instead
#
# To boot it: copy BOOT.BIN to the root of a FAT32 SD card, set the boot-mode
# jumpers to SD, power-cycle. The FSBL does PS init (DDR/clocks/MIO), configures
# the PL from the bitstream, loads the app ELF to DDR, and jumps to its entry —
# so the loader's xt_boot.S (app-side setup only) needs no change vs JTAG.
#
# Env overrides: REMOTE=valhalla  REMOTE_DIR=fpga-xt-build  VITIS_PATH=/opt/xilinx/2025.2/Vitis
#                FSBL / BIT / APP  (paths RELATIVE to REMOTE_DIR)

set -euo pipefail

REMOTE="${REMOTE:-valhalla}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VITIS_PATH="${VITIS_PATH:-/opt/xilinx/2025.2/Vitis}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FSBL="${FSBL:-vitis/workspace/fsbl/build/fsbl.elf}"   # REMOTE_DIR-relative
BIT="${BIT:-build/fpga_xt_top.bit}"
APP="${APP:-loader/build/freertos-hw.elf}"
LOCAL_OUT="${1:-$REPO_ROOT/vitis/BOOT.BIN}"

# Push the freshest locally-built artefacts (the loader ELF; the bitstream if present
# locally). FSBL + bitstream usually already live on valhalla from the build/JTAG flow.
ssh "$REMOTE" "mkdir -p $REMOTE_DIR/loader/build $REMOTE_DIR/build"
[ -f "$REPO_ROOT/loader/build/freertos-hw.elf" ] && \
    rsync -az "$REPO_ROOT/loader/build/freertos-hw.elf" "$REMOTE:$REMOTE_DIR/loader/build/freertos-hw.elf"
[ -f "$REPO_ROOT/vivado/build/fpga_xt_top.bit" ] && \
    rsync -az "$REPO_ROOT/vivado/build/fpga_xt_top.bit" "$REMOTE:$REMOTE_DIR/build/fpga_xt_top.bit"

echo ">> bootgen on $REMOTE:  [bootloader] $FSBL  +  $BIT  +  $APP"
ssh "$REMOTE" bash -l <<EOF
set -e
source "$VITIS_PATH/settings64.sh"
cd "$REMOTE_DIR"
for f in "$FSBL" "$BIT" "$APP"; do
    [ -f "\$f" ] || { echo "ERROR: missing on $REMOTE: $REMOTE_DIR/\$f" >&2; exit 1; }
done
cat > boot.bif <<BIF
the_ROM_image:
{
    [bootloader] $FSBL
    $BIT
    $APP
}
BIF
bootgen -arch zynq -image boot.bif -o BOOT.BIN -w on
ls -l BOOT.BIN
EOF

echo ">> pulling BOOT.BIN -> $LOCAL_OUT"
mkdir -p "$(dirname "$LOCAL_OUT")"
rsync -az "$REMOTE:$REMOTE_DIR/BOOT.BIN" "$LOCAL_OUT"
ls -lh "$LOCAL_OUT"
echo ">> Copy this BOOT.BIN to a FAT32 SD card, set boot jumpers to SD, power-cycle."
