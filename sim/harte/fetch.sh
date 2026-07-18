#!/bin/sh
# Fetch + convert Harte 65x02 tests for the given opcodes (hex). Cached; re-run is cheap.
#   sim/harte/fetch.sh [LIMIT] op op op ...   (LIMIT cases/opcode, default 300)
set -e
D=$(dirname "$0"); BASE=https://raw.githubusercontent.com/SingleStepTests/65x02/main/6502/v1
LIM=300; case "$1" in ''|*[!0-9]*) : ;; *) LIM=$1; shift ;; esac
for op in "$@"; do
    [ -f "$D/json/$op.json" ] || { echo "fetch $op"; curl -fsSL "$BASE/$op.json" -o "$D/json/$op.json"; }
    python3 "$D/convert.py" "$D/json/$op.json" "$D/vec/$op.vec" "$LIM"
    echo "  $op.vec: $LIM cases"
done
