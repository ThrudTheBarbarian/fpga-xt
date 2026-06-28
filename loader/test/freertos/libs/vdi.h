/* vdi.h — tiny VDI surface API exported by libGEM.so (RGBA-8888, 0xRRGGBBAA). */
#ifndef VDI_H
#define VDI_H
#include <stdint.h>
typedef struct { uint32_t *px; int w, h; } vdi_surface;
void v_clear (vdi_surface *s, uint32_t rgba);
void v_bar   (vdi_surface *s, int x, int y, int w, int h, uint32_t rgba);
void v_pline (vdi_surface *s, int x0, int y0, int x1, int y1, uint32_t rgba);
void v_circle(vdi_surface *s, int cx, int cy, int r, uint32_t rgba);
#endif
