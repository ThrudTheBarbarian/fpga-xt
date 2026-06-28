/* dirent stubs for the embedded libGEM. load_fonts.c links opendir/readdir/
 * closedir for its font-directory *scan*, but on XTOS the system font loads via
 * the OS/Fonts/System.font pointer file (through fopen), so the scan fallback is
 * never exercised — these just satisfy the link and report "empty directory". */
#include <dirent.h>
DIR           *opendir(const char *p)  { (void)p; return 0; }
struct dirent *readdir(DIR *d)         { (void)d; return 0; }
int            closedir(DIR *d)        { (void)d; return 0; }
