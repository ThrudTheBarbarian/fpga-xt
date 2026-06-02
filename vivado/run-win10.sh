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
#   REMOTE_DIR='C:/Users/user/fpga'                   (flat build dir on win10;
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
REMOTE_DIR="${REMOTE_DIR:-C:/Users/user/fpga}"
VIVADO_BAT="${VIVADO_BAT:-C:\\Xilinx\\2025.2.1\\Vivado\\bin\\vivado.bat}"
MAX_THREADS="${MAX_THREADS:-8}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD="$REPO_ROOT/vivado/build"

mkdir -p "$LOCAL_BUILD"

# ---- Up-to-date gate (bit flow) ------------------------------------------
# A full bit build is ~40 min.  Skip it when the pulled-back bitstream is
# already newer than every build input — i.e. nothing changed.  Catches the
# out-of-sync case (edit a source/constraint/BD/script -> rebuild) without
# burning a synth on a no-op.  Override with FORCE=1.  Only the bit flow has
# a single definitive artefact ($TOP.bit) to check against; synth/impl/xsa
# always run.  The build inputs are exactly what gets pushed (hdl,
# constraints, bd/gen_ps_bd.tcl, build.tcl), the OS ROM read at synth
# (rsrc/sally-boot.hex), and this driver script itself.
if [ "$FLOW" = "bit" ] && [ -z "${FORCE:-}" ] && [ -f "$LOCAL_BUILD/${TOP}.bit" ]; then
    bit_changed="$(find "$REPO_ROOT/hdl" \
                        "$REPO_ROOT/vivado/constraints" \
                        "$REPO_ROOT/vivado/bd/gen_ps_bd.tcl" \
                        "$REPO_ROOT/vivado/build.tcl" \
                        "$REPO_ROOT/rsrc/sally-boot.hex" \
                        "$0" \
                        -type f -newer "$LOCAL_BUILD/${TOP}.bit" -print 2>/dev/null | head -n 1)"
    if [ -z "$bit_changed" ]; then
        echo ">> ${TOP}.bit is newer than all build inputs — up to date, skipping."
        echo ">>   (set FORCE=1 to rebuild anyway.)"
        exit 0
    fi
    echo ">> bit rebuild needed — changed since last build: $bit_changed"
fi

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

# rsrc/ holds the $readmemh BRAM-init inputs read during synth: the OS ROM
# (rsrc/sally-boot.hex) + self-test ROM (rsrc/selftest.hex).  build.tcl resolves
# them relative to the run dir, so they must live at $REMOTE_DIR/rsrc/.  (The
# palette init hdl/palette/atari_ntsc.hex ships with the hdl/ push above.)  The
# xsa re-emit doesn't re-synthesise, so it doesn't need them.
if [ "$FLOW" != "xsa" ] && [ -d "$REPO_ROOT/rsrc" ]; then
    echo ">> pushing rsrc/ -> $REMOTE:$REMOTE_DIR/rsrc/"
    ps_wipe "$REMOTE_DIR/rsrc"
    scp -q -r "$REPO_ROOT/rsrc" "$REMOTE:$REMOTE_DIR/rsrc"
fi

# bd/ is only needed for the bit / xsa flows (PS block design ingest).
if [ "$FLOW" = "bit" ] || [ "$FLOW" = "xsa" ]; then
    if [ -d "$REPO_ROOT/vivado/bd" ]; then
        echo ">> pushing bd/ -> $REMOTE:$REMOTE_DIR/bd/"
        ps_wipe "$REMOTE_DIR/bd"
        scp -q -r "$REPO_ROOT/vivado/bd" "$REMOTE:$REMOTE_DIR/bd"
    fi
fi

# Always regenerate the PS block design for the bit flow so it tracks
# gen_ps_bd.tcl rather than the committed generated output (which can go
# stale — e.g. an HP port added to the script but never re-run, which then
# fails elaboration with "m_axi_hpN_* does not exist").  The xsa flow
# re-emits from an existing post_route checkpoint and does NOT re-synthesise,
# so it must NOT regenerate (it would invalidate the checkpoint's BD).
if [ "$FLOW" = "bit" ]; then
    echo ">> regenerating PS block design (gen_ps_bd.tcl) on $REMOTE"
    ssh "$REMOTE" "Set-Location '$REMOTE_DIR'; & '$VIVADO_BAT' -mode batch -source bd/gen_ps_bd.tcl"
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
ssh "$REMOTE" "Set-Location '$REMOTE_DIR'; \$env:MAX_THREADS='$MAX_THREADS'; \$env:XT_CPU='${XT_CPU:-}'; \$env:PLACE_DIRECTIVE='${PLACE_DIRECTIVE:-}'; & '$VIVADO_BAT' -mode batch -nojournal -nolog -source build.tcl -tclargs $FLOW $TOP $PART"

# Pull artefacts back ------------------------------------------------------
echo ">> pulling build/ -> $LOCAL_BUILD/"
ssh "$REMOTE" "if (Test-Path '$REMOTE_DIR/build') { Get-ChildItem '$REMOTE_DIR/build' | Select-Object -ExpandProperty Name }" \
    | tr -d '\r' \
    | while read -r f; do
        [ -z "$f" ] && continue
        scp -q "$REMOTE:$REMOTE_DIR/build/$f" "$LOCAL_BUILD/$f"
    done

echo ">> done. artefacts in $LOCAL_BUILD/"
