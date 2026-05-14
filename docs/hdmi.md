# HDMI output

## Mandatory (no picture without these)                                                                      
                                                                                                            
  1. HDMI Type-A (or DVI-D) connector with 100 Ω differential pair routing on the PCB, intra-pair length match within a few mil, inter-pair within ~50–100 ps (7.5mm to 15mm) 
  2. A way to get TMDS-compliant levels onto the cable. Trion LVDS outputs aren't real TMDS drivers, so use an external TMDS redriver/buffer — e.g. SN65DP159 / TMDS181. Clean eye, real TMDS swings, comfortable margin at 200/250 MHz in case we ever want to go there.                                                                                  
  3. +5 V on HDMI pin 18 to the sink. Min 55 mA. A polyfuse + ferrite from board 5 V is enough. We'll use an HDMI ESD/load-switch IC (TPD12S016). This also copes with HPD and DDC {SCL/SDA} voltage conversion and gives us ESD protection                                                     
                                 
                                                 
## Optional / can ignore for now                          

  4. CEC (pin 13), HEC/utility (pin 14), audio (we're DVI-mode TMDS anyway until M14b grows audio islands). Strongly desire audio islands, so we'll see how this goes

 
 ## What M14b does not give you on its own

  - The PLL config in pll_pix.sv is correct, but the Trion timing constraint for the 250 / 200 MHz tmds_clk has to actually close at P&R (M19 — already flagged in the roadmap at line 286–287, 357).
  - A pin-out / IO-bank assignment in the Efinity interface designer that puts the four pairs on bank pins capable of driving LVDS_E_3R at the required VCCIO. TZ50F256 has lots of 1.8 V LVDS-capable banks and the TPD12S016 handles that voltage-level signalling while buffering the signal.                                                                                                            
                                                                                                            
