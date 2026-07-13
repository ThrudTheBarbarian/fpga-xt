# TASK: restore wallpaper to the desktop

**Status: OPEN.** Wallpaper support was **lost** when the old `desktop.c` (the `gem_wm` demo)
was retired and `aesdesk` took its name (2026-07-13). This file preserves the code and — more
importantly — the reason a straight copy-paste **will not work**.

`aesdesk`/`desktop` has **no wallpaper support at all**. It sets a flat colour:

```c
wind_set_desktop(0x30507800u);      /* progs/desktop.c (was aesdesk.c) */
```

## ⚠ Why this is not a copy-paste

The two programs made **incompatible** use of the same DDR region, `WALLPAPER_BASE`
(`0x3300_0000`, 16 MB, `SEC_PLANE_C` — PL0-RW **cacheable**):

| | how it used `WALLPAPER_BASE` |
|---|---|
| **old `desktop.c`** | as a **backdrop**: decode the wallpaper image into it once, bake the icon labels in, and let the WM blit *from* it when erasing behind a moved window (`gem/wm.c:360-365`). |
| **`aesdesk` (now `desktop`)** | as its **entire cacheable compositing back-buffer** (`g_bb`). Everything is drawn there and only dirty rects are pushed to the scanned plane. |

So the region is **already spoken for**, and it is load-bearing. The wallpaper surface needs a
**new home** — and it is not small: a 1080p RGBA backdrop is ~8 MB, which the original code
notes is too big for the per-process heap.

> This also corrects a claim in `RESPONSIBILITIES.md`: `WALLPAPER_BASE` was described as
> "probably redundant" under the gemd design. It is **not** redundant — it is *repurposed*, and
> the current desktop depends on it.

## The design question to answer first

Under the gemd design (§4) the desktop is **an ordinary app** and its wallpaper is **content**,
drawn into its **own backing store** — not a special plane every process can write. So the
right restoration is probably *not* "put the backdrop back in `WALLPAPER_BASE`", but "the
desktop app decodes its wallpaper into its own surface and draws it as the bottom layer of its
own content". That fits the phase-1 plan and does not need a privileged region at all.

Decide that before writing code. Restoring the old mechanism would add a user of a region that
is scheduled to go **PL0-none** (see §2/§14: the whole `SEC_PLANE` range, decided 2026-07-13).

## The harvested code (from the retired `desktop.c`)

Both functions operated on a `gfx_surface` pointing at the wallpaper DDR buffer.

```c
/* Vertical gradient fallback backdrop (deep blue -> desktop blue). */
static void gradient(gfx_surface *wp)
{
    for (int y = 0; y < wp->h; y++) {
        int t = wp->h > 1 ? y * 255 / (wp->h - 1) : 0;
        uint8_t r = (uint8_t)(0x1a + (0x30 - 0x1a) * t / 255);
        uint8_t g = (uint8_t)(0x2a + (0x50 - 0x2a) * t / 255);
        uint8_t b = (uint8_t)(0x40 + (0x78 - 0x40) * t / 255);
        uint32_t c = GFX_RGB(r, g, b);
        uint32_t *row = wp->px + (size_t)y * wp->stride;
        for (int x = 0; x < wp->w; x++) row[x] = c;
    }
}

/* Decode the user's wallpaper (named by /OS/wallpaper/Default) into the backdrop
 * buffer; fall back to a gradient if the SD isn't there or the file won't parse
 * (e.g. not a P6/P7 image, or not exactly plane-sized). */
static void load_wallpaper(gfx_surface *wp)
{
    char name[128], path[192];
    if (read_default("/OS/wallpaper", name, sizeof name)) {
        snprintf(path, sizeof path, "/OS/wallpaper/%s", name);
        if (img_load(path, wp)) return;
    }
    gradient(wp);
}
```

`read_default()` (the one-line `<dir>/Default` selector reader) already exists in the current
`desktop.c` — it survived the rename, since `aesdesk` had a verbatim twin of it for themes.
`img_load()` (P6/P7 decode) is in `gem/img.c` and is still live.

`/OS/wallpaper/` is **user content on the SD card** — the build stages nothing there, so no
asset is missing; only the code to read it.

Full original: `git show 9929aa0:loader/test/freertos/progs/desktop.c` (the commit before the
rename).
