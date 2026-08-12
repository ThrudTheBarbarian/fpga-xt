/* usb.h — see usb.c */
#ifndef USB_H
#define USB_H

int  usb_init(void);                            /* <0 if it refused to start */
void usb_task(void);                            /* call from the main loop */
int  usb_started(void);
void usb_status(void);                          /* REPL readout */

#endif /* USB_H */
