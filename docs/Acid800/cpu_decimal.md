# cpu_decimal — CPU: Decimal mode

**Pins down:** NMOS decimal-mode `ADC` results **and flags**, including the
cases where the flags do not follow the decimal result.

Source: [`src/cpu_decimal.s`](src/cpu_decimal.s). Four assertions, in two pairs
— each pair checks a result *and* the flags it produced.

| var | expect | assertion |
|---|---|---|
| `d0` | `$25` | `$06+$19=$%x, should be $25.` |
| `d1` | `$00` | `$00+$10 flags incorrect: $%x, should be $00.` |
| `d0` | `$96` | `$7e+$11+1=$%x, should be $96.` |
| `d1` | `$c0` | `$7e+$11+1 flags incorrect: $%x, should be $C0.` |

The second pair is the sharp one. `$7e + $11 + carry` in decimal gives `$96`,
and the flags are `$C0` — **N and V both set**. On the NMOS 6502, decimal `ADC`
takes `N` and `V` from the *intermediate* value **before** the high-nibble
fixup, not from the final BCD answer, and takes `Z` from the **binary** sum. A
model that computes the decimal result and then derives all its flags from it
gets `$96` right and `$C0` wrong.

## Our implementation

`emu/xt6502.c`'s `op_adc()` does exactly this:

```c
uint32_t inter = (c->a & 0xf0u) + (v & 0xf0u) + al;
c->p = (c->p & ~(XTF_N | XTF_V)) | (inter & 0x80u);   /* N from the intermediate */
setv(c, (~(c->a ^ v) & (c->a ^ (unsigned char)inter) & 0x80) != 0);
if (inter > 0x9fu) inter += 0x60u;                    /* ...fixup AFTER */
setc(c, inter > 0xffu);
c->p = (c->p & ~XTF_Z) | (((bin & 0xffu) == 0) ? XTF_Z : 0);  /* Z from BINARY */
```

Harte covers decimal `ADC`/`SBC` across all addressing modes, so this is already
gated — but this test is the readable statement of *why* the code is shaped that
way, which the Harte vectors are not.
