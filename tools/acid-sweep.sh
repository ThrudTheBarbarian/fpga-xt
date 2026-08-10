#!/bin/sh
# acid-sweep.sh - ON-BOARD ACID800 conformance sweep.
#
# Runs entirely on the fpga-xt board xtos/toysh userland, invoked by a SINGLE
# ssh from the Mac. The old method ran one ssh per test; Dropbear rate-limits
# after about 30 connections and the sweep collapses to garbage na results.
# This loops all tests locally and writes ONE file the Mac pulls once.
#
# Mac side — push the script as a FILE, then run it:
#   cat tools/acid-sweep.sh | ssh BOARD 'cat > /tmp/acid-sweep.sh'
#   ssh BOARD sh /tmp/acid-sweep.sh
#   ssh BOARD cat /tmp/acid-sweep.tsv > local.tsv
#   python3 docs/a800/tsv2run.py local.tsv
#
# NOT `ssh BOARD sh -s < tools/acid-sweep.sh` — on this board that runs LINE ONE
# and exits, so the sweep silently produces nothing. Use ONE ssh connection for
# the whole run (multiplex with -M/-S): Dropbear rate-limits after ~30 new
# connections and the sweep then collapses into `na` results.
#
# Per test: xexload -h cold-boots the fabric 6502 and runs the XEX with a HW
# breakpoint at the ACID framework _testEnd 1D93, so the CPU HALTS on the
# result. Poll 6502 status for HALTED, then classify the Y register:
# _testPassed sets Y to 00 for pass, _testFailed sets Y to 80 for fail.
# Then ALWAYS release the core - a halted 6502 wedges the desktop.
# Tests that never halt (65C816 probe, mod display-only modules) record na.
#
# TOYSH CONSTRAINTS - verified on HW 2026-07-21. Do NOT modernise this:
#   no command substitution - both forms silently produce nothing
#   no read builtin
#   no VAR:-default parameter expansion
#   no timeout, no awk, no date
#   comments must avoid quote and dollar characters - toysh mis-parses them
#   WORKING: prefix and suffix var expansion, integer arith, grep -q, printf,
#   case, for, while, if, globs, redirection, fractional sleep
# Consequence: values are never captured into variables. 6502 status is
# redirected to a temp file and every decision is a grep -q against it.
#
# Output: /tmp/acid-sweep.tsv, one line per test: name TAB result
# result is one of pass, fail, na, error. No detail column, so the Mac-side
# converter can carry forward the richer prior-run assertion text.

ACID_DIR=/media/6502/acid
OUT=/tmp/acid-sweep.tsv
ST=/tmp/_acid_status
POLL_INTERVAL=0.5
POLL_MAX=24           # 24 * 0.5s = 12s per-test ceiling
MAX_TRIES=6           # xexload -h is INTERMITTENT - loads fail often; retry hard

: > "$OUT"

n=0
for xex in "$ACID_DIR"/*.xex; do
    [ -e "$xex" ] || continue
    base=${xex##*/}
    name=${base%.xex}
    n=$((n + 1))
    printf '[%d] %-24s ' "$n" "$name" >&2

    # Environment-na (Simon's call, 2026-08-10): these need a physical SIO
    # device to NAK a command -- the paravirtual SIO cannot produce the bus
    # behavior they assert on, and the sim skips them for the same reason.
    # Greyed like the sim until the peri-RP serial bring-up delivers a real
    # bus; remove from this list at that point.
    case "$name" in
    pokey_serdirect|pokey_skstat)
        printf '%s\t%s\n' "$name" na >> "$OUT"
        echo "na (no serial bus)" >&2
        continue ;;
    esac

    # Retry ONLY a failed load. xexload exits 0 on success, so a non-zero rc is
    # the known flaky-load race and is worth another go. A load that succeeded
    # but never halted is a genuine na (65C816 probe, mod display modules) and
    # must NOT be retried - that would just burn the ceiling three more times.
    result=na
    loaded=0
    halted=0
    tries=0
    while [ "$tries" -lt "$MAX_TRIES" ]; do
        tries=$((tries + 1))
        6502 break off > /dev/null 2>&1
        6502 go        > /dev/null 2>&1
        if xexload -h "$xex" > /dev/null 2>&1; then
            loaded=1
            i=0
            while [ "$i" -lt "$POLL_MAX" ]; do
                # NOTE: 6502 status output survives a PIPE but is LOST to a file
                # redirect (yields 0 bytes), so never redirect it to a file.
                if 6502 status | grep -q HALTED; then
                    halted=1
                    break
                fi
                sleep "$POLL_INTERVAL"
                i=$((i + 1))
            done
            break
        fi
    done

    if [ "$loaded" -eq 0 ]; then
        result=error
    elif [ "$halted" -eq 1 ]; then
        # core is halted and therefore stable, so a second status call is safe
        result=fail
        if 6502 status | grep -q 'Y=.00'; then
            result=pass
        fi
    fi

    6502 break off > /dev/null 2>&1
    6502 go        > /dev/null 2>&1

    printf '%s\t%s\n' "$name" "$result" >> "$OUT"
    echo "$result" >&2
done

echo "acid-sweep: wrote $n results" >&2
