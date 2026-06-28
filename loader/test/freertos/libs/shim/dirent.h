/* Minimal <dirent.h> shim for the embedded libGEM build: this newlib multilib
 * ships a non-functional <dirent.h> (#error "not supported"). load_fonts.c only
 * needs the types to compile; the dir scan is stubbed (gem_stubs.c) since fonts
 * load via the OS/Fonts/System.font pointer file, not a directory scan. */
#ifndef GEM_SHIM_DIRENT_H
#define GEM_SHIM_DIRENT_H
typedef struct { int _d; } DIR;
struct dirent { char d_name[256]; };
DIR           *opendir(const char *path);
struct dirent *readdir(DIR *d);
int            closedir(DIR *d);
#endif
