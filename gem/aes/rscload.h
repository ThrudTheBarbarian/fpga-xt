// aes/rscload.h — thin AES-side adapter over the SHARED GEM .rsc engine.
//
// The one .rsc reader/writer lives in ../fpga-gem/src/rsc.c (shared VERBATIM
// with the GemRCS editor).  It parses a .rsc image into RSC_OBJECT trees whose
// ob_spec is a resolved pointer, but it does NOT draw anything and keeps the
// ob_type high byte intact (an authoring extension the AES ignores).  This
// adapter turns an engine RSC into trees the AES can hand straight to
// objc_draw / form_do:
//
//   * every G_CICON / G_IMAGE object's embedded P7 PAM is decoded into a
//     gfx_surface wrapped in our CICON (as load_icon builds one), and ob_spec
//     is repointed at it so objc_draw renders the colour icon;
//   * each ob_type is masked to its low byte (the type the AES switches on);
//     the authoring high byte is captured so rscload_ext() can report it (for a
//     G_POPUP it is the linked menu tree index — RSC-FORMAT.md §5).
//
// RSC_OBJECT and our OBJECT are byte-identical (see aes.h), so rscload_tree()
// returns the trees as OBJECT*.  The adapter owns the engine RSC plus the
// decoded surfaces; rscload_free() releases the lot.
//
// PORTABILITY: rscload_mem() takes a byte buffer (host + A9); rscload_file() is
// a host fopen/fread convenience — on the A9 the caller passes bytes it already
// has (e.g. from the loader file API) to rscload_mem().

#ifndef GEM_AES_RSCLOAD_H
#define GEM_AES_RSCLOAD_H

#include "aes/aes.h"     // OBJECT, TEDINFO, CICON, G_*, OF_*, OS_*, BOX_ROUND_*
#include "rsc.h"         // the shared engine: RSC, RSC_OBJECT, rsc_read/write/...

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rscdoc rscdoc;   // owns the engine RSC + decoded CICON surfaces

// Parse a .rsc image from memory (big-endian classic/extended GEM).  Returns a
// handle, or NULL with *err set (err may be NULL).
rscdoc *rscload_mem(const uint8_t *data, size_t len, const char **err);
// Host convenience: slurp `path` then rscload_mem().  NULL on open/format error.
rscdoc *rscload_file(const char *path, const char **err);

int     rscload_ntrees(const rscdoc *d);
// Root OBJECT of tree `index`, ready for objc_draw / form_do (ob_spec resolved,
// ob_type masked to the low byte).  NULL if out of range.
OBJECT *rscload_tree(rscdoc *d, int index);
// The authoring high byte of object `obj` (tree-relative) in tree `index`.  For
// a G_POPUP this is its linked menu tree index (0 = none).  -1 if out of range.
int     rscload_ext(const rscdoc *d, int index, int obj);

// The XGNB nib extension (if the .rsc carried one).  Primitives + string pointers only, so a
// client reads the graph without the engine's structs.  Refs are (space, a, b) per XG-NIB.md.
int         rscload_nib_present(const rscdoc *d);
int         rscload_nib_nclassov(const rscdoc *d);
int         rscload_nib_ntopobj(const rscdoc *d);
int         rscload_nib_nconn(const rscdoc *d);
const char *rscload_nib_classov(const rscdoc *d, int i, int *space, int *a, int *b);       // view -> class name
const char *rscload_nib_topobj(const rscdoc *d, int i, int *id);                            // id -> class name
const char *rscload_nib_conn(const rscdoc *d, int i, int *kind,                             // -> member name
                             int *ss, int *sa, int *sb, int *ds, int *da, int *db);

void    rscload_free(rscdoc *d);

#ifdef __cplusplus
}
#endif

#endif // GEM_AES_RSCLOAD_H
