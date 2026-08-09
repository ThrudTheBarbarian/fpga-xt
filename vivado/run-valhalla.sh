#!/usr/bin/env bash
# Run Vivado flows for fpga-xt on 'valhalla' (Ryzen 9 Linux build+JTAG host;
# replaces the retired win10/ubuntu boxes).  rsync the repo-layout sources to
# the remote, source the 2025.2 toolchain, batch-build, rsync artefacts back.
#
# Usage: ./run-valhalla.sh [flow] [top] [part]
#   flow ∈ {synth, impl, bit, xsa}    (default: bit)
#
# Env overrides:
#   REMOTE=valhalla            (ssh alias)
#   REMOTE_DIR=fpga-xt-build   (work tree on the remote, repo-root layout)
#   VIVADO_PATH=/opt/xilinx/2025.2/Vivado
#   PLACE_DIRECTIVE=Explore    (passed through to build.tcl; needed to close
#                               clk_sys with the drag-overlay plane)
#   MAX_THREADS=10

set -euo pipefail

FLOW="${1:-bit}"
TOP="${2:-fpga_xt_top}"
PART="${3:-xc7z020-2clg400}"

REMOTE="${REMOTE:-valhalla}"
REMOTE_DIR="${REMOTE_DIR:-fpga-xt-build}"
VIVADO_PATH="${VIVADO_PATH:-/opt/xilinx/2025.2/Vivado}"
# Default to a MEASURED-GOOD placer directive. Vivado's own default lands
# clk_sys NEGATIVE on this design: a 5-directive sweep (2026-07-22, no pblocks,
# blitter DO_REG enabled) gave clk_sys setup/hold —
#   Default               -0.028 / +0.036   <-- FAILS the timing gate
#   Explore               +0.024 / +0.036
#   ExtraPostPlacementOpt +0.016 / +0.036
#   ExtraNetDelay_high    +0.065 / +0.036
#   AltSpreadLogic_high   +0.121 / +0.009   (best setup, spends hold)
#   ExtraTimingOpt        +0.123 / +0.009   (the HW-verified build)
# Override with PLACE_DIRECTIVE=... for experiments; do not set it empty.
PLACE_DIRECTIVE="${PLACE_DIRECTIVE:-ExtraTimingOpt}"
# Incremental implementation: point at a routed .dcp (path on the remote, under
# $REMOTE_DIR) to reuse its P&R for unchanged logic.  Keep it OUTSIDE build/
# (which is rm -rf'd each run), e.g. ref.dcp.  Empty = full build.
INCR_REF_DCP="${INCR_REF_DCP:-}"
INCR_DIRECTIVE="${INCR_DIRECTIVE:-}"
# Ship a knowingly-marginal bitstream past the negative-WNS gate (e.g. thin clk_sys).
TIMING_GATE_ALLOW_NEG="${TIMING_GATE_ALLOW_NEG:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD="$REPO_ROOT/vivado/build"
mkdir -p "$LOCAL_BUILD"

echo ">> syncing sources -> $REMOTE:$REMOTE_DIR/ (repo-root layout)"
ssh "$REMOTE" "mkdir -p $REMOTE_DIR"
rsync -az --delete "$REPO_ROOT/hdl/"                "$REMOTE:$REMOTE_DIR/hdl/"
rsync -az --delete "$REPO_ROOT/vivado/constraints/" "$REMOTE:$REMOTE_DIR/constraints/"
rsync -az --delete "$REPO_ROOT/vivado/bd/"          "$REMOTE:$REMOTE_DIR/bd/"
rsync -az --delete "$REPO_ROOT/rsrc/"               "$REMOTE:$REMOTE_DIR/rsrc/"
rsync -az --delete "$REPO_ROOT/vivado/scripts/"     "$REMOTE:$REMOTE_DIR/scripts/"
rsync -az          "$REPO_ROOT/vivado/build.tcl"    "$REMOTE:$REMOTE_DIR/build.tcl"

echo ">> vivado -mode batch (flow=$FLOW top=$TOP part=$PART, PLACE_DIRECTIVE=${PLACE_DIRECTIVE:-default})"
ssh "$REMOTE" bash -l <<EOF
set -eo pipefail
set +u
source $VIVADO_PATH/settings64.sh
set -u
cd ~/$REMOTE_DIR
export PLACE_DIRECTIVE="$PLACE_DIRECTIVE"
export INCR_REF_DCP="$INCR_REF_DCP"
export INCR_DIRECTIVE="$INCR_DIRECTIVE"
export TIMING_GATE_ALLOW_NEG="$TIMING_GATE_ALLOW_NEG"
# Regenerate the PS block design (gen_ps_bd.tcl) for synth/impl/bit so it
# tracks the script, not the stale committed BD output — else an HP port added
# to the script but not re-run fails elaboration with "m_axi_hpN_* does not
# exist".  The xsa flow re-emits from an existing checkpoint and must NOT regen.
if [ "$FLOW" != "xsa" ]; then
    rm -rf build
    vivado -mode batch -nojournal -nolog -source bd/gen_ps_bd.tcl
fi
vivado -mode batch -nojournal -nolog -source build.tcl -tclargs $FLOW $TOP $PART
EOF

echo ">> pulling build/ -> $LOCAL_BUILD/"
rsync -az "$REMOTE:$REMOTE_DIR/build/" "$LOCAL_BUILD/" 2>/dev/null || true
echo ">> done. artefacts in $LOCAL_BUILD/"
