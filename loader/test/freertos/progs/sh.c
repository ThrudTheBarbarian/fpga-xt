/*
 * sh.c — /System/bin/sh: a shell that uses Lua as its scripting language. Per line,
 * COMMAND-FIRST: split into words; if word 0 names a program (in /System/bin or
 * /OS/bin) the line is run as a command (`desktop arg1 ...`); otherwise the line is
 * evaluated as Lua (`x = 5`, `for ...`, `print(...)`, `spawn("...")`). One persistent
 * lua_State per sh, so script-local Lua variables persist across lines.
 *
 * A foreground command runs to completion (waitpid) before the script continues;
 * a trailing '&' launches it in the background. `sh <script>` runs a script and exits
 * (each /OS/Boot/NN-* is a separate sh process, so scripts share no state). Interactive
 * REPL = TODO (still needs blocking stdin; command waitpid works).
 *
 * Embeds the real Lua 5.4 core, linked against libc.so/libm.so.
 */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "usys.h"
#include <stdio.h>
#include <string.h>

static lua_State *L;

/* spawn(name [,args]) -> pid. Bare name resolves to /System/bin/name. */
static int l_spawn(lua_State *Ls)
{
    const char *name = luaL_checkstring(Ls, 1);
    char path[80];
    if (name[0] == '/') snprintf(path, sizeof path, "%s", name);
    else                snprintf(path, sizeof path, "/System/bin/%s", name);
    char *av[1] = { path };
    lua_pushinteger(Ls, sys_spawn(path, 1, av));
    return 1;
}

static void open_libs(lua_State *Ls)
{
    static const luaL_Reg libs[] = {
        { LUA_GNAME, luaopen_base }, { LUA_TABLIBNAME, luaopen_table },
        { LUA_STRLIBNAME, luaopen_string }, { LUA_MATHLIBNAME, luaopen_math },
        { NULL, NULL }
    };
    for (const luaL_Reg *l = libs; l->func; l++) { luaL_requiref(Ls, l->name, l->func, 1); lua_pop(Ls, 1); }
}

/* If `name` is a program, write its full path to out and return 1. */
static int resolve_prog(const char *name, char *out, int outsz)
{
    static const char *const dirs[] = { "/System/bin/", "/OS/bin/", 0 };
    for (int i = 0; dirs[i]; i++) {
        snprintf(out, outsz, "%s%s", dirs[i], name);
        int fd = sys_open(out, 0);
        if (fd >= 0) { sys_close(fd); return 1; }
    }
    return 0;
}

static void run_line(char *line)
{
    while (*line == ' ' || *line == '\t') line++;
    if (!*line || line[0] == '#' || (line[0] == '-' && line[1] == '-')) return;  /* blank/#!/Lua-comment */

    /* split a COPY into words (Lua eval needs the original intact) */
    char tmp[256]; snprintf(tmp, sizeof tmp, "%s", line);
    char *argv[16]; int argc = 0;
    for (char *t = strtok(tmp, " \t"); t && argc < 15; t = strtok(NULL, " \t")) argv[argc++] = t;
    argv[argc] = 0;

    int bg = 0;                                  /* trailing '&' -> run in the background */
    if (argc > 0 && !strcmp(argv[argc - 1], "&")) { argv[--argc] = 0; bg = 1; }

    char path[96];
    if (argc > 0 && resolve_prog(argv[0], path, sizeof path)) {   /* command */
        argv[0] = path;
        long pid = sys_spawn(path, argc, argv);
        if (pid >= 0 && !bg) sys_waitpid((int)pid);   /* foreground: run to completion, then continue */
        return;
    }
    if (luaL_dostring(L, line) != LUA_OK) {                       /* otherwise: Lua */
        const char *e = lua_tostring(L, -1);
        fprintf(stderr, "sh: %s\n", e ? e : "error");
        lua_pop(L, 1);
    }
}

void _app_entry(int argc, char **argv)
{
    L = luaL_newstate();
    if (!L) { sys_write(2, "sh: out of memory\n", 18); sys_exit(1); }
    open_libs(L);
    lua_register(L, "spawn", l_spawn);

    if (argc < 2) { sys_write(2, "sh: interactive REPL not yet implemented\n", 41); lua_close(L); sys_exit(1); }

    FILE *f = fopen(argv[1], "r");
    if (!f) { sys_write(2, "sh: cannot open ", 16); sys_write(2, argv[1], strlen(argv[1])); sys_write(2, "\n", 1);
              lua_close(L); sys_exit(1); }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        run_line(line);
    }
    fclose(f);
    lua_close(L);
    sys_exit(0);
}
