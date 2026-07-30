#!/bin/sh
#
# NOT VALID YET — DO NOT TRUST RESULTS FROM THIS HARNESS.
#
# It runs the test image with NO OS ROM.  The ACID framework installs handlers
# in the OS vectors (VDSLST, VVBLKI) and relies on the OS ROM's NMI dispatcher
# at $FFFA to read NMIST and jump through them.  The XEX does not cover $FFFA —
# antic_vcount's segments are $1A20-$1F30, $2000-$21F2, $02E0-$02E1 — so with
# no ROM that vector is RAM, reads as zero, and the first DLI or VBI kills the
# machine.  There is also no VBI, no SIO and no E: handler.
#
# A result out of this harness therefore means nothing, and it will still print
# a confident PASS or FAIL, which is worse than printing nothing.
#
# What it needs to be real: RAM + the XL OS ROM at $C000 (rsrc/atari-xl.rom) +
# PIA for PORTB banking (pia_regs.sv) + POKEY (pokey.sv) + the display chips,
# cold-booted, with the XEX injected afterwards the way loader/test/freertos/
# progs/xexload.c does it on the board.  Every piece is already in the repo.
#

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
