#pragma once

#include <stdint.h>

// peri-RP IRQ_OUT drive (M25-3d).
//
// IRQ_OUT is a single open-drain GPIO that the peri-RP holds low
// whenever any unmasked flag bit is set in the STATUS register
// ($D003 on the wire) and releases when STATUS clears. The FPGA's
// `peri_link.peri_irq_pulse` edge-detects the falling edge and the
// bridge above peri_link (peri_pot_bridge today) uses the pulse to
// short-circuit its poll-tick wait.
//
// Multiple IRQ sources coalesce on the single line: M25-3c sets
// STATUS.pot_done; M25-4 will set STATUS.sio_rx; M25-5 will set
// STATUS.sd_done. Each of those calls `peri_irq_update()` after
// touching STATUS so the pin level tracks.

void peri_irq_init(void);

// Re-evaluate STATUS and drive IRQ_OUT accordingly. Call this from
// any path that writes STATUS (peri_pot_service after setting
// pot_done; peri_regs_handle after a STATUS read clears flags;
// future M25-4 / M25-5 service paths).
void peri_irq_update(void);

#ifdef PERI_POT_HOST_SIM
// Test hook — returns the IRQ_OUT pin level that would be driven
// (1 = released = IRQ inactive; 0 = pulled low = IRQ asserted).
int  peri_irq_host_pin_level(void);
#endif
