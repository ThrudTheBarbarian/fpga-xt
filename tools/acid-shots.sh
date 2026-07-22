#!/bin/sh
# acid-shots.sh - capture ACID800 result screens for named tests.
#
# The sweep records only pass or fail. This grabs the framework result screen,
# which carries the assertion text - and the value in that text IS the cycle
# delta, so it is what makes a failure diagnosable. Decoded back to text on the
# Mac by tools/bmp2text.py.
#
# Kept SEPARATE from acid-sweep.sh on purpose: that script is parsed by toysh,
# which mis-parses quote and dollar characters in comments and dislikes nested
# if inside elif. Adding this to it broke the sweep outright.
#
# Mac side:
#   ssh BOARD cat GT /media/6502/acid-shots.sh LT tools/acid-shots.sh
#   ssh BOARD sh /media/6502/acid-shots.sh name1 name2 ...
#   ssh BOARD tar cf - -C /media/6502/acid-shots . GT shots.tar
#
# NOTE: graboverlay stdout is LOST to a plain board-side file redirect, exactly
# like 6502 status and dmesg. It has to go through a pipe.
# NOTE: shots go on the SD card - /tmp is a small ramfs and 184KB grabs fill it.

ACID_DIR=/media/6502/acid
SHOTS=/media/6502/acid-shots

mkdir -p "$SHOTS"

for name in "$@"; do
    xex="$ACID_DIR/$name.xex"
    [ -e "$xex" ] || continue
    printf '%-24s ' "$name"

    6502 break off > /dev/null 2>&1
    6502 go        > /dev/null 2>&1

    if xexload -h "$xex" > /dev/null 2>&1; then
        sleep 3
        graboverlay | cat > "$SHOTS/$name.bmp"
        echo grabbed
    else
        echo loadfail
    fi

    6502 break off > /dev/null 2>&1
    6502 go        > /dev/null 2>&1
done
