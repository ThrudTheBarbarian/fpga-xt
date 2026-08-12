#!/bin/sh
# rtt-gdb.sh — send one REPL command and print the reply, using nothing but
# gdb's memory access.
#
# This is the fallback console for a probe whose firmware was built without
# RTT (`monitor rtt` reports "Target does not support this command").  It pokes
# the command into the RTT down buffer, lets the target run, then reads the up
# buffer back.  Slower and clunkier than a real terminal — each command costs
# an attach/detach pair — but it needs no extra wires and no probe reflash, and
# it is enough to bring a board up.
#
# For an interactive console use one of:
#   - a probe with RTT enabled  (tools/bmp-console.sh)
#   - USART2 on PA2/PA3 to a USB-serial adapter, 115200 8N1
#
#   usage: rtt-gdb.sh "<command>" [gdb-port] [elf]
#
set -eu

CMD=${1:?usage: rtt-gdb.sh "<command>" [port] [elf]}
BMP=${2:-$(ls /dev/cu.usbmodem*1 2>/dev/null | head -1)}
ELF=${3:-build/xtio.elf}

[ -n "$BMP" ] || { echo "no Black Magic Probe found"; exit 1; }

GDB=arm-none-eabi-gdb
SCRIPT=$(mktemp -t rttgdb)
trap 'rm -f "$SCRIPT"' EXIT

# Phase 1: clear the ring, stage the command, resume.
{
    echo 'set confirm off'
    echo 'set pagination off'
    echo 'set mem inaccessible-by-default off'
    echo "target extended-remote $BMP"
    echo 'monitor connect_rst disable'
    echo 'monitor swd_scan'
    echo 'attach 1'
    echo 'set var _SEGGER_RTT.up[0].wr = 0'
    echo 'set var _SEGGER_RTT.up[0].rd = 0'
    echo 'set var _SEGGER_RTT.down[0].rd = 0'
    i=0
    len=${#CMD}
    while [ "$i" -lt "$len" ]; do
        i=$((i + 1))
        c=$(printf '%s' "$CMD" | cut -c "$i")
        printf "set var _SEGGER_RTT.down[0].buffer[%d] = '%s'\n" "$((i - 1))" "$c"
    done
    printf 'set var _SEGGER_RTT.down[0].buffer[%d] = 13\n' "$len"
    printf 'set var _SEGGER_RTT.down[0].wr = %d\n' "$((len + 1))"
    echo 'detach'
} > "$SCRIPT"

$GDB -batch -x "$SCRIPT" "$ELF" >/dev/null 2>&1

sleep 1

# Phase 2: read back exactly the bytes the REPL wrote.  Reading the buffer as
# a C string would run past the new output into whatever the previous command
# left behind, since phase 1 rewinds the write pointer but does not scrub the
# ring.
OUT=$(mktemp -t rttout)
trap 'rm -f "$SCRIPT" "$OUT"' EXIT

cat > "$SCRIPT" <<EOF
set confirm off
set pagination off
set mem inaccessible-by-default off
target extended-remote $BMP
monitor swd_scan
attach 1
dump binary memory $OUT _SEGGER_RTT.up[0].buffer (_SEGGER_RTT.up[0].buffer + _SEGGER_RTT.up[0].wr)
detach
EOF

$GDB -batch -x "$SCRIPT" "$ELF" >/dev/null 2>&1
cat "$OUT"
