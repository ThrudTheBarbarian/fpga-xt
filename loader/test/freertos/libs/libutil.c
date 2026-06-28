/* libutil.so — a shared library (soname libutil.so). Pure code, no syscalls,
 * no imports; exercised by /bin/usestr via a DT_NEEDED dependency. */
char *strrev(char *s)
{
    int n = 0;
    while (s[n]) n++;
    for (int i = 0, j = n - 1; i < j; i++, j--) {
        char t = s[i]; s[i] = s[j]; s[j] = t;
    }
    return s;
}
