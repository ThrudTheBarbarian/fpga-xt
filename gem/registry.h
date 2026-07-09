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

// Pick the window icon for an entry named `name` of iconTypes id `type`: the
// most-specific matching windowIcons.match wins ('%' = one char, '*' = a run;
// case-insensitive).  Fills path/displayName (displayName may be "" -> caller
// uses `name`).  Returns 1 on a match, 0 if none.
int  registry_match(const char *name, int type, char *path, int psz, char *disp, int dsz);

#endif // GEM_REGISTRY_H
