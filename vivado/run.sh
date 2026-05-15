#!/usr/bin/env bash
# Run Vivado flows for fpga-xt on the remote 'ubuntu' Linux box.
#
# Usage: ./run.sh [flow] [top] [part]
#   flow ∈ {synth, impl, bit}    (default: synth)
#   top   default: sally_synth_top   (Phase 0 starting point — SALLY
#                                      stack in isolation, fmax probe)
#   part  default: xc7z020-2clg400   (Z-Turn part)
#
# Pattern mirrors efinity/run.sh — rsync HDL to remote, source the
# vendor toolchain, run a batch-mode build, rsync artefacts back.
#
# Env var overrides:
#   VIVADO_PATH=/opt/xilinx/2025.2.1/Vivado  (default; adjust per install)
#   REMOTE=ubuntu                            (SSH alias of the build box;
#                                             resolves to ldaps)
#   REMOTE_DIR=fpga-xt-build                 (build path on remote)

set -euo pipefail

FLOW="${1:-synth}"
TOP="${2:-fpga_xt_top}"
PART="${3:-xc7z020-2clg400}"

REMOTE="${REMOTE:-ubuntu}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VIVADO_PATH="${VIVADO_PATH:-/opt/xilinx/2025.2.1/Vivado}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD="$REPO_ROOT/vivado/build"

mkdir -p "$LOCAL_BUILD"

echo ">> syncing hdl/ -> $REMOTE:$REMOTE_DIR/hdl/"
ssh "$REMOTE" "mkdir -p $REMOTE_DIR"
rsync -az --delete "$REPO_ROOT/hdl/" "$REMOTE:$REMOTE_DIR/hdl/"

if [ -d "$REPO_ROOT/vivado/constraints" ]; then
    echo ">> syncing constraints/ -> $REMOTE:$REMOTE_DIR/constraints/"
    rsync -az --delete "$REPO_ROOT/vivado/constraints/" "$REMOTE:$REMOTE_DIR/constraints/"
fi

if [ -d "$REPO_ROOT/vivado/bd" ]; then
    echo ">> syncing bd/ -> $REMOTE:$REMOTE_DIR/bd/"
    rsync -az --delete "$REPO_ROOT/vivado/bd/" "$REMOTE:$REMOTE_DIR/bd/"
fi

echo ">> syncing build.tcl -> $REMOTE:$REMOTE_DIR/build.tcl"
rsync -az "$REPO_ROOT/vivado/build.tcl" "$REMOTE:$REMOTE_DIR/build.tcl"

echo ">> running vivado -mode batch (flow=$FLOW top=$TOP part=$PART)"
ssh "$REMOTE" bash -l <<EOF
set -eo pipefail
set +u
source $VIVADO_PATH/settings64.sh
set -u
cd ~/$REMOTE_DIR
rm -rf build
vivado -mode batch -nojournal -nolog \\
    -source build.tcl \\
    -tclargs $FLOW $TOP $PART
EOF

echo ">> syncing build artefacts back -> $LOCAL_BUILD/"
rsync -az --delete "$REMOTE:$REMOTE_DIR/build/" "$LOCAL_BUILD/" 2>/dev/null || true

echo ">> done. artefacts in $LOCAL_BUILD/"
