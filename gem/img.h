// img.h — tiny Netpbm image loader for the GEM core (wallpaper + icons).
//
// The target has no PNG decoder (and on-target PNG decode was slow), so desktop
// artwork ships as Netpbm: P6 (binary PPM, RGB -> opaque RGBA) for the opaque
// wallpaper, P7 (binary PAM, RGB_ALPHA / GRAY[_ALPHA]) for icons that need a
// transparent surround.  Both are plain formats any tool can emit
// (`convert road.png road.ppm`, `convert xe.png xe.pam`) and parse as a header
// plus one bulk read — no decompression.  One pixel format out: RGBA-8888.

#ifndef GEM_IMG_H
#define GEM_IMG_H

#include "gfx.h"

// Load a Netpbm image.  If `dst` != NULL its dimensions MUST equal the image's:
// the pixels are decoded straight into `dst` (no allocation) and `dst` is
// returned — used to fill the OS-owned wallpaper DDR buffer without a heap copy.
// If `dst` == NULL a surface sized to the image is allocated (free it with
// gfx_surface_free).  Returns NULL on open/format error or size mismatch.
gfx_surface *img_load(const char *path, gfx_surface *dst);

// Box-average resample `src` to a new dw x dh surface (free with
// gfx_surface_free) — used to scale icons to the system default size.  NULL on
// failure.  Handles up- and down-scaling; alpha is resampled with the colour.
gfx_surface *img_scale(const gfx_surface *src, int dw, int dh);

// Src-over composite (per-pixel alpha) of `src` onto `dst` at (dx,dy), clipped
// to `dst`.  For baking transparent icons onto the opaque wallpaper backdrop.
void img_blit_over(gfx_surface *dst, int dx, int dy, const gfx_surface *src);

#endif // GEM_IMG_H
