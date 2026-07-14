// registry.h — the XTOS desktop registry (SQLite: /OS/Etc/Registry.db).
//
// Three tables (see /OS/Etc/SQL): iconTypes (the distinct icon-type ids),
// desktopIcons (positioned icons on the desktop), and windowIcons (pattern ->
// icon rules for the files/folders shown inside windows).  Callers use this thin
// API and never touch SQL; on the SDL host it links the system libsqlite3, on the
// A9 it will link the vendored amalgamation.

#ifndef GEM_REGISTRY_H
#define GEM_REGISTRY_H

#define REG_PATH_MAX 128    // icon path (relative to /OS/Icons, or absolute)
#define REG_NAME_MAX 64     // displayName

// iconTypes ids (see the SQL seed).
enum { ICT_EMU_8BIT = 1, ICT_EMU_1632 = 2, ICT_MEDIA_8BIT = 3,
       ICT_MEDIA_1632 = 4, ICT_BIN = 5, ICT_FOLDER = 6, ICT_FILE = 7,
       ICT_FUJINET = 8, ICT_SERVER = 9, ICT_ADD_SERVER = 10 };

typedef struct {
    int  x, y, type;
    char path[REG_PATH_MAX];         // icon bitmap, relative to /OS/Icons
    char displayName[REG_NAME_MAX];  // label ("" -> caller uses the entry name)
} reg_desktop_icon;

int  registry_open(const char *db_path);          // 0 ok, <0 fail
void registry_close(void);

// Fill up to `max` desktop icons (ordered by id); returns the count, <0 on error.
int  registry_desktop_icons(reg_desktop_icon *out, int max);

// Read a deskPrefs value by `key` into `out` (NUL-terminated, <=osz).  Returns 1
// when the key exists; otherwise copies `deflt` (may be NULL) and returns 0.  Used
// for the desktop view defaults (e.g. 'viewMode' 1=icons/2=single/3=multi).
int  registry_pref(const char *key, const char *deflt, char *out, int osz);

// Pick the window icon for an entry named `name` of iconTypes id `type`: the
// most-specific matching windowIcons.match wins ('%' = one char, '*' = a run;
// case-insensitive).  Fills path/displayName (displayName may be "" -> caller
// uses `name`).  Returns 1 on a match, 0 if none.
int  registry_match(const char *name, int type, char *path, int psz, char *disp, int dsz);
// registry_match caches the rules per type (they were re-queried per directory ENTRY — most
// of a big folder's open time). Call this after CHANGING windowIcons rows in a live process;
// registry_close() flushes on its own.
void registry_match_flush(void);

// Application <-> mimetype lookup: pick the launch action for a file named
// `name` from the mimeApps table (most-specific glob wins, case-insensitive).
// Fills `app` ("emulator"|"textview"|"none"), and for an emulator `machine`
// ("6502"|"m68k") + `boot` ("disk"|"cart"|"exec") — empty for non-emulators.
// Returns 1 on a match, 0 if the table exists but nothing matched (caller = a
// "none" / no-application notice), and -1 if the table/DB is unavailable (caller
// may fall back to path-based inference).  machine/boot may be NULL.
int  registry_mime(const char *name, char *app, int asz,
                   char *machine, int msz, char *boot, int bsz);

#endif // GEM_REGISTRY_H
