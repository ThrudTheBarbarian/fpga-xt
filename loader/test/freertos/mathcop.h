/* mathcop.h — math-coprocessor mailbox ABI (shared 6502 <-> A9 contract).
 *
 * The 6502 maps an 8 KB "math page" over $4000-$5FFF ($D5C6.0), fills operand
 * slots + an op program, and strobes $D5C7 (EXEC).  The PL flushes the page's
 * dirty lines to the task's backing DDR chunk and raises IRQ 62; the worker
 * task here runs the program on the A9's VFP/libm and writes results + STATUS
 * back into the chunk; the PL reloads the result span and raises $D5C7.0
 * (done).  One doorbell round-trip per PROGRAM, not per operation.
 *
 * ---- page layout (8 KB, byte offsets; all values little-endian) ----------
 *   0x0000  u16  op_count      number of 32-bit op WORDS used (a vector op
 *                              counts as 2 — it is two words in the stream)
 *   0x0002  u8   abi_version   MC_ABI_VERSION
 *   0x0003  u8   status        written by the A9 (MC_ST_*), read after done
 *   0x0004  ...                reserved (zero)
 *   0x0040  slots S0..S255     8 bytes each (2 KB); also the byte-addressable
 *                              vector memory — see vector ops below
 *   0x0840  op words           4 bytes each, up to 1024 words (4 KB)
 *   0x1840  ...                reserved / scratch (never touched by the A9)
 *
 * ---- scalar op word -------------------------------------------------------
 *   byte 0   [7:6] element type (MC_T_*)   [5:0] operation (MC_OP_*)
 *   byte 1   src1 slot index
 *   byte 2   src2 slot index (unary ops ignore; CVT: [1:0] = SOURCE type)
 *   byte 3   dst  slot index
 * A slot holds one value in its low bytes: f32/i32 in bytes 0-3 (4-7 don't
 * care), f64/i64 in bytes 0-7.  dst = op(src1, src2).
 *
 * ---- vector (SIMD) op: TWO consecutive op words --------------------------
 *   word 0   as scalar (op in the vector range; slot bytes = BASE slots)
 *   word 1   byte 0 = lane count (0 means 256)
 *            byte 1 = src1 stride   } signed, in ELEMENTS; 0 on a src =
 *            byte 2 = src2 stride   } broadcast that single element
 *            byte 3 = dst  stride
 * Vector elements are PACKED from the base slot's byte offset: element i of
 * a vector based at slot B with stride s lives at byte B*8 + i*s*esize.  All
 * elements must stay inside the slot region (S0..S255); an out-of-range
 * access sets MC_ST_RANGE and aborts the program.  One vector op = one word
 * pair, so a 32-element multiply is 8 bytes of program instead of 32 scalar
 * ops — and a 4x4 matmul is 16 VDOTs (row stride 1, column stride 4).
 */

#ifndef MATHCOP_H
#define MATHCOP_H

#include <stdint.h>

#define MC_ABI_VERSION      1

/* page layout */
#define MC_PAGE_SIZE        8192
#define MC_OFF_OPCOUNT      0x0000      /* u16 */
#define MC_OFF_ABIVER       0x0002      /* u8  */
#define MC_OFF_STATUS       0x0003      /* u8  */
#define MC_OFF_SLOTS        0x0040      /* 256 x 8 B */
#define MC_NSLOTS           256
#define MC_OFF_OPS          0x0840      /* up to 1024 x 4 B */
#define MC_MAX_OPS          1024

/* status byte (A9 -> 6502, at MC_OFF_STATUS) */
#define MC_ST_OK            0x01        /* program ran to completion */
#define MC_ST_DIV0          0x02        /* integer or FP divide by zero */
#define MC_ST_INVALID       0x04        /* an FP op produced NaN/Inf */
#define MC_ST_BADOP         0x08        /* unknown opcode / op-type combo */
#define MC_ST_RANGE         0x10        /* vector element outside the slots */

/* element types (op word byte 0 [7:6]) */
#define MC_T_F32            0
#define MC_T_F64            1
#define MC_T_I32            2
#define MC_T_I64            3

/* scalar operations (op word byte 0 [5:0]) */
#define MC_OP_NOP           0x00
#define MC_OP_ADD           0x01
#define MC_OP_SUB           0x02
#define MC_OP_MUL           0x03
#define MC_OP_DIV           0x04
#define MC_OP_NEG           0x05
#define MC_OP_ABS           0x06
#define MC_OP_SQRT          0x07
#define MC_OP_MIN           0x08
#define MC_OP_MAX           0x09
#define MC_OP_CMP           0x0A        /* dst.i32 = -1 / 0 / +1 */
#define MC_OP_REM           0x0B        /* fmod / integer remainder */
/* FP only (MC_T_I* -> MC_ST_BADOP) */
#define MC_OP_SIN           0x10
#define MC_OP_COS           0x11
#define MC_OP_TAN           0x12
#define MC_OP_ASIN          0x13
#define MC_OP_ACOS          0x14
#define MC_OP_ATAN          0x15
#define MC_OP_ATAN2         0x16
#define MC_OP_EXP           0x17
#define MC_OP_LOG           0x18
#define MC_OP_LOG10         0x19
#define MC_OP_POW           0x1A
#define MC_OP_FLOOR         0x1B
#define MC_OP_CEIL          0x1C
#define MC_OP_ROUND         0x1D
#define MC_OP_TRUNC         0x1E
/* conversion: op-word type field = DEST type, src2 byte [1:0] = SOURCE type */
#define MC_OP_CVT           0x20
/* integer only (MC_T_F* -> MC_ST_BADOP) */
#define MC_OP_AND           0x28
#define MC_OP_OR            0x29
#define MC_OP_XOR           0x2A
#define MC_OP_NOT           0x2B
#define MC_OP_SHL           0x2C
#define MC_OP_SHR           0x2D        /* logical */
#define MC_OP_SAR           0x2E        /* arithmetic */

/* vector operations (two-word; op word byte 0 [5:0]) */
#define MC_OP_VECBASE       0x30
#define MC_OP_VADD          0x30
#define MC_OP_VSUB          0x31
#define MC_OP_VMUL          0x32
#define MC_OP_VDIV          0x33
#define MC_OP_VMIN          0x34
#define MC_OP_VMAX          0x35
#define MC_OP_VABS          0x36        /* unary: src2/stride2 ignored */
#define MC_OP_VNEG          0x37
#define MC_OP_VSQRT         0x38
#define MC_OP_VMLA          0x39        /* dst[i] += src1[i] * src2[i] */
#define MC_OP_VCOPY         0x3A        /* dst[i] = src1[i] (gather/scatter) */
#define MC_OP_VDOT          0x3B        /* reduction: dst slot = sum(s1*s2) */
#define MC_OP_VSUM          0x3C        /* reduction: dst slot = sum(s1) */
#define MC_OP_VCVT          0x3D        /* dst type = type field; src type = word0 byte2 [1:0] */
#define MC_OP_VECTOP        0x3D        /* highest defined vector op */

/* ---- 6502-side registers (CCTL gap, BANK unlock group) ------------------ */
#define MC_REG_CTL          0xD5C6      /* bit 0 = map the math page over $4000 */
#define MC_REG_EXEC         0xD5C7      /* W: doorbell; R: {chunk_ready,busy,done} */
#define MC_REG_CHUNK        0xD5C8      /* backing chunk index (0 = none) */

/* ---- A9 side ------------------------------------------------------------- */
#define MC_CHUNK_BASE       0x20800000u /* screen_bank/math chunk stack in DDR */
#define MC_CHUNK_SIZE       8192u
#define MC_GIC_IRQ_ID       62          /* IRQ_F2P[1] */

#define MC_GP0_EVT          0x43C00600u /* R: [8]=valid, [7:0]=chunk; read pops */
#define MC_GP0_DONE         0x43C00604u /* W: [23:16]=line count, [15:8]=first line, [7:0]=chunk */
#define MC_GP0_STAT         0x43C00608u /* R: engine busy / resident chunk / FIFO fill */

void mathcop_init(void);                /* GIC setup + worker task (pre-scheduler) */

#endif /* MATHCOP_H */
