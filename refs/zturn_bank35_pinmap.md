# Z-Turn (XC7Z020-CLG400) Bank 35 pin map

Extracted from `refs/Z-TURNBOARD_schematic.pdf` page 3 (U10, BANK 35).
MyIR net name (appears on the carrier/expansion connector) -> XC7Z020 package
ball -> Xilinx pin function. Use the **ball** in the XDC `PACKAGE_PIN`.

Bank 35 is currently UNUSED by the design (no overlap with vivado/constraints/
zturn_board.xdc, whose IO are Bank 34 + PS) -> all 50 IO free for cart/PBI.

IOSTANDARD: Bank 35 VCCO = **3.3 V** (CONFIRMED: VDD_3.3V -> FB5 ferrite bead
220R@300mA -> VDDIO_35_PL; banks 13/34 fed the same way via FB3/FB18). Use
LVCMOS33. NB all Bank 35 I/O share FB5's ~300 mA budget -> keep SLEW SLOW /
low DRIVE (fine for the ~1.79 MHz bus). VREF pins (F17, G15) usable as ordinary IO.
Clock-capable: MRCC = K17/K18 (L12), H16/H17 (L13); SRCC = L16/L17 (L11),
J18/H18 (L14) — route any bus-side clock (e.g. external phi2) here.

| MyIR net    | ball | note | Xilinx function          |
|-------------|------|------|--------------------------|
| IO_B35_0    | G14  |      | IO_0_35                  |
| IO_B35_LP1  | C20  |      | IO_L1P_T0_AD0P_35        |
| IO_B35_LN1  | B20  |      | IO_L1N_T0_AD0N_35        |
| IO_B35_LP2  | B19  |      | IO_L2P_T0_AD8P_35        |
| IO_B35_LN2  | A20  |      | IO_L2N_T0_AD8N_35        |
| IO_B35_LP3  | E17  |      | IO_L3P_T0_DQS_AD1P_35    |
| IO_B35_LN3  | D18  |      | IO_L3N_T0_DQS_AD1N_35    |
| IO_B35_LP4  | D19  |      | IO_L4P_T0_35             |
| IO_B35_LN4  | D20  |      | IO_L4N_T0_35             |
| IO_B35_LP5  | E18  |      | IO_L5P_T0_AD9P_35        |
| IO_B35_LN5  | E19  |      | IO_L5N_T0_AD9N_35        |
| IO_B35_LP6  | F16  |      | IO_L6P_T0_35             |
| IO_B35_LN6  | F17  | VREF | IO_L6N_T0_VREF_35        |
| IO_B35_LP7  | M19  |      | IO_L7P_T1_AD2P_35        |
| IO_B35_LN7  | M20  |      | IO_L7N_T1_AD2N_35        |
| IO_B35_LP8  | M17  |      | IO_L8P_T1_AD10P_35       |
| IO_B35_LN8  | M18  |      | IO_L8N_T1_AD10N_35       |
| IO_B35_LP9  | L19  |      | IO_L9P_T1_DQS_AD3P_35    |
| IO_B35_LN9  | L20  |      | IO_L9N_T1_DQS_AD3N_35    |
| IO_B35_LP10 | K19  |      | IO_L10P_T1_AD11P_35      |
| IO_B35_LN10 | J19  |      | IO_L10N_T1_AD11N_35      |
| IO_B35_LP11 | L16  | SRCC | IO_L11P_T1_SRCC_35       |
| IO_B35_LN11 | L17  | SRCC | IO_L11N_T1_SRCC_35       |
| IO_B35_LP12 | K17  | MRCC | IO_L12P_T1_MRCC_35       |
| IO_B35_LN12 | K18  | MRCC | IO_L12N_T1_MRCC_35       |
| IO_B35_LP13 | H16  | MRCC | IO_L13P_T2_MRCC_35       |
| IO_B35_LN13 | H17  | MRCC | IO_L13N_T2_MRCC_35       |
| IO_B35_LP14 | J18  | SRCC | IO_L14P_T2_AD4P_SRCC_35  |
| IO_B35_LN14 | H18  | SRCC | IO_L14N_T2_AD4N_SRCC_35  |
| IO_B35_LP15 | F19  |      | IO_L15P_T2_DQS_AD12P_35  |
| IO_B35_LN15 | F20  |      | IO_L15N_T2_DQS_AD12N_35  |
| IO_B35_LP16 | G17  |      | IO_L16P_T2_35            |
| IO_B35_LN16 | G18  |      | IO_L16N_T2_35            |
| IO_B35_LP17 | J20  |      | IO_L17P_T2_AD5P_35       |
| IO_B35_LN17 | H20  |      | IO_L17N_T2_AD5N_35       |
| IO_B35_LP18 | G19  |      | IO_L18P_T2_AD13P_35      |
| IO_B35_LN18 | G20  |      | IO_L18N_T2_AD13N_35      |
| IO_B35_LP19 | H15  |      | IO_L19P_T3_35            |
| IO_B35_LN19 | G15  | VREF | IO_L19N_T3_VREF_35       |
| IO_B35_LP20 | K14  |      | IO_L20P_T3_AD6P_35       |
| IO_B35_LN20 | J14  |      | IO_L20N_T3_AD6N_35       |
| IO_B35_LP21 | N15  |      | IO_L21P_T3_DQS_AD14P_35  |
| IO_B35_LN21 | N16  |      | IO_L21N_T3_DQS_AD14N_35  |
| IO_B35_LP22 | L14  |      | IO_L22P_T3_AD7P_35       |
| IO_B35_LN22 | L15  |      | IO_L22N_T3_AD7N_35       |
| IO_B35_LP23 | M14  |      | IO_L23P_T3_35            |
| IO_B35_LN23 | M15  |      | IO_L23N_T3_35            |
| IO_B35_LP24 | K16  |      | IO_L24P_T3_AD15P_35      |
| IO_B35_LN24 | J16  |      | IO_L24N_T3_AD15N_35      |
| IO_B35_25   | J15  |      | IO_25_35                 |
