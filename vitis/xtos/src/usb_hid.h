/* usb_hid.h — TinyUSB host (USB0) bring-up glue for xtos. */
#ifndef USB_HID_H
#define USB_HID_H

void usb_hid_init(void);   /* bring up the USB0 host controller (tuh_init) */
void usb_hid_task(void);   /* poll the host stack; call from the main loop */

#endif
