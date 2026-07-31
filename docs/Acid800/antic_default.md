# antic_default — ANTIC: Default value

**Pins down:** what a read of an unused/write-only ANTIC register returns.

Source: [`src/antic_default.s`](src/antic_default.s). One assertion. The whole
test is four instructions:

```
lda $d406
sta d0
_ASSERT1 d0, $ff, c"ANTIC default value wrong: $%x"
```

> Reading `$D406` returns **`$FF`**.

`$D406` is not a readable ANTIC register. The value is what the bus floats to
when nothing drives it, and on this hardware that is all-ones — not zero, and
not the last value written.

## To pass this test you must have

Unmapped/write-only ANTIC register reads returning `$FF` rather than `$00` or
open-bus-of-last-write. Trivial to implement and trivial to get wrong by
defaulting a register array to zero.
