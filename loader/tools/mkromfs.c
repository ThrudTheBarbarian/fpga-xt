/*
 * mkromfs — host tool: pack files into a flat read-only filesystem blob.
 * Usage: mkromfs out.bin  /fs/path=hostfile  [/fs/path2=hostfile2 ...]
 *
 * Format (little-endian):
 *   magic "XRFS" (4), count (4)
 *   count x entry { char path[56]; u32 offset; u32 size; }   (64 bytes)
 *   ... file data (each PAGE-ALIGNED from the start of the blob) ...
 *
 * File data is 4 KB-aligned so a file can be mmap'd zero-copy: with the embedded
 * blob array page-aligned too (romfs_blob.h), each file's bytes land on a physical
 * page boundary, mappable read-only straight into a process VA. See SYS_mmap.
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

#define PAGE 0x1000u
    char **srcs = calloc(n, sizeof *srcs);
    unsigned cursor = 8 + (unsigned)n * sizeof(ent_t);   /* header + table */
    for (int i = 0; i < n; i++) {
        char *spec = argv[2 + i];
        char *eq = strchr(spec, '=');
        if (!eq) { fprintf(stderr, "bad spec '%s' (need /path=file)\n", spec); return 1; }
        *eq = 0;
        if (strlen(spec) >= PATHLEN) { fprintf(stderr, "path too long: %s\n", spec); return 1; }
        strncpy(ents[i].path, spec, PATHLEN - 1);
        srcs[i] = eq + 1;
        /* same source file as an earlier entry -> alias its data (this is how
         * the toybox applet names all point at one blob, unix-hardlink style) */
        int dup = -1;
        for (int j = 0; j < i; j++)
            if (!strcmp(srcs[j], srcs[i])) { dup = j; break; }
        if (dup >= 0) {
            data[i] = 0;
            ents[i].off = ents[dup].off;
            ents[i].size = ents[dup].size;
            continue;
        }
        data[i] = slurp(eq + 1, &sizes[i]);
        cursor = (cursor + PAGE - 1u) & ~(PAGE - 1u);     /* page-align each file (mmap) */
        ents[i].off = cursor;
        ents[i].size = sizes[i];
        cursor += sizes[i];
    }

    FILE *out = fopen(argv[1], "wb");
    if (!out) { perror(argv[1]); return 1; }
    fwrite("XRFS", 1, 4, out);
    unsigned cnt = (unsigned)n; fwrite(&cnt, 4, 1, out);
    fwrite(ents, sizeof(ent_t), n, out);
    unsigned pos = 8 + (unsigned)n * sizeof(ent_t);
    for (int i = 0; i < n; i++) {
        if (!data[i]) continue;                              /* alias of an earlier file */
        while (pos < ents[i].off) { fputc(0, out); pos++; }  /* pad to the file's page */
        fwrite(data[i], 1, sizes[i], out);
        pos += sizes[i];
    }
    fclose(out);
    fprintf(stderr, "mkromfs: %d files, %u bytes\n", n, cursor);
    return 0;
}
