#!/bin/sh
# Regenerate the titlebar button sprites: a brushed-metal disc + a Google Material
# Symbol scaled to fit, downsampled to the 20x20 titlebar sprite size.  Needs
# ImageMagick 7 (magick) + rsvg-convert.  Outputs to icons/titlebar/, which themepack
# overlays onto the Aristo2 atlas (recipe tokens close/maximize/view/fit + .inactive).
#   close    <- Close           (window close button)     [X]
#   maximize <- Add             (window maximize)         [plus]
#   view     <- Select Window 2 (view-mode popup)         [two window frames]
#   fit      <- Open With       (scale-to-fit)            [4-way expand arrows]
# Two variants per button:
#   <name>          ACTIVE  : dark brushed disc (texture-circle.png) + WHITE glyph
#   <name>.inactive INACTIVE: light silver disc (texture-circle-light.png) + muted
#                             grey glyph — lower contrast, for unfocused windows.
set -e
SZ=${SZ:-20}
here=$(cd "$(dirname "$0")/.." && pwd)          # gem/
mat="$here/icons/material"
out="$here/icons/titlebar"
tmp=$(mktemp -d)

# gen <out-name> <svg-basename> <glyph-hex>   (uses $tmp/circ.png as the disc)
gen() {
  rsvg-convert -w 330 -h 330 "$mat/$2.svg" -o "$tmp/g.png"
  magick "$tmp/g.png" -fill "#$3" -colorize 100% -background none -gravity center -extent 512x512 "$tmp/glyphc.png"
  magick "$tmp/glyphc.png" \( +clone -background black -shadow 55x5+0+0 \) +swap -background none -layers merge +repage "$tmp/glyph.png"
  magick "$tmp/circ.png" "$tmp/glyph.png" -gravity center -composite -filter Lanczos -resize ${SZ}x${SZ} "$out/$1.png"
}

# --- ACTIVE: dark disc, white glyphs -----------------------------------------
magick "$here/icons/texture-circle.png" -resize 512x512 -modulate 112 "$tmp/circ.png"
gen close    close           ffffff
gen maximize add             ffffff
gen view     select_window_2 ffffff
gen fit      open_with       ffffff

# --- INACTIVE: light silver disc, muted grey glyphs --------------------------
magick "$here/icons/texture-circle-light.png" -resize 512x512 "$tmp/circ.png"
gen close.inactive    close           606060
gen maximize.inactive add             606060
gen view.inactive     select_window_2 606060
gen fit.inactive      open_with       606060

rm -rf "$tmp"
echo "wrote $out/{close,maximize,view,fit}{,.inactive}.png"
