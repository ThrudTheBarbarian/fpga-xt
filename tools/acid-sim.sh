#!/bin/sh
# acid-sim.sh — run ACID800 tests against the ANTIC rewrite in SIMULATION.
#
# This is not the hardware sweep (tools/acid-sweep.sh).  It runs each test
# against a8_core in iverilog, which needs no bitstream and so can be used while
# the rewrite is still off to one side of fpga_xt_top.  It is much slower: tens
# of seconds per test rather than under one.
#
# Same result convention as the board: break at the ACID framework's _testEnd
# and classify Y — $00 pass, $80 fail.
#
#   tools/acid-sim.sh antic_vcount antic_wsync ...
#   tools/acid-sim.sh            # every antic_/gtia_ standalone test
set -e
cd "$(dirname "$0")/.."
LIST="$*"
if [ -z "$LIST" ]; then
    LIST=$(ls rsrc/acid800/Acid800/standalone/ | grep -E '^(antic|gtia)_.*\.xex$' | sed 's/\.xex$//')
fi
OUT=/tmp/acid-sim.tsv
: > "$OUT"
for t in $LIST; do
    if ! python3 tools/acid2mem.py "$t" >/dev/null 2>&1; then
        printf '%s\tna\n' "$t" >> "$OUT"; echo "$t: na (no image)"; continue
    fi
    r=$(cd sim && make -s acid TEST="$t" 2>/dev/null | grep -oE 'ACID .*: (PASS|FAIL|TIMEOUT)' | tail -1)
    case "$r" in
        *PASS)    printf '%s\tpass\n'    "$t" >> "$OUT"; echo "$t: pass" ;;
        *FAIL*)   printf '%s\tfail\n'    "$t" >> "$OUT"; echo "$t: fail" ;;
        *TIMEOUT) printf '%s\ttimeout\n' "$t" >> "$OUT"; echo "$t: timeout" ;;
        *)        printf '%s\terror\n'   "$t" >> "$OUT"; echo "$t: error" ;;
    esac
done
echo "--- $OUT ---"
