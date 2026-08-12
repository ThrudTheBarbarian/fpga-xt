/* rtt.h — see rtt.c */
#ifndef RTT_H
#define RTT_H

void rtt_init(void);
int  rtt_write(const char *data, int len);      /* non-blocking, may short-write */
int  rtt_read(char *data, int len);
int  rtt_readable(void);
int  rtt_attached(void);

#endif /* RTT_H */
