/* fault.h — see fault.c */
#ifndef FAULT_H
#define FAULT_H

void fault_init(void);
int  fault_pending(void);                       /* a record survived a reset */
void fault_dump(void);
void fault_clear(void);

#endif /* FAULT_H */
