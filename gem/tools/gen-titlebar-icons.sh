#!/bin/sh
# Regenerate the titlebar button sprites: a brushed-metal disc (icons/texture-circle.png)
# with a white Google Material Symbol scaled to fit, downsampled to the 16x16 titlebar
# sprite size.  Needs ImageMagick 7 (magick) + rsvg-convert.  Outputs to icons/titlebar/,
# which themepack overlays onto the Aristo2 atlas (recipe: close/view/fit sprites).
#   close <- Close          (window close button)
#   fit   <- Open With       (scale-to-fit)     [4-way expand arrows]
#   view     <- Select Window 2 (view-mode popup)  [two window frames]
#   maximize <- Add             (window maximize)    [plus]
set -e
SZ=${SZ:-20}
here=$(cd "$(dirname "$0")/.." && pwd)          # gem/
circ="$here/icons/texture-circle.png"
mat="$here/icons/material"
out="$here/icons/titlebar"
tmp=$(mktemp -d)
magick "$circ" -resize 512x512 -modulate 112 "$tmp/circ.png"
gen() {  # <out-name> <svg-basename>
  rsvg-convert -w 330 -h 330 "$mat/$2.svg" -o "$tmp/g.png"
  magick "$tmp/g.png" -channel RGB -evaluate set 100% +channel -background none -gravity center -extent 512x512 "$tmp/white.png"
  magick "$tmp/white.png" \( +clone -background black -shadow 70x5+0+0 \) +swap -background none -layers merge +repage "$tmp/glyph.png"
  magick "$tmp/circ.png" "$tmp/glyph.png" -gravity center -composite -filter Lanczos -resize ${SZ}x${SZ} "$out/$1.png"
}
gen close close
gen fit   open_with
gen maximize add
gen view  select_window_2
rm -rf "$tmp"
echo "wrote $out/{close,view,fit}.png"
