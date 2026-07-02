/* libc-compat: sys/ttydefaults.h — classic BSD tty defaults */
#ifndef _XT_COMPAT_SYS_TTYDEFAULTS_H
#define _XT_COMPAT_SYS_TTYDEFAULTS_H

#define CTRL(x) ((x) & 037)

#define CEOF     CTRL('d')
#define CERASE   0177
#define CINTR    CTRL('c')
#define CKILL    CTRL('u')
#define CQUIT    034
#define CSUSP    CTRL('z')
#define CSTART   CTRL('q')
#define CSTOP    CTRL('s')
#define CLNEXT   CTRL('v')
#define CWERASE  CTRL('w')
#define CREPRINT CTRL('r')
#define CDISCARD CTRL('o')

#define TTYDEF_IFLAG (ICRNL | IXON)
#define TTYDEF_OFLAG (OPOST | ONLCR)
#define TTYDEF_LFLAG (ECHO | ICANON | ISIG | IEXTEN | ECHOE | ECHOK)
#define TTYDEF_CFLAG (CREAD | CS8 | HUPCL)
#define TTYDEF_SPEED (B9600)

#endif
