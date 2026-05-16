#!/usr/bin/env bash
# Run Vivado flows for fpga-xt on the remote Windows build host (win10).
#
# Mirrors run.sh (which targets the ubuntu Linux box) but uses scp +
# PowerShell instead of rsync + bash, since win10 has no rsync and runs
# OpenSSH-on-PowerShell.
#
# Usage: ./run-win10.sh [flow] [top] [part]
#   flow ∈ {synth, impl, bit, xsa}    (default: synth)
#   top   default: fpga_xt_top
#   part  default: xc7z020-2clg400
#
# Env var overrides:
#   REMOTE=win10                                       (ssh alias)
#   REMOTE_DIR='C:/Users/simon/fpga'                   (flat build dir on win10;
#                                                       layout matches what
#                                                       build.tcl expects:
#                                                       hdl/, constraints/,
#                                                       bd/, build.tcl at root)
#   VIVADO_BAT='C:\Xilinx\2025.2.1\Vivado\bin\vivado.bat'
#   MAX_THREADS=8                                      (passed through to
#                                                       build.tcl's
#                                                       general.maxThreads)

set -euo pipefail

FLOW="${1:-synth}"
TOP="${2:-fpga_xt_top}"
PART="${3:-xc7z020-2clg400}"

REMOTE="${REMOTE:-win10}"
REMOTE_DIR="${REMOTE_DIR:-C:/Users/simon/fpga}"
VIVADO_BAT="${VIVADO_BAT:-C:\\Xilinx\\2025.2.1\\Vivado\\bin\\vivado.bat}"
MAX_THREADS="${MAX_THREADS:-8}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD="$REPO_ROOT/vivado/build"

mkdir -p "$LOCAL_BUILD"

# PowerShell snippets ------------------------------------------------------
# Wipe a directory tree (mimics rsync --delete on the source side) so that
# renamed/removed local files don't linger on win10 and pollute the glob.
ps_wipe() {
    local dir="$1"
    ssh "$REMOTE" "if (Test-Path '$dir') { Remove-Item -Recurse -Force '$dir' }"
}

ps_mkdir() {
    local dir="$1"
    ssh "$REMOTE" "New-Item -ItemType Directory -Path '$dir' -Force | Out-Null"
}

# Push sources -------------------------------------------------------------
echo ">> preparing $REMOTE:$REMOTE_DIR"
ps_mkdir "$REMOTE_DIR"

echo ">> pushing hdl/ -> $REMOTE:$REMOTE_DIR/hdl/"
ps_wipe "$REMOTE_DIR/hdl"
scp -q -r "$REPO_ROOT/hdl" "$REMOTE:$REMOTE_DIR/hdl"

if [ -d "$REPO_ROOT/vivado/constraints" ]; then
    echo ">> pushing constraints/ -> $REMOTE:$REMOTE_DIR/constraints/"
    ps_wipe "$REMOTE_DIR/constraints"
    scp -q -r "$REPO_ROOT/vivado/constraints" "$REMOTE:$REMOTE_DIR/constraints"
fi

# bd/ is only needed for the bit / xsa flows (PS block design ingest).
if [ "$FLOW" = "bit" ] || [ "$FLOW" = "xsa" ]; then
    if [ -d "$REPO_ROOT/vivado/bd" ]; then
        echo ">> pushing bd/ -> $REMOTE:$REMOTE_DIR/bd/"
        ps_wipe "$REMOTE_DIR/bd"
        scp -q -r "$REPO_ROOT/vivado/bd" "$REMOTE:$REMOTE_DIR/bd"
    fi
fi

echo ">> pushing build.tcl -> $REMOTE:$REMOTE_DIR/build.tcl"
scp -q "$REPO_ROOT/vivado/build.tcl" "$REMOTE:$REMOTE_DIR/build.tcl"

# Clean build/ unless this is an xsa-only re-emit (which needs the prior
# post_route.dcp from build/).
if [ "$FLOW" != "xsa" ]; then
    echo ">> wiping $REMOTE:$REMOTE_DIR/build"
    ps_wipe "$REMOTE_DIR/build"
fi

# Run Vivado ---------------------------------------------------------------
echo ">> running vivado (flow=$FLOW top=$TOP part=$PART threads=$MAX_THREADS)"

# Quote layering: the outer single quotes wrap the PowerShell command we hand
# to ssh; the inner single quotes wrap the vivado.bat path for the `&` call
# operator. $env:MAX_THREADS pushes the value through to build.tcl's
# [info exists ::env(MAX_THREADS)] check.
ssh "$REMOTE" "Set-Location '$REMOTE_DIR'; \$env:MAX_THREADS='$MAX_THREADS'; & '$VIVADO_BAT' -mode batch -nojournal -nolog -source build.tcl -tclargs $FLOW $TOP $PART"

# Pull artefacts back ------------------------------------------------------
echo ">> pulling build/ -> $LOCAL_BUILD/"
ssh "$REMOTE" "if (Test-Path '$REMOTE_DIR/build') { Get-ChildItem '$REMOTE_DIR/build' | Select-Object -ExpandProperty Name }" \
    | tr -d '\r' \
    | while read -r f; do
        [ -z "$f" ] && continue
        scp -q "$REMOTE:$REMOTE_DIR/build/$f" "$LOCAL_BUILD/$f"
    done

echo ">> done. artefacts in $LOCAL_BUILD/"
