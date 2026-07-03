/* sh_lineedit.c — toysh's interactive line editor: linenoise (vendored,
 * libs/linenoise/) over the kernel raw-mode tty. get_next_line (sh.c, XTOS
 * patch) routes interactive tty reads here; scripts and pipes keep the plain
 * getc path. Gives history (up/down, persisted to /OS/var/sh_history) and TAB
 * completion: command position completes from the PATH dirs, anything else
 * completes as a filesystem path.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include "linenoise.h"

#define HISTFILE "/OS/var/sh_history"
#define HISTLEN  100

/* the token being completed starts after the last shell separator */
static int tok_start(const char *buf, int len)
{
    int s = len;
    while (s > 0 && !strchr(" \t;|&<>", buf[s - 1])) s--;
    return s;
}

/* is the token at `start` in command position (first word of a command)? */
static int is_cmd_pos(const char *buf, int start)
{
    for (int i = start - 1; i >= 0; i--) {
        if (buf[i] == ' ' || buf[i] == '\t') continue;
        return strchr(";|&", buf[i]) != 0;      /* a prior word unless after ; | & */
    }
    return 1;
}

/* emit "<prefix-of-buf><dir-part><name>[/]" as a completion candidate */
static void add_cand(linenoiseCompletions *lc, const char *buf, int start,
                     const char *dirpart, const char *name, int isdir)
{
    char full[512];
    snprintf(full, sizeof full, "%.*s%s%s%s", start, buf, dirpart, name,
             isdir ? "/" : "");
    linenoiseAddCompletion(lc, full);
}

/* complete the names in `dir` that start with `base` (dirpart = what the user
 * already typed before the basename, kept verbatim in the candidate) */
static void complete_dir(linenoiseCompletions *lc, const char *buf, int start,
                         const char *dir, const char *dirpart, const char *base)
{
    DIR *d = opendir(dir[0] ? dir : "/");
    if (!d) return;
    size_t bl = strlen(base);
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' && base[0] != '.') continue;
        if (strncmp(e->d_name, base, bl)) continue;
        char p[512];
        struct stat st;
        snprintf(p, sizeof p, "%s/%s", dir[0] ? dir : "", e->d_name);
        int isdir = (stat(p, &st) == 0) && S_ISDIR(st.st_mode);
        add_cand(lc, buf, start, dirpart, e->d_name, isdir);
    }
    closedir(d);
}

static void completer(const char *buf, linenoiseCompletions *lc)
{
    int len = (int)strlen(buf), start = tok_start(buf, len);
    const char *tok = buf + start;

    if (is_cmd_pos(buf, start) && !strchr(tok, '/')) {
        /* command position: the PATH dirs */
        static const char *const dirs[] = { "/System/bin", "/OS/bin", "/bin", 0 };
        size_t tl = strlen(tok);
        for (int i = 0; dirs[i]; i++) {
            DIR *d = opendir(dirs[i]);
            if (!d) continue;
            struct dirent *e;
            while ((e = readdir(d))) {
                if (e->d_name[0] == '.' || strncmp(e->d_name, tok, tl)) continue;
                add_cand(lc, buf, start, "", e->d_name, 0);
            }
            closedir(d);
        }
        return;
    }

    /* path completion: split the token at its last '/' */
    const char *slash = strrchr(tok, '/');
    char dir[400], dirpart[400];
    const char *base;
    if (slash) {
        int dl = (int)(slash - tok) + 1;                 /* keep the '/' */
        snprintf(dirpart, sizeof dirpart, "%.*s", dl, tok);
        snprintf(dir, sizeof dir, "%.*s", dl > 1 ? dl - 1 : 1, tok);
        base = slash + 1;
    } else {
        dirpart[0] = 0;
        char cwd[256];
        if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "/");
        snprintf(dir, sizeof dir, "%s", cwd);
        base = tok;
    }
    complete_dir(lc, buf, start, dir, dirpart, base);
}

/* interactive line for toysh: NULL = EOF; otherwise a malloc'd line ending in
 * '\n' (the shape the getc path produces; the caller frees it). */
char *xt_line_input(char *ps, int continuation)
{
    static int inited;
    if (!inited) {
        inited = 1;
        linenoiseHistorySetMaxLen(HISTLEN);
        linenoiseHistoryLoad(HISTFILE);                  /* absent (qemu): no-op */
        linenoiseSetCompletionCallback(completer);
    }

    /* PS1/PS2 pass through when plain; \-escaped prompts fall back (the
     * editor needs the literal prompt string for line redraws) */
    const char *prompt = (ps && *ps && !strchr(ps, '\\') && !strchr(ps, '!'))
                       ? ps : (continuation ? "> " : "$ ");

    char *ln = linenoise(prompt);
    if (!ln) {
        if (errno == EAGAIN) {                           /* ^C: empty line, not EOF */
            char *e = malloc(2);
            if (e) { e[0] = '\n'; e[1] = 0; }
            return e;
        }
        return 0;                                        /* EOF (ctrl-D) */
    }
    if (*ln) {
        linenoiseHistoryAdd(ln);
        linenoiseHistorySave(HISTFILE);
    }
    size_t n = strlen(ln);
    char *out = malloc(n + 2);
    if (out) { memcpy(out, ln, n); out[n] = '\n'; out[n + 1] = 0; }
    free(ln);
    return out;
}
