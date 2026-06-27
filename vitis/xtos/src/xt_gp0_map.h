/*
 * xt_gp0_map.h — the PL control-register map over PS GP0 (@ 0x43C0_0000).
 *
 * Single source of truth for the A9-side register addresses; mirrors the
 * hardware decode in hdl/xt_gp0_regs.sv.  The map is partitioned into per-device
 * 256-byte blocks; every register is 32-bit word-aligned, so software uses
 * Xil_In32 / Xil_Out32 (no byte-lane tricks), and reads never alias writes.
 *
 *   0x000  BLITTER     blit regs (offset = bl_addr) + STATUS/SEQ reads
 *   0x100  SPRITE      sprite-engine reg index/data port
 *   0x200  COMPOSITOR  drag-overlay config (whole words)
 *   0x300  CONTROL     gp0_ctrl, SALLY speed, XT unlock, keyboard inject
 *   0x400  DIAG        seven read-only PL diagnostic words
 *   0x1000+            sally_rom_loader (ROM image init; not a register)
 */
#ifndef XT_GP0_MAP_H_
#define XT_GP0_MAP_H_

#ifndef XT_GP0_BASE
#define XT_GP0_BASE      0x43C00000u
#endif

/* ---- per-device block bases ---------------------------------------------- */
#define XT_BLK_BLITTER   (XT_GP0_BASE + 0x000u)
#define XT_BLK_SPRITE    (XT_GP0_BASE + 0x100u)
#define XT_BLK_COMP      (XT_GP0_BASE + 0x200u)
#define XT_BLK_CTRL      (XT_GP0_BASE + 0x300u)
#define XT_BLK_DIAG      (XT_GP0_BASE + 0x400u)

/* ---- Blitter block: writes at offset == the blitter's bl_addr (see blitter.h
 *      XT_BL_* offsets 0x00..0x18 + descriptors 0x30..0x3B); reads here: ----- */
#define XT_BLT_STATUS    (XT_BLK_BLITTER + 0x40u)  /* R {pat_blocked,qfull,busy} */
#define XT_BLT_SEQ       (XT_BLK_BLITTER + 0x44u)  /* R seq_counter[15:0]        */

/* ---- Sprite block -------------------------------------------------------- */
#define XT_SPR_IDX       (XT_BLK_SPRITE + 0x00u)   /* W sprite reg index         */
#define XT_SPR_DATA      (XT_BLK_SPRITE + 0x04u)   /* W sprite reg data + strobe */

/* ---- Compositor block (drag overlay, whole 32-bit words) ----------------- */
#define XT_OVL_EN        (XT_BLK_COMP + 0x00u)     /* W [0]=enable, commits set  */
#define XT_OVL_BASE      (XT_BLK_COMP + 0x04u)     /* W DDR base (32-bit)        */
#define XT_OVL_X         (XT_BLK_COMP + 0x08u)     /* W on-screen X (12-bit)     */
#define XT_OVL_Y         (XT_BLK_COMP + 0x0Cu)     /* W on-screen Y (12-bit)     */
#define XT_OVL_W         (XT_BLK_COMP + 0x10u)     /* W width  (12-bit)          */
#define XT_OVL_H         (XT_BLK_COMP + 0x14u)     /* W height (12-bit)          */

/* ---- Control block ------------------------------------------------------- */
#define XT_CTRL_GP0      (XT_BLK_CTRL + 0x00u)     /* W/R [0]bars [3:1]XLscale [4]blank */
#define XT_CTRL_SPEED    (XT_BLK_CTRL + 0x04u)     /* W/R SALLY clock_mult       */
#define XT_CTRL_UNLOCK   (XT_BLK_CTRL + 0x08u)     /* W/R XT register-unlock     */
#define XT_CTRL_KBD_INJECT  (XT_BLK_CTRL + 0x0Cu)  /* W KBCODE + POKEY IRQ       */
#define XT_CTRL_KBD_RELEASE (XT_BLK_CTRL + 0x10u)  /* W all-keys-up              */
#define XT_CTRL_KBD_BREAK   (XT_BLK_CTRL + 0x14u)  /* W Atari BREAK              */

/* ---- Diagnostics block (read-only) --------------------------------------- */
#define XT_DIAG0         (XT_BLK_DIAG + 0x00u)  /* MMCM locks / clk_pix-alive / frame ct */
#define XT_DIAG2         (XT_BLK_DIAG + 0x04u)  /* production-chain counters             */
#define XT_DIAG3         (XT_BLK_DIAG + 0x08u)  /* read-path activity                    */
#define XT_DIAG4         (XT_BLK_DIAG + 0x0Cu)  /* HP3 (XL) first-AR address             */
#define XT_DIAG5         (XT_BLK_DIAG + 0x10u)  /* HP0 (desktop) first-AR address        */
#define XT_DIAG6         (XT_BLK_DIAG + 0x14u)  /* HP2 read-probe status                 */
#define XT_DIAG7         (XT_BLK_DIAG + 0x18u)  /* HP2 read-probe last rdata             */

#endif /* XT_GP0_MAP_H_ */
