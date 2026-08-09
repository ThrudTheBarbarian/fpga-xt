# gtia_default — GTIA: Default value

**Pins down:** what a read of an unused GTIA register returns.

Source: [`src/gtia_default.s`](src/gtia_default.s). One assertion:

```
lda gtia+$15
_ASSERTA $0f, c"GTIA default value wrong: $%x"
```

> Reading an unused GTIA register returns **`$0F`**.

**Note the contrast with ANTIC**, which returns `$FF`
([`antic_default`](antic_default.md)). GTIA's readable registers are the 4-bit
collision registers, so GTIA only drives the low nibble of the data bus; the
high nibble is whatever the bus floats to. Two chips on the same bus, two
different "default" values — an emulator with one shared open-bus value gets one
of them wrong.

## To pass this test you must have

Unused GTIA reads returning `$0F`, distinct from ANTIC's `$FF`.
