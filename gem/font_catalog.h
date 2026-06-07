// font_catalog.h — the persisted catalog of selectable faces in OS/Fonts.
//
// Each *selectable face* is either a named instance of a variable font (Roboto
// "SemiBold Condensed") or a whole static font.  The catalog is the small,
// always-resident metadata the chooser and vst_font/vst_name resolve against, and
// what the effect path consults to pick a real master vs a synthetic effect — so
// nothing downstream re-parses a font to know its weights/widths.
//
// It is FS-agnostic: the caller enumerates the directory (POSIX on host, FatFs
// f_readdir on target) and passes the {name,size} list in.  fc_load persists the
// catalog and, when the directory's name:size hash is unchanged, reloads it
// without parsing a single font (there is no RTC, so the hash is the staleness
// key).  See docs/OS/fonts.md.

#ifndef GEM_FONT_CATALOG_H
#define GEM_FONT_CATALOG_H

#include <stdint.h>
#include <ft2build.h>
#include <freetype/freetype.h>

#define FC_MAX_AXES   16        // Roboto Flex has 13
#define FC_FAMILY_MAX 64
#define FC_STYLE_MAX  48
#define FC_FILE_MAX   128

typedef struct { uint32_t tag; float value; } fc_axis;   // one design-coord setting

// A selectable face.  For a variable instance, axes[] are the design coords to
// apply (FT_Set_Var_Design_Coordinates); for a static font n_axes == 0.
typedef struct {
    char    family[FC_FAMILY_MAX];
    char    style [FC_STYLE_MAX];   // "Regular", "Condensed Bold", "Italic", ...
    char    file  [FC_FILE_MAX];    // filename within the font directory
    uint8_t variable;               // came from a variable font
    uint8_t italic;                 // slnt < 0, ital >= 1, or the static italic flag
    int16_t weight;                 // wght (100..1000); 400 default / 700 if bold-flagged
    int16_t width;                  // wdth percent (100 default)
    uint8_t n_axes;                 // design coords to apply (0 = static default)
    fc_axis axes[FC_MAX_AXES];
} fc_face;

// A directory entry to index: filename + byte size (FatFs FILINFO.fsize gives
// size for free during f_readdir; on host, stat()).
typedef struct { const char *name; long size; } fc_dirent;

typedef struct {
    fc_face *faces;
    int      n_faces, cap;
    uint32_t hash;                  // name:size hash of the directory at build time
} fc_catalog;

// CRC32 over the sorted "name:size\n" list — the staleness key.
uint32_t fc_dir_hash(const fc_dirent *ents, int n);

// Build by parsing every font in `dir` (path = dir + "/" + entry name).  Returns
// the face count, or -1.  Expects a zeroed `cat`; sets cat->hash from the entries.
int  fc_build(fc_catalog *cat, FT_Library lib, const char *dir,
              const fc_dirent *ents, int n);

// Versioned text index.  fc_read fills `cat` and returns 0; -1 on missing /
// corrupt / version-mismatch.  fc_write replaces the file atomically.
int  fc_write_index(const fc_catalog *cat, const char *path);
int  fc_read_index(fc_catalog *cat, const char *path);

// If the index at `idxpath` matches the directory hash, load it (zero fonts
// parsed); else rebuild and rewrite it.  *from_index (may be NULL) = 1 on the fast
// path.  Returns the face count or -1.  Pass a zeroed `cat`.
int  fc_load(fc_catalog *cat, FT_Library lib, const char *dir,
             const fc_dirent *ents, int n, const char *idxpath, int *from_index);

void fc_free(fc_catalog *cat);

#endif // GEM_FONT_CATALOG_H
