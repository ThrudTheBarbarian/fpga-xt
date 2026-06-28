#!/usr/bin/env bash
# Vitis platform / FSBL / app build for fpga-xt on 'valhalla'.  Needs the XSA
# (run vivado/run-valhalla.sh first).  rsync the repo-layout sources, source
# the 2025.2 Vitis tools, run create_platform.py, rsync the elves back.
#
# Usage:
#   ./run-valhalla.sh                 # full scripts/create_platform.py
#   ./run-valhalla.sh <script>        # custom script
#   PULL=1 ./run-valhalla.sh          # also pull fsbl.elf + xtos.elf back
#
# Env overrides: REMOTE=valhalla  REMOTE_DIR=fpga-xt-build
#                VITIS_PATH=/opt/xilinx/2025.2/Vitis

set -euo pipefail

SCRIPT="${1:-scripts/create_platform.py}"
REMOTE="${REMOTE:-valhalla}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VITIS_PATH="${VITIS_PATH:-/opt/xilinx/2025.2/Vitis}"
PULL="${PULL:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_WORKSPACE="$REPO_ROOT/vitis/workspace"
mkdir -p "$LOCAL_WORKSPACE"

echo ">> checking remote XSA at $REMOTE:$REMOTE_DIR/build/fpga_xt_top.xsa"
ssh "$REMOTE" "test -f $REMOTE_DIR/build/fpga_xt_top.xsa" || {
    echo "ERROR: XSA not on $REMOTE — run vivado/run-valhalla.sh bit first." >&2; exit 1; }

# create_platform.py resolves gem/ + xtos/ from REPO_ROOT and APP_SRC from
# vitis/xtos/src, so the remote needs the repo-root layout for all three.
echo ">> syncing vitis/ gem/ xtos/ loader/ -> $REMOTE:$REMOTE_DIR/"
rsync -az --delete --exclude 'workspace/' --exclude 'build/' \
    "$REPO_ROOT/vitis/" "$REMOTE:$REMOTE_DIR/vitis/"
rsync -az --delete "$REPO_ROOT/gem/"  "$REMOTE:$REMOTE_DIR/gem/"
rsync -az --delete "$REPO_ROOT/xtos/" "$REMOTE:$REMOTE_DIR/xtos/"
# loader/xtld.c is compiled into xtos.elf (dynamic loader); skip its build deps
rsync -az --delete --exclude 'build/' --exclude 'newlib-pic/' \
    "$REPO_ROOT/loader/" "$REMOTE:$REMOTE_DIR/loader/"

echo ">> vitis -s $SCRIPT"
ssh "$REMOTE" bash -l <<EOF
set -eo pipefail
set +u
source $VITIS_PATH/settings64.sh
set -u
cd ~/$REMOTE_DIR/vitis
vitis -s $SCRIPT
EOF

if [ -n "$PULL" ]; then
    echo ">> pulling elves -> $LOCAL_WORKSPACE/"
    mkdir -p "$LOCAL_WORKSPACE/xtos/build" "$LOCAL_WORKSPACE/fsbl/build"
    rsync -az "$REMOTE:$REMOTE_DIR/vitis/workspace/xtos/build/xtos.elf" "$LOCAL_WORKSPACE/xtos/build/" 2>/dev/null || true
    rsync -az "$REMOTE:$REMOTE_DIR/vitis/workspace/fsbl/build/fsbl.elf" "$LOCAL_WORKSPACE/fsbl/build/" 2>/dev/null || true
fi
echo ">> done."
