#!/usr/bin/env bash
# run-win10.sh — Vitis platform / FSBL / app build on the win10 box.
#
# Mac-side companion to vivado/run-win10.sh.  scp pushes scripts/ +
# xtos/, ssh runs vitis -s <script>, optionally scp pulls the
# build elves back.  The full workspace is NOT pulled — it's tens of
# thousands of files, gitignored, and reproducible from the script.
#
# Prerequisite: the XSA must exist on win10.  Run
# `cd ../vivado && ./run-win10.sh bit ...` first.
#
# Usage:
#   ./run-win10.sh                       # full scripts/create_platform.py
#   ./run-win10.sh <script>              # custom Python script
#   PULL=1 ./run-win10.sh                # also pull fsbl.elf + xtos.elf
#                                        #  back to vitis/workspace/...
#
# Env-var overrides:
#   REMOTE       win10                                       (SSH alias)
#   REMOTE_DIR   C:/Users/user/fpga                         (work tree root)
#   VITIS_BAT    C:\Xilinx\2025.2.1\Vitis\bin\vitis.bat      (Vitis launcher)
#   PULL         unset (set =1 to scp build elves back)

set -euo pipefail

SCRIPT="${1:-scripts/create_platform.py}"

REMOTE="${REMOTE:-win10}"
REMOTE_DIR="${REMOTE_DIR:-C:/Users/user/fpga}"
VITIS_BAT="${VITIS_BAT:-C:\\Xilinx\\2025.2.1\\Vitis\\bin\\vitis.bat}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_WORKSPACE="$REPO_ROOT/vitis/workspace"

# PowerShell helpers ------------------------------------------------------
ps_wipe() {
    local dir="$1"
    ssh "$REMOTE" "if (Test-Path '$dir') { Remove-Item -Recurse -Force '$dir' }"
}

ps_mkdir() {
    local dir="$1"
    ssh "$REMOTE" "New-Item -ItemType Directory -Path '$dir' -Force | Out-Null"
}

# Sanity-check the XSA exists ---------------------------------------------
echo ">> checking remote XSA at $REMOTE:$REMOTE_DIR/build/fpga_xt_top.xsa"
if ! ssh "$REMOTE" "Test-Path '$REMOTE_DIR/build/fpga_xt_top.xsa'" \
        | grep -q True; then
    echo "ERROR: XSA not found on $REMOTE." >&2
    echo "       Run 'cd ../vivado && ./run-win10.sh bit ...' first." >&2
    exit 1
fi

# Push sources ------------------------------------------------------------
echo ">> preparing $REMOTE:$REMOTE_DIR/vitis"
ps_mkdir "$REMOTE_DIR/vitis"

echo ">> pushing scripts/ -> $REMOTE:$REMOTE_DIR/vitis/scripts/"
ps_wipe "$REMOTE_DIR/vitis/scripts"
scp -q -r "$REPO_ROOT/vitis/scripts" "$REMOTE:$REMOTE_DIR/vitis/scripts"

echo ">> pushing xtos/ (app src + tinyusb/src only) -> $REMOTE:$REMOTE_DIR/vitis/xtos/"
ps_wipe "$REMOTE_DIR/vitis/xtos"
ps_mkdir "$REMOTE_DIR/vitis/xtos/tinyusb"
# App sources, then ONLY the TinyUSB src/ tree (not the ~50 MB submodule's
# examples/docs/test/hw/.git — the build only compiles + includes src/).
scp -q -r "$REPO_ROOT/vitis/xtos/src" "$REMOTE:$REMOTE_DIR/vitis/xtos/src"
scp -q -r "$REPO_ROOT/vitis/xtos/tinyusb/src" "$REMOTE:$REMOTE_DIR/vitis/xtos/tinyusb/src"

# Run Vitis ---------------------------------------------------------------
echo ">> running vitis -s $SCRIPT"
ssh "$REMOTE" "Set-Location '$REMOTE_DIR/vitis'; & '$VITIS_BAT' -s $SCRIPT"

# Optionally pull build artefacts -----------------------------------------
# Workspace is 30k+ files — only pull the specific elf outputs by default
# (gated on PULL=1).  The full workspace stays on win10 where Vitis IDE /
# xsct can use it directly.
if [ -n "${PULL:-}" ]; then
    echo ">> pulling build elves -> $LOCAL_WORKSPACE/"
    mkdir -p "$LOCAL_WORKSPACE/fsbl/build"
    mkdir -p "$LOCAL_WORKSPACE/xtos/build"
    scp -q "$REMOTE:$REMOTE_DIR/vitis/workspace/fsbl/build/fsbl.elf" \
        "$LOCAL_WORKSPACE/fsbl/build/fsbl.elf" 2>/dev/null \
        || echo "   (fsbl.elf not present — VITIS_NO_FSBL set?)"
    scp -q "$REMOTE:$REMOTE_DIR/vitis/workspace/xtos/build/xtos.elf" \
        "$LOCAL_WORKSPACE/xtos/build/xtos.elf"
    ls -lh "$LOCAL_WORKSPACE"/{fsbl/build/fsbl.elf,xtos/build/xtos.elf} 2>/dev/null || true
fi

echo ">> done."
echo "   workspace on win10: $REMOTE_DIR/vitis/workspace/"
if [ -n "${PULL:-}" ]; then
    echo "   local elves:        $LOCAL_WORKSPACE/{fsbl,xtos}/build/*.elf"
fi
