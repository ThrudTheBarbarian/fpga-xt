#!/bin/sh
# sdpush.sh — mirror the staged /OS tree to a running XTOS board over TFTP, so
# you can update the SD card without ejecting it. Pushes only files whose
# contents changed since the last push (tracked in a local md5 manifest), then
# you cold-load the kernel to pick everything up.
#
#   tools/sdpush.sh [STAGEDIR] [BOARD]
#     STAGEDIR  default build/sdstage   (produced by `make sdstage`)
#     BOARD     default xtos.local      (mDNS; or an IP)
#
# The board must be booted with networking up (its tftpd listening). Parent
# directories must already exist on the card (a provisioned /OS); TFTP creates
# files, not directories.
set -eu

STAGE="${1:-build/sdstage}"
BOARD="${2:-xtos.local}"
MANIFEST="build/.sdpush-manifest.$BOARD"
BLK=1428

[ -d "$STAGE/OS" ] || { echo "sdpush: no $STAGE/OS — run 'make sdstage' first" >&2; exit 1; }
command -v curl >/dev/null || { echo "sdpush: curl not found" >&2; exit 1; }

# reachability: a quick TFTP GET of a file that always exists
echo "sdpush: probing $BOARD ..."
if ! curl -s --connect-timeout 5 --max-time 8 "tftp://$BOARD/OS/bin/toybox" -o /dev/null 2>/dev/null; then
    # a GET of a maybe-absent file still proves the server answered; only a
    # total failure (no route / not booted) trips this
    if ! curl -s --connect-timeout 5 --max-time 8 "tftp://$BOARD/OS/" -o /dev/null 2>/dev/null; then
        echo "sdpush: $BOARD not reachable — is the board booted with the network up?" >&2
        echo "        (try: ping $BOARD ; or pass an IP: make sdpush BOARD=192.168.x.y)" >&2
        exit 1
    fi
fi

touch "$MANIFEST"
new="$MANIFEST.new"; : > "$new"
changed="$(mktemp)"; : > "$changed"

# find changed files (md5 differs from the manifest), rebuild the manifest
( cd "$STAGE" && find OS -type f | sort ) | while IFS= read -r rel; do
    sum=$(md5 -q "$STAGE/$rel" 2>/dev/null || md5sum "$STAGE/$rel" | cut -d' ' -f1)
    echo "$sum  $rel" >> "$new"
    old=$(grep -F "  $rel" "$MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f1)
    [ "$sum" = "$old" ] || echo "$rel" >> "$changed"
done

nchanged=$(wc -l < "$changed" | tr -d ' ')
if [ "$nchanged" = 0 ]; then
    echo "sdpush: nothing changed since the last push to $BOARD"
    rm -f "$new" "$changed"
    exit 0
fi

echo "sdpush: $nchanged changed file(s) -> $BOARD"
fail=0
while IFS= read -r rel; do
    printf '  -> /%s ... ' "$rel"
    if curl -s --tftp-blksize "$BLK" --max-time 60 -T "$STAGE/$rel" "tftp://$BOARD/$rel"; then
        echo ok
    else
        echo FAILED; fail=1
    fi
done < "$changed"

if [ "$fail" = 0 ]; then
    mv "$new" "$MANIFEST"          # commit the manifest only if every push succeeded
    echo "sdpush: done. Cold-load the kernel (jumpers=JTAG, power-cycle) to pick up changes."
else
    rm -f "$new"                   # a failure -> next run retries everything unpushed
    echo "sdpush: some files failed; manifest not updated (they'll retry next run)." >&2
fi
rm -f "$changed"
exit "$fail"
