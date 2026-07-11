// aes/rsc.h — the ONE shared, portable GEM `.rsc` codec (read AND write).
//
// This is the single source of truth for the GemRCS / classic-GEM resource
// format.  It owns one in-memory model and both directions run over it:
//
//     rsc_load(path)  : parse a .rsc  -> model
//     rsc_save(r,path): serialise model -> .rsc   (byte-exact inverse of load)
//
// It is meant to be used unchanged by:
//   * the XTOS AES runtime  — rsc_load a .rsc, rsc_tree() a tree, hand the
//     returned OBJECT* straight to objc_draw / form_do (it is exactly what a
//     classic rsrc_gaddr(R_TREE, i) returns: the tree root, children reachable
//     by tree-relative ob_head/ob_tail/ob_next);
//   * an authoring tool (gem/tools/mkrsc.c) — build a model with the builder
//     API below, then rsc_save it;
//   * later, the GemRCS editor at ~/src/fpga-gem — its GRsc.m reader/writer
//     could be reimplemented as a thin Objective-C wrapper over this codec
//     (GRscRead -> rsc_load + walk trees; GRscWrite -> build model + rsc_save),
//     retiring the second implementation.  (Do not change fpga-gem here.)
//
// PORTABILITY: portable C only (libc: stdio/stdlib/string).  No ObjC, no SDL,
// no host-only APIs.  Compiles with clang for the Mac and with
// arm-none-eabi-gcc into libGEM for the A9.  All wire values are BIG-ENDIAN
// regardless of host (Atari-ST / 68000 convention); a little-endian file is
// accepted on read as a fallback, but write is always big-endian.
//
// The wire layout, offsets, extensions (extended widget types 40..44, embedded
// P7 PAM for G_IMAGE/G_CICON, the G_POPUP high-byte linked-tree index, Latin-1
// strings, char/pixel 8x16-packed coordinates, tree-relative indices) match
// fpga-gem/src/GRsc.m exactly; see fpga-gem/RSC-FORMAT.md for the spec.

#ifndef GEM_AES_RSC_H
#define GEM_AES_RSC_H

#include "aes/aes.h"      // OBJECT, TEDINFO, G_*, OF_*, OS_*

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rsc rsc;   // owns OBJECT[] trees, strings, TEDINFOs, images

// ---- read / write ---------------------------------------------------------
// Parse a GemRCS/classic .rsc into a model.  NULL on open / format error.
rsc  *rsc_load(const char *path);
// Serialise the model to a GemRCS big-endian .rsc.  0 on success, -1 on error.
int   rsc_save(const rsc *r, const char *path);
// Serialise into a freshly malloc'd buffer instead of a file (caller frees
// *out).  Returns the byte length, or 0 on error.  (Used by the round-trip
// test to compare two streams for byte-identity.)
long  rsc_save_mem(const rsc *r, unsigned char **out);
void  rsc_free(rsc *r);

// ---- consume (AES runtime) ------------------------------------------------
// Root OBJECT of tree `index`, ready for objc_draw / form_do (== the pointer a
// classic rsrc_gaddr(R_TREE, index) hands back).  ob_spec is resolved per type:
// a char* for G_STRING/BUTTON/TITLE/CHECKBOX/RADIO/POPUP, a TEDINFO* for the
// editable/text types, NULL for boxes/icons.  NULL if index is out of range.
OBJECT *rsc_tree(rsc *r, int index);
int     rsc_ntree(const rsc *r);
// Number of objects in tree `index` (root + descendants), -1 if out of range.
int     rsc_tree_nobs(const rsc *r, int index);
// The G_POPUP linked-menu-tree index stored in an object's ob_type high byte
// (0 = none); -1 if the tree/obj index is out of range.
int     rsc_popup_link(const rsc *r, int tree, int obj);
// Raw embedded P7 PAM bytes for a G_IMAGE / G_CICON object (NULL if none); the
// length is returned via *len.  The blob is owned by the model — decode it with
// img.c at the use site (kept out of the codec so rsc.c stays libc-only).
const unsigned char *rsc_image_pam(const rsc *r, int tree, int obj, int *len);

// ---- build (authoring tool) -----------------------------------------------
// Construct a model in memory, then rsc_save it.  Object indices returned and
// taken by these calls are TREE-RELATIVE (the root is 0), matching the AES.
rsc *rsc_new(void);
// Append an empty tree; returns its index.
int  rsc_add_tree(rsc *r);
// Add an object to tree `tree` as a child of `parent` (a tree-relative index,
// or -1 for the root of the tree — the first object added must be the root).
// Returns the new object's tree-relative index (or -1 on error).
int  rsc_add_object(rsc *r, int tree, int parent, int type,
                    unsigned flags, unsigned state,
                    int x, int y, int w, int h);

// Payload setters (choose the one matching the object's type):
// string spec (G_STRING/BUTTON/TITLE/CHECKBOX/RADIO/POPUP).
void rsc_set_string(rsc *r, int tree, int obj, const char *s);
// inline box colour spec (G_BOX/G_IBOX/G_BOXCHAR): chr = G_BOXCHAR character,
// thick = border thickness, color = the 16-bit GEM colour word.
void rsc_set_box(rsc *r, int tree, int obj, int chr, int thick, unsigned color);
// TEDINFO spec (G_TEXT/BOXTEXT/FTEXT/FBOXTEXT/FIELD).  `text` is the initial
// value, `tmplt` the display template ('_' per input slot), `valid` the
// per-slot validation string ("X" = any); `just` is TE_LEFT/RIGHT/CNTR.
void rsc_set_tedinfo(rsc *r, int tree, int obj, const char *text,
                     const char *tmplt, const char *valid, int just);
// G_POPUP: record the linked menu tree's index in the ob_type high byte.
void rsc_set_popup_link(rsc *r, int tree, int obj, int linked_tree);
// Any type: set the raw ob_type high byte (corner-rounding / group-box / etc.).
void rsc_set_exttype(rsc *r, int tree, int obj, int ext);

// A convenient default GEM colour word (black border+text, hollow, white fill).
unsigned rsc_default_color(void);

#ifdef __cplusplus
}
#endif

#endif // GEM_AES_RSC_H
