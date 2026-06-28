/*
 * mkromfs — host tool: pack files into a flat read-only filesystem blob.
 * Usage: mkromfs out.bin  /fs/path=hostfile  [/fs/path2=hostfile2 ...]
 *
 * Format (little-endian):
 *   magic "XRFS" (4), count (4)
 *   count x entry { char path[56]; u32 offset; u32 size; }   (64 bytes)
 *   ... file data (each at its offset from the start of the blob) ...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PATHLEN 56
typedef struct { char path[PATHLEN]; unsigned off; unsigned size; } ent_t;

static unsigned char *slurp(const char *p, unsigned *len)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(n);
    if (fread(b, 1, n, f) != (size_t)n) { perror("read"); exit(1); }
    fclose(f); *len = (unsigned)n; return b;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: %s out.bin /path=file ...\n", argv[0]); return 1; }
    int n = argc - 2;
    ent_t *ents = calloc(n, sizeof *ents);
    unsigned char **data = calloc(n, sizeof *data);
    unsigned *sizes = calloc(n, sizeof *sizes);

    unsigned cursor = 8 + (unsigned)n * sizeof(ent_t);   /* header + table */
    for (int i = 0; i < n; i++) {
        char *spec = argv[2 + i];
        char *eq = strchr(spec, '=');
        if (!eq) { fprintf(stderr, "bad spec '%s' (need /path=file)\n", spec); return 1; }
        *eq = 0;
        if (strlen(spec) >= PATHLEN) { fprintf(stderr, "path too long: %s\n", spec); return 1; }
        strncpy(ents[i].path, spec, PATHLEN - 1);
        data[i] = slurp(eq + 1, &sizes[i]);
        ents[i].off = cursor;
        ents[i].size = sizes[i];
        cursor += (sizes[i] + 3u) & ~3u;                 /* 4-byte align */
    }

    FILE *out = fopen(argv[1], "wb");
    if (!out) { perror(argv[1]); return 1; }
    fwrite("XRFS", 1, 4, out);
    unsigned cnt = (unsigned)n; fwrite(&cnt, 4, 1, out);
    fwrite(ents, sizeof(ent_t), n, out);
    for (int i = 0; i < n; i++) {
        fwrite(data[i], 1, sizes[i], out);
        unsigned pad = ((sizes[i] + 3u) & ~3u) - sizes[i];
        while (pad--) fputc(0, out);
    }
    fclose(out);
    fprintf(stderr, "mkromfs: %d files, %u bytes\n", n, cursor);
    return 0;
}
