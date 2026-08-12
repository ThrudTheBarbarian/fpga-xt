/* usb.h — see usb.c */
#ifndef USB_H
#define USB_H

#include <stdint.h>

int  usb_init(void);                            /* <0 if it refused to start */
void usb_task(void);                            /* call from the main loop */
int  usb_started(void);
void usb_status(void);                          /* REPL readout */
uint8_t usb_consol(void);                       /* active-low CONSOL state */

#endif /* USB_H */
