/* sqlite3.c — /OS/bin/sqlite3: a compact SQL shell over the vendored SQLite
 * (same build as the registry: SQLITE_OS_OTHER + sqlite_vfs.c, so database
 * locks are lockfs files — watch them appear in /OS/var/locks while a
 * statement holds the db).
 *
 *   sqlite3 DB [SQL...]      run the SQL arguments and exit
 *   sqlite3 DB               interactive: statements end with ';', dot
 *                            commands: .tables  .schema [TABLE]  .quit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

static sqlite3 *db;

static int row_cb(void *hdr, int nc, char **vals, char **cols)
{
    int *need_hdr = (int *)hdr;
    if (*need_hdr) {
        for (int i = 0; i < nc; i++) printf("%s%s", i ? "|" : "", cols[i]);
        printf("\n");
        *need_hdr = 0;
    }
    for (int i = 0; i < nc; i++) printf("%s%s", i ? "|" : "", vals[i] ? vals[i] : "NULL");
    printf("\n");
    return 0;
}

static void run_sql(const char *sql)
{
    int hdr = 1;
    char *err = 0;
    if (sqlite3_exec(db, sql, row_cb, &hdr, &err) != SQLITE_OK) {
        fprintf(stderr, "Error: %s\n", err ? err : sqlite3_errmsg(db));
        sqlite3_free(err);
    }
    fflush(stdout);
}

static void dot_command(char *line)
{
    char *arg = strchr(line, ' ');
    if (arg) { *arg++ = 0; while (*arg == ' ') arg++; }

    if (!strcmp(line, ".quit") || !strcmp(line, ".exit")) {
        sqlite3_close(db);
        exit(0);
    } else if (!strcmp(line, ".tables")) {
        run_sql("SELECT name FROM sqlite_schema WHERE type IN ('table','view') "
                "AND name NOT LIKE 'sqlite_%' ORDER BY 1");
    } else if (!strcmp(line, ".schema")) {
        char *q = arg && *arg
            ? sqlite3_mprintf("SELECT sql FROM sqlite_schema WHERE sql NOT NULL "
                              "AND tbl_name = %Q ORDER BY rowid", arg)
            : sqlite3_mprintf("SELECT sql FROM sqlite_schema WHERE sql NOT NULL "
                              "ORDER BY rowid");
        run_sql(q);
        sqlite3_free(q);
    } else {
        fprintf(stderr, "unknown command %s (have: .tables .schema .quit)\n", line);
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: sqlite3 DB [SQL...]\n");
        return 1;
    }
    if (sqlite3_open(argv[1], &db) != SQLITE_OK) {
        fprintf(stderr, "sqlite3: cannot open %s: %s\n", argv[1], sqlite3_errmsg(db));
        return 1;
    }

    if (argc > 2) {                                  /* one-shot: SQL from argv */
        for (int i = 2; i < argc; i++) run_sql(argv[i]);
        sqlite3_close(db);
        return 0;
    }

    printf("SQLite %s — .tables .schema [TABLE] .quit\n", sqlite3_libversion());
    char stmt[2048], line[256];
    int slen = 0;
    for (;;) {
        printf(slen ? "   ...> " : "sqlite> ");
        fflush(stdout);
        if (!fgets(line, sizeof line, stdin)) break;              /* EOF */
        if (!slen && line[0] == '.') {                            /* dot command */
            line[strcspn(line, "\r\n")] = 0;
            if (line[1]) dot_command(line);
            continue;
        }
        int ll = (int)strlen(line);
        if (slen + ll >= (int)sizeof stmt - 1) { fprintf(stderr, "statement too long\n"); slen = 0; continue; }
        memcpy(stmt + slen, line, (size_t)ll + 1);
        slen += ll;
        if (sqlite3_complete(stmt)) {                             /* ends with ';' */
            run_sql(stmt);
            slen = 0;
        }
    }
    sqlite3_close(db);
    return 0;
}

/* progs enter at _app_entry (see xtld) */
void _app_entry(int ac, char **av) { exit(main(ac, av)); }
