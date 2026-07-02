// registry.c — SQLite-backed desktop registry.  See registry.h.
#include "registry.h"
#include <sqlite3.h>
#include <string.h>
#include <ctype.h>
#include <stdio.h>

static sqlite3 *g_db;

int registry_open(const char *db_path) {
    if (g_db) return 0;
    if (sqlite3_open_v2(db_path, &g_db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (g_db) { sqlite3_close(g_db); g_db = NULL; }
        return -1;
    }
    return 0;
}

void registry_close(void) { if (g_db) { sqlite3_close(g_db); g_db = NULL; } }

int registry_desktop_icons(reg_desktop_icon *out, int max) {
    if (!g_db) return -1;
    sqlite3_stmt *st;
    const char *sql = "SELECT x,y,type,path,COALESCE(displayName,'') FROM desktopIcons ORDER BY id";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
    int n = 0;
    while (n < max && sqlite3_step(st) == SQLITE_ROW) {
        out[n].x    = sqlite3_column_int(st, 0);
        out[n].y    = sqlite3_column_int(st, 1);
        out[n].type = sqlite3_column_int(st, 2);
        snprintf(out[n].path,        REG_PATH_MAX, "%s", (const char *)sqlite3_column_text(st, 3));
        snprintf(out[n].displayName, REG_NAME_MAX, "%s", (const char *)sqlite3_column_text(st, 4));
        n++;
    }
    sqlite3_finalize(st);
    return n;
}

// Glob match: '%' = exactly one char, '*' = zero or more, case-insensitive.
static int pmatch(const char *p, const char *s) {
    if (*p == '\0') return *s == '\0';
    if (*p == '*') { do { if (pmatch(p+1, s)) return 1; } while (*s++); return 0; }
    if (*s == '\0') return 0;
    if (*p == '%' || tolower((unsigned char)*p) == tolower((unsigned char)*s)) return pmatch(p+1, s+1);
    return 0;
}

// Specificity: literal (non-wildcard) chars — higher wins (so "textedit.prg"
// beats "*.prg" beats "*").
static int specificity(const char *p) {
    int n = 0;
    for (; *p; p++) if (*p != '*' && *p != '%') n++;
    return n;
}

int registry_match(const char *name, int type, char *path, int psz, char *disp, int dsz) {
    if (!g_db) return 0;
    sqlite3_stmt *st;
    const char *sql = "SELECT path,match,COALESCE(displayName,'') FROM windowIcons WHERE type=?";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_int(st, 1, type);
    int best = -1, found = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        const char *pat = (const char *)sqlite3_column_text(st, 1);
        if (!pmatch(pat, name)) continue;
        int sp = specificity(pat);
        if (sp > best) {
            best = sp; found = 1;
            snprintf(path, psz, "%s", (const char *)sqlite3_column_text(st, 0));
            snprintf(disp, dsz, "%s", (const char *)sqlite3_column_text(st, 2));
        }
    }
    sqlite3_finalize(st);
    return found;
}
