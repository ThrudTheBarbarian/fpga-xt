// vdi/clip_rects.c — vr_clip_rects_by_dst / _by_src (171, sub 0/1) and their
// 32-bit forms (sub 2/3): trim a vr_transfer_bits rectangle pair to a clip
// rectangle.  by_dst clips the destination and scales the source by the same
// fraction; by_src clips the source and scales the destination.  Pure geometry.
// ptsin: [0..3] clip rect, [4..7] src rect, [8..11] dst rect; the adjusted src
// + dst come back in ptsout[0..7].

#include "vdi/vdi.h"
#include "vdi/internal.h"

static double dmin(double a, double b) { return a < b ? a : b; }
static double dmax(double a, double b) { return a > b ? a : b; }

// Clip rect A to `clip`, and apply the same edge trims (scaled) to rect B.
static void clip_pair(const int16_t *clip, const double *A, const double *B,
                      double *outA, double *outB) {
    double aw = A[2] - A[0], ah = A[3] - A[1];
    double na0 = dmax(A[0], clip[0]), na1 = dmax(A[1], clip[1]);
    double na2 = dmin(A[2], clip[2]), na3 = dmin(A[3], clip[3]);
    double fx = aw != 0 ? (B[2] - B[0]) / aw : 0, fy = ah != 0 ? (B[3] - B[1]) / ah : 0;
    outA[0] = na0; outA[1] = na1; outA[2] = na2; outA[3] = na3;
    outB[0] = B[0] + (na0 - A[0]) * fx; outB[1] = B[1] + (na1 - A[1]) * fy;
    outB[2] = B[2] + (na2 - A[2]) * fx; outB[3] = B[3] + (na3 - A[3]) * fy;
}

void op_clip_rects(vdi_pb *pb) {
    int by_src = (pb->contrl[5] & 1);                   // sub 1/3 = by src, 0/2 = by dst
    const int16_t *clip = pb->ptsin;
    double src[4] = { pb->ptsin[4], pb->ptsin[5], pb->ptsin[6], pb->ptsin[7] };
    double dst[4] = { pb->ptsin[8], pb->ptsin[9], pb->ptsin[10], pb->ptsin[11] };
    double os[4], od[4];
    if (by_src) clip_pair(clip, src, dst, os, od);      // clip src, scale dst
    else        clip_pair(clip, dst, src, od, os);      // clip dst, scale src
    for (int i = 0; i < 4; i++) pb->ptsout[i]     = (int16_t)(os[i] < 0 ? os[i] - 0.5 : os[i] + 0.5);
    for (int i = 0; i < 4; i++) pb->ptsout[4 + i] = (int16_t)(od[i] < 0 ? od[i] - 0.5 : od[i] + 0.5);
}

// clip[4], pxy[8] = src(0..3)+dst(4..7); pxy is updated in place.
static void clip_rects(int handle, int sub, const int16_t *clip, int16_t *pxy) {
    for (int i = 0; i < 4; i++) g_ptsin[i] = clip[i];
    for (int i = 0; i < 8; i++) g_ptsin[4 + i] = pxy[i];
    vdi_emit(VDI_CLIP_RECTS, sub, handle, 6, 0);
    for (int i = 0; i < 8; i++) pxy[i] = g_ptsout[i];
}
void vr_clip_rects_by_dst(int handle, const int16_t *clip, int16_t *pxy) { clip_rects(handle, 0, clip, pxy); }
void vr_clip_rects_by_src(int handle, const int16_t *clip, int16_t *pxy) { clip_rects(handle, 1, clip, pxy); }

// 32-bit forms: our coordinate range fits in 16 bits, so fold to the same path.
static void clip_rects32(int handle, int sub, const int32_t *clip, int32_t *pxy) {
    int16_t c[4], p[8];
    for (int i = 0; i < 4; i++) c[i] = (int16_t)clip[i];
    for (int i = 0; i < 8; i++) p[i] = (int16_t)pxy[i];
    clip_rects(handle, sub, c, p);
    for (int i = 0; i < 8; i++) pxy[i] = p[i];
}
void vr_clip_rects32_by_dst(int handle, const int32_t *clip, int32_t *pxy) { clip_rects32(handle, 2, clip, pxy); }
void vr_clip_rects32_by_src(int handle, const int32_t *clip, int32_t *pxy) { clip_rects32(handle, 3, clip, pxy); }
