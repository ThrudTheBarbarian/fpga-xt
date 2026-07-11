#!/bin/sh
# Build a self-contained XTOS desktop test environment for the SDL host build,
# mirroring the SD card layout the desktop expects (OS/Themes, OS/var/registry.db,
# OS/Icons, Media/...).  Needs sqlite3 + ImageMagick 7 (magick).
#   Usage:  gem/tools/mk-testenv.sh [BASE]      (default /private/tmp/xtdesk-env)
#   Run:    gem/build/gem_xtdesk <BASE>         (interactive SDL desktop)
set -e
here=$(cd "$(dirname "$0")/.." && pwd)          # gem/
repo=$(cd "$here/.." && pwd)
BASE=${1:-/private/tmp/xtdesk-env}
rm -rf "$BASE"; mkdir -p "$BASE"

# --- theme (the rebaked Aristo2 atlas) + the "Default" marker naming it ------
mkdir -p "$BASE/OS/Themes/Aristo2/1x"
cp "$here"/themes/Aristo2/1x/artwork.tex "$here"/themes/Aristo2/1x/locations.txt \
   "$here"/themes/Aristo2/1x/theme.ini "$BASE/OS/Themes/Aristo2/1x/"
printf 'Aristo2\n' > "$BASE/OS/Themes/Default"      # load_theme reads this name

# --- label font (icon/window text) -------------------------------------------
mkdir -p "$BASE/OS/fonts"
cp "$here/fonts/AovelSansRounded.ttf" "$BASE/OS/fonts/"

# --- registry (desktop icons, icon types, context menus, mime -> app) --------
mkdir -p "$BASE/OS/var"
sqlite3 "$BASE/OS/var/registry.db" < "$repo/loader/test/freertos/Registry.sql"

# --- icons: convert the registry's icons from iconSrc PNGs to PAM (the same
#     PNG->PAM step the SD build does), gem/icons for the custom xe/st art -------
ic="$BASE/OS/Icons"
# mkicon <target-under-OS/Icons> <source .png|.pam>  (PNG -> 48px RGBA PAM)
mkicon() {
    t="$ic/$1"; mkdir -p "$(dirname "$t")"
    case "$2" in
        *.pam) [ -f "$2" ] && cp "$2" "$t" ;;
        *)     [ -f "$2" ] && magick "$2" -resize 48x48 -background none -depth 8 "PAM:$t" ;;
    esac
    [ -f "$t" ] || magick -size 48x48 xc:'#8a8a90' -depth 8 "PAM:$t"   # last-resort placeholder
}
mkicon retro/xe.pam                              "$here/icons/xe.pam"
mkicon retro/st.pam                              "$here/icons/st.pam"
mkicon retro/floppy525.pam                       "$repo/iconSrc/devices/media-floppy-3.5.png"
mkicon retro/floppy35.pam                        "$repo/iconSrc/devices/media-floppy-3.5.png"
mkicon devices/network-nfs.pam                   "$repo/iconSrc/devices/network-nfs.png"
mkicon places/crystal_clear-style/folder-blue.pam "$repo/iconSrc/actions/folder-new.png"
mkicon mimetypes/crystal-style/text-x-plain.pam  "$repo/iconSrc/mimetypes/crystal-style/text-x-plain.png"
mkicon actions/document-open-remote.pam          "$repo/iconSrc/actions/document-open-remote.png"
mkicon actions/folder-new-7.pam                  "$repo/iconSrc/actions/folder-new-7.png"

# --- Media fixtures: 8-bit (6502) + 16-bit (m68k), varied types/attrs --------
g="$BASE/Media/6502/Games"; mkdir -p "$g"
for n in DespatchRider ElektraGlide River_Raid Boulder_Dash Miner_2049er; do
    head -c 2048 /dev/zero > "$g/$n.atr"
done
mkdir -p "$BASE/Media/6502"
printf 'XTOS 6502 media notes.\n' > "$BASE/Media/6502/readme.txt"
printf '# Loader\nboot order...\n'  > "$BASE/Media/6502/loader.md"
mkdir -p "$BASE/Media/m68k"
for n in Xenon2 Llamatron; do head -c 4096 /dev/zero > "$BASE/Media/m68k/$n.st"; done
printf 'notes\n' > "$BASE/Media/m68k/notes.txt"
# varied access attributes for the columns view (x / read-only / hidden)
printf '#!/bin/sh\necho hi\n' > "$g/run.sh";    chmod 755 "$g/run.sh"
printf 'locked\n'            > "$g/config.ini"; chmod 444 "$g/config.ini"
printf 'hidden\n'            > "$g/.dotfile"
mkdir -p "$g/subdir"

# --- harness fixtures (the headless --* flags read these) --------------------
m="$BASE/navtest/many"; mkdir -p "$m"
for n in pic1.gif pic2.gif screen.gif notes.txt readme.md a.xex b.xex logo.gif; do : > "$m/$n"; done
for i in $(seq -w 1 12); do : > "$m/item_$i.atr"; done
for d in subdir_a subdir_b subdir_c pics docs data games; do mkdir -p "$m/$d"; done
b="$BASE/navtest/big"; mkdir -p "$b"
for i in $(seq -w 1 120); do : > "$b/file_$i.atr"; done
mkdir -p "$BASE/navtest/a/b/c"
: > "$BASE/navtest/root.xex"                     # a file at the navtest root
: > "$BASE/navtest/a/b/c/leaf1.xex"
: > "$BASE/navtest/a/b/c/leaf2.atr"

echo "test env ready at $BASE"
echo "run:  $repo/gem/build/gem_xtdesk $BASE"
