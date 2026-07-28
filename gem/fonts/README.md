# GEM UI fonts

The font directory the VDI maps at boot. `vst_load_fonts` scans it and assigns ids
2..N in filename order; id 1 is the system face, named by the `System.font` pointer
file (our portable stand-in for a symlink, since FAT has none). `vdi_font_name`
reports each face's name — which is the *filename* sans extension, so those are the
names a font chooser lists and `vst_font` matches against.

On the target this directory is `/OS/fonts`; the hostgem shim redirects that path
here (`XG/hostgem/xtos_host.c`), so the macOS/SDL build enumerates the same faces.
Faces are opened lazily by the FreeType-backed font module (`gem/font.c`) on first
selection. Drop additional TTF/OTF files here and they appear on the next boot — no
code change.

## Licensing

Every file below is redistributable, but on different terms; check before adding more.

| File | Family | Designer | Licence |
|---|---|---|---|
| `AovelSansRounded.ttf` | Aovel Sans Rounded | Álvaro Thomáz (DMF) | Freeware — [fontspace](https://www.fontspace.com/aovel-sans-rounded-font-f12477) |
| `EBGaramond.ttf` | EB Garamond | Georg Duffner, Octavio Pardo | SIL OFL 1.1 |
| `Lobster.ttf` | Lobster | Impallari Type | SIL OFL 1.1 — RFN "Lobster" |
| `Lora.ttf` | Lora | Olga Karpushina, Alexei Vanyashin | SIL OFL 1.1 — RFN "Lora" |
| `Oswald.ttf` | Oswald | Vernon Adams | SIL OFL 1.1 |
| `Pacifico.ttf` | Pacifico | Vernon Adams | SIL OFL 1.1 |
| `PlayfairDisplay.ttf` | Playfair Display | Claus Eggers Sørensen | SIL OFL 1.1 — RFN "Playfair Display" |
| `RobotoMono.ttf` | Roboto Mono | Christian Robertson (Google) | SIL OFL 1.1 |

The seven OFL faces came from [Google Fonts](https://fonts.google.com/). Their licence
text, carrying each project's copyright notice, is bundled here as `OFL.txt` — the OFL
requires it to travel with the fonts. Every licence and copyright line above was read
out of the font's own `name` table (ids 0/9/13) rather than taken from a download page.

**RFN** = Reserved Font Name: a *modified* version of that face may not keep the
reserved name. Renaming the file is enough to change what a chooser lists (names come
from the filename), but the RFN applies to the font's internal names — a genuinely
modified font has to be renamed inside the file too.

Aovel Sans Rounded predates the rest: it is the historical `v_gtext` / window-title
face and is what `System.font` points at, so removing it changes the whole UI's look.
