// registry.c — SQLite-backed desktop registry.  See registry.h.
#include "registry.h"
#include <sqlite3.h>
#include <stdint.h>
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

void registry_close(void) {
    if (g_db) { sqlite3_close(g_db); g_db = NULL; }
    registry_match_flush();              /* the cached rules belong to the closed db */
}

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

int registry_pref(const char *key, const char *deflt, char *out, int osz) {
    if (out && osz > 0) snprintf(out, osz, "%s", deflt ? deflt : "");
    if (!g_db) return 0;
    sqlite3_stmt *st;
    const char *sql = "SELECT value FROM deskPrefs WHERE key=?";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
    int found = 0;
    if (sqlite3_step(st) == SQLITE_ROW) {
        const char *v = (const char *)sqlite3_column_text(st, 0);
        if (v) { if (out && osz > 0) snprintf(out, osz, "%s", v); found = 1; }
    }
    sqlite3_finalize(st);
    return found;
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

/* The windowIcons rules, hoisted ONCE PER TYPE. registry_match used to prepare and scan the
 * table per directory ENTRY — a 150-file folder cost ~300 queries of the same dozen rows, and
 * it was most of a 2.5 s folder open on the board. Rules do not change mid-listing: cache them
 * (per type, on first use) and pattern-match in memory. registry_close() drops the cache, so a
 * reopened registry re-reads them. */
#define MRULE_MAX 64
typedef struct { int type; char path[REG_PATH_MAX]; char match[64]; char disp[REG_NAME_MAX]; } mrule;
static mrule    g_mr[MRULE_MAX];
static int      g_nmr;
static uint32_t g_mr_types;              /* bit n = rules for type n are loaded */

void registry_match_flush(void) { g_nmr = 0; g_mr_types = 0; }

static void mrules_load(int type) {
    if (g_mr_types & (1u << type)) return;
    g_mr_types |= 1u << type;
    sqlite3_stmt *st;
    const char *sql = "SELECT path,match,COALESCE(displayName,'') FROM windowIcons WHERE type=?";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return;
    sqlite3_bind_int(st, 1, type);
    while (sqlite3_step(st) == SQLITE_ROW && g_nmr < MRULE_MAX) {
        mrule *r = &g_mr[g_nmr++];
        r->type = type;
        snprintf(r->path,  sizeof r->path,  "%s", (const char *)sqlite3_column_text(st, 0));
        snprintf(r->match, sizeof r->match, "%s", (const char *)sqlite3_column_text(st, 1));
        snprintf(r->disp,  sizeof r->disp,  "%s", (const char *)sqlite3_column_text(st, 2));
    }
    sqlite3_finalize(st);
}

int registry_match(const char *name, int type, char *path, int psz, char *disp, int dsz) {
    if (!g_db || type < 0 || type > 31) return 0;   /* ICT_* are single digits */
    mrules_load(type);
    int best = -1, found = 0;
    for (int i = 0; i < g_nmr; i++) {
        if (g_mr[i].type != type) continue;
        if (!pmatch(g_mr[i].match, name)) continue;
        int sp = specificity(g_mr[i].match);
        if (sp > best) {
            best = sp; found = 1;
            snprintf(path, psz, "%s", g_mr[i].path);
            snprintf(disp, dsz, "%s", g_mr[i].disp);
        }
    }
    return found;
}

int registry_mime(const char *name, char *app, int asz,
                  char *machine, int msz, char *boot, int bsz) {
    if (app && asz)     app[0] = 0;
    if (machine && msz) machine[0] = 0;
    if (boot && bsz)    boot[0] = 0;
    if (!g_db) return -1;                                  // no DB -> caller falls back
    sqlite3_stmt *st;
    const char *sql = "SELECT match,app,COALESCE(machine,''),COALESCE(boot,'') FROM mimeApps";
    if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return -1;  // no table
    int best = -1, found = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        const char *pat = (const char *)sqlite3_column_text(st, 0);
        if (!pat || !pmatch(pat, name)) continue;
        int sp = specificity(pat);
        if (sp > best) {                                   // most-specific glob wins
            best = sp; found = 1;
            if (app)     snprintf(app,     asz, "%s", (const char *)sqlite3_column_text(st, 1));
            if (machine) snprintf(machine, msz, "%s", (const char *)sqlite3_column_text(st, 2));
            if (boot)    snprintf(boot,    bsz, "%s", (const char *)sqlite3_column_text(st, 3));
        }
    }
    sqlite3_finalize(st);
    return found;                                          // 1 matched, 0 = none matched
}
