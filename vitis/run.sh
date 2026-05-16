#!/usr/bin/env bash
# Run the Vitis platform / FSBL / app build on the remote Linux box.
#
# Mirrors vivado/run.sh — rsync sources to remote, source the Xilinx
# tools, run a batch-mode Vitis flow, rsync results back.
#
# Prerequisite: the XSA must exist on the remote build host.  Run
# `cd ../vivado && ./run.sh bit ...` first (build.tcl emits the XSA
# alongside the bitstream as of 2026-05).
#
# Usage:
#   ./run.sh                                 # full create_platform.py
#   ./run.sh <script>                        # run a custom script
#
# Env var overrides:
#   VITIS_PATH=/opt/xilinx/2025.2.1/Vitis    (default; adjust per install)
#   REMOTE=ubuntu                            (SSH alias of build box)
#   REMOTE_DIR=fpga-xt-build                 (build path on remote)

set -euo pipefail

SCRIPT="${1:-scripts/create_platform.py}"

REMOTE="${REMOTE:-ubuntu}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VITIS_PATH="${VITIS_PATH:-/opt/xilinx/2025.2.1/Vitis}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_WORKSPACE="$REPO_ROOT/vitis/workspace"

mkdir -p "$LOCAL_WORKSPACE"

# Vivado run.sh already drops the XSA into vivado/build/ on the
# remote.  Confirm before launching Vitis so we don't get a confusing
# "platform create failed" error halfway through.
echo ">> checking remote XSA exists at $REMOTE:$REMOTE_DIR/build/fpga_xt_top.xsa"
if ! ssh "$REMOTE" "test -f $REMOTE_DIR/build/fpga_xt_top.xsa"; then
    echo "ERROR: XSA not found on $REMOTE." >&2
    echo "       Run 'cd ../vivado && ./run.sh bit ...' first." >&2
    exit 1
fi

echo ">> syncing vitis/ -> $REMOTE:$REMOTE_DIR/vitis/"
ssh "$REMOTE" "mkdir -p $REMOTE_DIR/vitis"
rsync -az --delete \
    --exclude 'workspace/' \
    --exclude 'build/' \
    "$REPO_ROOT/vitis/" "$REMOTE:$REMOTE_DIR/vitis/"

echo ">> running vitis -s $SCRIPT (workspace mode)"
ssh "$REMOTE" bash -l <<EOF
set -eo pipefail
set +u
source $VITIS_PATH/settings64.sh
set -u
cd ~/$REMOTE_DIR/vitis
vitis -s $SCRIPT
EOF

echo ">> syncing workspace back -> $LOCAL_WORKSPACE/"
rsync -az --delete \
    "$REMOTE:$REMOTE_DIR/vitis/workspace/" "$LOCAL_WORKSPACE/" \
    2>/dev/null || true

echo ">> done.  Build artefacts in $LOCAL_WORKSPACE/"
echo "   * platform: $LOCAL_WORKSPACE/fpga_xt_platform/export/"
echo "   * FSBL elf: $LOCAL_WORKSPACE/fsbl/build/fsbl.elf"
echo "   * app elf:  $LOCAL_WORKSPACE/app_blink/build/app_blink.elf"
