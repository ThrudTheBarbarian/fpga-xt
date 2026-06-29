/* dirent stubs for the embedded libGEM. load_fonts.c links opendir/readdir/
 * closedir for its font-directory *scan*, but on XTOS the system font loads via
 * the OS/Fonts/System.font pointer file (through fopen), so the scan fallback is
 * never exercised — these just satisfy the link and report "empty directory". */
#include <dirent.h>
DIR           *opendir(const char *p)  { (void)p; return 0; }
struct dirent *readdir(DIR *d)         { (void)d; return 0; }
int            closedir(DIR *d)        { (void)d; return 0; }

/* xt_font_map / xt_font_unmap — XTOS overrides of font.c's weak hooks: map a font
 * file READ-ONLY + shared (zero-copy) so FreeType reads glyphs straight from the
 * one resident romfs copy, demand-paged, instead of fread-ing it into a private
 * malloc buffer. Reaches the kernel directly via svc #1 (SYS_open/lseek/mmap). */
#define SYS_open   0x300
#define SYS_close  0x301
#define SYS_lseek  0x304
#define SYS_mmap   0x305
#define SYS_munmap 0x306

static long sc(long n, long a0, long a1, long a2)
{
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

const void *xt_font_map(const char *path, unsigned long *len)
{
    long fd = sc(SYS_open, (long)path, 0, 0);
    if (fd < 0) return 0;
    long sz = sc(SYS_lseek, fd, 0, 2 /*SEEK_END*/);
    long va = sc(SYS_mmap, fd, 0, 0);            /* whole file, RO, shared, demand-paged */
    sc(SYS_close, fd, 0, 0);                     /* the mapping is independent of the fd */
    if (va <= 0 || sz <= 0) return 0;
    if (len) *len = (unsigned long)sz;
    return (const void *)va;
}

void xt_font_unmap(const void *p, unsigned long len)
{
    sc(SYS_munmap, (long)p, (long)len, 0);
}
