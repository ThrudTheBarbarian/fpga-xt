/* httpd.c — /OS/bin/httpd: a tiny HTTP/1.0 file server on the raw socket
 * syscalls (bare usys — no libc, no toybox), so the board is browsable and
 * you can PULL files from a browser (the TFTP drop pushes). GET only; a
 * directory serves an HTML index, a file serves its bytes. Rooted at the
 * whole VFS; single connection at a time; LAN-trust, no auth.
 *
 *   httpd [port]      (default 80)     then browse  http://xtos.local/
 */
#include "usys.h"

/* ---- tiny string helpers (freestanding) ------------------------------------ */
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void scpy(char *d, const char *s, int cap) { int i = 0; while (s[i] && i < cap-1) { d[i]=s[i]; i++; } d[i]=0; }
static char *sapp(char *d, const char *s) { while (*s) *d++ = *s++; return d; }
static char *iapp(char *d, long v)         /* append a decimal */
{ char t[16]; int i=0; if(v<0){*d++='-';v=-v;} do{t[i++]=(char)('0'+v%10);v/=10;}while(v); while(i)*d++=t[--i]; return d; }
static int seq(const char *a, const char *b) { while (*a&&*a==*b){a++;b++;} return *a==*b; }
static int ici(char c) { return (c>='A'&&c<='Z') ? c+32 : c; }
static int ieq(const char *a, const char *b) { while(*a&&ici(*a)==ici(*b)){a++;b++;} return ici(*a)==ici(*b); }

static const char *ctype(const char *path)
{
    const char *dot = 0;
    for (const char *p = path; *p; p++) if (*p == '.') dot = p;
    if (!dot) return "application/octet-stream";
    if (ieq(dot,".html")||ieq(dot,".htm")) return "text/html";
    if (ieq(dot,".txt")||ieq(dot,".md")||ieq(dot,".c")||ieq(dot,".h")) return "text/plain";
    if (ieq(dot,".css"))  return "text/css";
    if (ieq(dot,".js"))   return "text/javascript";
    if (ieq(dot,".json")) return "application/json";
    if (ieq(dot,".png"))  return "image/png";
    if (ieq(dot,".jpg")||ieq(dot,".jpeg")) return "image/jpeg";
    if (ieq(dot,".gif"))  return "image/gif";
    return "application/octet-stream";
}

static void wr(int fd, const char *s, int n) { long o=0; while(o<n){ long w=sys_write(fd,s+o,(unsigned)(n-o)); if(w<=0)return; o+=w; } }
static void wrs(int fd, const char *s) { wr(fd, s, slen(s)); }

static void head(int fd, int code, const char *status, const char *type, long len)
{
    char h[256], *p = h;
    /* HTTP/1.1 in the status line (with Connection: close below, so it's really
     * 1.0 semantics) — toybox wget only accepts a "HTTP/1.1 " status prefix */
    p = sapp(p, "HTTP/1.1 "); p = iapp(p, code); *p++=' '; p = sapp(p, status);
    p = sapp(p, "\r\nServer: xtos\r\nContent-Type: "); p = sapp(p, type);
    p = sapp(p, "\r\nConnection: close\r\n");
    if (len >= 0) { p = sapp(p, "Content-Length: "); p = iapp(p, len); p = sapp(p, "\r\n"); }
    p = sapp(p, "\r\n");
    wr(fd, h, (int)(p - h));
}

static void http_error(int fd, int code, const char *status)
{
    head(fd, code, status, "text/html", -1);
    char b[128], *p = b;
    p = sapp(p, "<html><body><h1>"); p = iapp(p, code); *p++=' '; p = sapp(p, status);
    p = sapp(p, "</h1></body></html>\n");
    wr(fd, b, (int)(p - b));
}

static void serve_dir(int fd, const char *path)
{
    head(fd, 200, "OK", "text/html", -1);
    char line[600], *p;
    p = sapp(line, "<html><head><title>"); p = sapp(p, path);
    p = sapp(p, "</title></head><body><h2>Index of "); p = sapp(p, path);
    p = sapp(p, "</h2><ul>\n"); wr(fd, line, (int)(p - line));
    if (!(path[0]=='/'&&!path[1])) wrs(fd, "<li><a href=\"../\">../</a></li>\n");

    struct xt_dirent de;
    for (int i = 0; sys_readdir(path, i, &de) == 1; i++) {
        if (de.name[0] == '.') continue;
        int isdir = (de.mode & XT_S_IFMT) == XT_S_IFDIR;
        p = sapp(line, "<li><a href=\""); p = sapp(p, de.name); if (isdir) *p++='/';
        p = sapp(p, "\">"); p = sapp(p, de.name); if (isdir) *p++='/';
        p = sapp(p, "</a></li>\n");
        wr(fd, line, (int)(p - line));
    }
    wrs(fd, "</ul></body></html>\n");
}

static void serve_file(int fd, const char *path, long size)
{
    int in = (int)sys_open(path, 0);
    if (in < 0) { http_error(fd, 404, "Not Found"); return; }
    head(fd, 200, "OK", ctype(path), size);
    char buf[2048]; long n;
    while ((n = sys_read(in, buf, sizeof buf)) > 0) wr(fd, buf, (int)n);
    sys_close(in);
}

static void urldecode(char *s)
{
    char *o = s;
    for (; *s; s++) {
        if (*s == '%' && s[1] && s[2]) {
            int hi=s[1], lo=s[2];
            hi = hi<='9'?hi-'0':(ici(hi)-'a'+10);
            lo = lo<='9'?lo-'0':(ici(lo)-'a'+10);
            *o++ = (char)((hi<<4)|lo); s += 2;
        } else *o++ = *s;
    }
    *o = 0;
}

static int has_dotdot(const char *s) { for (; s[0]; s++) if (s[0]=='.'&&s[1]=='.') return 1; return 0; }

static void handle(int cfd)
{
    char req[1024];
    long n = sys_read(cfd, req, sizeof req - 1);
    if (n <= 0) return;
    req[n] = 0;

    if (!(req[0]=='G'&&req[1]=='E'&&req[2]=='T'&&req[3]==' ')) { http_error(cfd, 501, "Not Implemented"); return; }
    char path[600]; int k = 0;
    for (char *s = req + 4; *s && *s != ' ' && *s != '?' && k < 599; s++) path[k++] = *s;
    path[k] = 0;
    urldecode(path);
    if (path[0] != '/' || has_dotdot(path)) { http_error(cfd, 400, "Bad Request"); return; }
    while (k > 1 && path[k-1] == '/') path[--k] = 0;    /* trailing slash off (except root) */

    struct xt_stat st;
    if (sys_stat(path, &st) != 0) { http_error(cfd, 404, "Not Found"); return; }
    if ((st.mode & XT_S_IFMT) == XT_S_IFDIR) serve_dir(cfd, path);
    else                                     serve_file(cfd, path, (long)st.size);
}

static int atoin(const char *s) { int v=0; while(*s>='0'&&*s<='9') v=v*10+(*s++-'0'); return v; }

void _app_entry(int argc, char **argv)
{
    int port = argc > 1 ? atoin(argv[1]) : 80;

    int ls = (int)sys_socket(XT_SOCK_TCP);
    if (ls < 0) { wrs(2, "httpd: socket failed\n"); sys_exit(1); }
    if (sys_bind(ls, 0 /* INADDR_ANY */, (unsigned)port) != 0) { wrs(2, "httpd: port busy\n"); sys_exit(1); }
    sys_listen(ls, 4);
    { char m[48], *p = sapp(m, "httpd: serving / on port "); p = iapp(p, port); p = sapp(p, "\n"); wr(1, m, (int)(p-m)); }

    for (;;) {
        unsigned peer[2];
        int cfd = (int)sys_accept(ls, peer);
        if (cfd < 0) continue;
        handle(cfd);
        sys_close(cfd);
    }
}
