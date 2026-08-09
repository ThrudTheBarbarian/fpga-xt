/* xg_settings.c — persistent application settings for XG's toolkit, over the system registry.
 *
 * XG's XGKeyValueStore was in-memory: an app could "save" a preference and find it gone next
 * launch.  This is the XTOS backing store for it, and it is the SAME SQLite registry the desktop
 * already keeps its own preferences in — one database (/OS/var/registry.db), one C API, no SQL
 * anywhere near the toolkit.  Values live in a `settings` table (domain, key, value) that
 * registry.c creates on first write, so a board whose registry predates this gains it silently.
 *
 * `domain` namespaces a key per application — two apps may each keep a 'fontSize' — and an empty
 * or NULL domain is the shared one that applies to everybody.  The domain -> shared FALLBACK is
 * not done here: it is toolkit policy (XGKeyValueStore), so it reads the same on every backend.
 *
 * Compiled into libGEM alongside gemclient.c, because the XG client links libGEM and nothing else.
 * Kept OUT of gemclient.c so that the client half of the AES does not drag SQLite into every
 * program that only wanted a window.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "registry.h"

/* Where the registry lives.  The board has one fixed place (the desktop opens the same file); the
 * host gets one per user, made on demand, so `make gem` persists settings without a board image. */
static const char *xg_settings_db(void) {
    const char *env = getenv("XG_SETTINGS_DB");
    if (env && *env) return env;
#ifdef GEM_HOST
    static char path[512];
    if (!path[0]) {
        const char *home = getenv("HOME");
        if (!home || !*home) home = ".";
        snprintf(path, sizeof path, "%s/.xg", home);
        mkdir(path, 0755);                       /* first run: no directory yet */
        snprintf(path, sizeof path, "%s/.xg/Registry.db", home);
    }
    return path;
#else
    return "/OS/var/registry.db";                /* the desktop's registry — see desktop.c */
#endif
}

/* Open once per process, and remember that we tried: a missing or unwritable registry must cost
 * one failed open, not one per preference read. */
static int settings_ready(void) {
    static int tried, ok;
    if (!tried) { tried = 1; ok = (registry_open_or_create(xg_settings_db()) == 0); }
    return ok;
}

int xg_setting_get(const char *domain, const char *key, char *out, int cap) {
    if (out && cap > 0) out[0] = 0;
    if (!settings_ready()) return 0;
    return registry_setting_get(domain, key, "", out, cap) ? 1 : 0;
}

int xg_setting_set(const char *domain, const char *key, const char *value) {
    if (!settings_ready()) return 0;
    return registry_setting_set(domain, key, value) == 0 ? 1 : 0;
}

int xg_setting_remove(const char *domain, const char *key) {
    if (!settings_ready()) return 0;
    return registry_setting_remove(domain, key) == 0 ? 1 : 0;
}

int xg_setting_key(const char *domain, int idx, char *out, int cap) {
    if (out && cap > 0) out[0] = 0;
    if (!settings_ready()) return 0;
    return registry_setting_key(domain, idx, out, cap) ? 1 : 0;
}
