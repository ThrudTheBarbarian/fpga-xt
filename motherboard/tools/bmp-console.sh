#!/bin/sh
# bmp-console.sh — RTT terminal on the STM32 via the Black Magic Probe.
#
# The board has no spare debug UART: J17 brings out SWDIO/SWCLK/NRST but not
# SWO, and PB3 (TRACESWO) is spent on USART1_RX for the SIO port.  So the
# console rides RTT — ring buffers in target RAM that the probe reads and
# writes over SWD while the CPU keeps running.
#
# The probe serves RTT only while a debugger session is live and the target is
# running, so gdb is held open in the background on the GDB port while a
# terminal runs on the probe's second CDC port.
#
#   usage: bmp-console.sh [gdb-port] [elf]
#
set -eu

BMP=${1:-$(ls /dev/cu.usbmodem*1 2>/dev/null | head -1)}
ELF=${2:-}

[ -n "$BMP" ] || { echo "no Black Magic Probe found"; exit 1; }

# The probe enumerates two CDC ports; the GDB one ends in 1, the aux (RTT and
# passthrough UART) one ends in 3.
AUX=$(printf '%s' "$BMP" | sed 's/1$/3/')
[ -e "$AUX" ] || { echo "aux port $AUX not present"; exit 1; }

GDB=arm-none-eabi-gdb
LOG=$(mktemp -t bmp-console)

cleanup() {
    [ -n "${GDBPID:-}" ] && kill "$GDBPID" 2>/dev/null || true
    stty sane 2>/dev/null || true
    rm -f "$LOG"
}
trap cleanup EXIT INT TERM

echo "probe   $BMP"
echo "console $AUX"

$GDB -nx -q ${ELF:+"$ELF"} \
    -ex 'set confirm off' \
    -ex 'set pagination off' \
    -ex 'set mem inaccessible-by-default off' \
    -ex "target extended-remote $BMP" \
    -ex 'monitor swd_scan' \
    -ex 'attach 1' \
    -ex 'monitor rtt enable' \
    -ex 'continue' \
    > "$LOG" 2>&1 &
GDBPID=$!

# give the probe time to scan RAM for the control block
sleep 3

if ! kill -0 "$GDBPID" 2>/dev/null; then
    echo "gdb exited:"
    cat "$LOG"
    exit 1
fi

grep -i 'rtt' "$LOG" || true
echo "--- ctrl-A k to quit (screen) ---"

exec screen "$AUX" 115200
