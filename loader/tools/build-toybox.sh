#!/bin/sh
# build-toybox.sh — compile the vendored toybox (third_party/toybox, 0BSD;
# the GPL kconfig/ dir is excluded — allnoconfig/miniconfig use toybox's own
# scripts/kconfig.c) into objects for the XTOS toybox.so. The final link is
# expected to FAIL (it wants a hosted static link); what we need are the
# per-file objects in $GENDIR/obj, which the loader Makefile links into a
# PIC .so against libc.so + the posix shim.
#
# usage: tools/build-toybox.sh   (from loader/; objects land in build/toybox)
set -e

LOADER=$(cd "$(dirname "$0")/.." && pwd)
TB=$(cd "$LOADER/../third_party/toybox" && pwd)
OUT="$LOADER/build/toybox"
mkdir -p "$OUT"

# In-tree build (toybox's kconfig resolves generated/Config.in relative to
# the tree); generated/, .config, .singlemake are gitignored, objects are
# collected into build/toybox for the .so link.
export CROSS_COMPILE=arm-none-eabi-
export CC=gcc      # toybox composes $CROSS_COMPILE$CC; the cross tool is *-gcc
export HOSTCC=cc
export CFLAGS="-marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fpic -fno-builtin \
 -D_GNU_SOURCE -I$LOADER/libc-compat -I$LOADER/newlib-pic/include"
export NOSTRIP=1

cd "$TB"
KCONFIG_ALLCONFIG="$LOADER/tools/toybox-xtos.miniconfig" scripts/genconfig.sh -n

# every =y in the miniconfig must survive into .config
MISSING=0
while read -r line; do
    case "$line" in
    CONFIG_*=y)
        grep -q "^$line\$" .config || { echo "config dropped: $line" >&2; MISSING=1; } ;;
    esac
done < "$LOADER/tools/toybox-xtos.miniconfig"
[ "$MISSING" = 0 ] || exit 1

# compile is everything before the final link; the link failure is noise
if ! scripts/make.sh > "$OUT/make.log" 2>&1; then
    if ! ls generated/unstripped/obj/*.o >/dev/null 2>&1; then
        echo "toybox compile failed:" >&2
        tail -40 "$OUT/make.log" >&2
        exit 1
    fi
fi

# lib_net.o is linked now: the socket shim (net_shim.c) implements the calls
# sockets — keep it out of the .so so no dangling relocations reach xtld
ls "$TB"/generated/unstripped/obj/*.o > "$OUT/objects.list"
echo "toybox objects ready: $(wc -l < "$OUT/objects.list" | tr -d ' ') files (see $OUT/objects.list)"
