# cpu_illtiming — CPU: Illegal instruction timing

**Pins down:** the cycle counts of the undocumented opcodes, measured on real
hardware.

Source: [`src/cpu_illtiming.s`](src/cpu_illtiming.s). Asserts by control flow;
same double `_SKIP` as [`cpu_illegal`](cpu_illegal.md).

## Method, and the detail worth having

```
;set loop counter (228 cycles - 18 refresh cycles)
;sync and delay to mid-scanline for some safety margin
;load A and wait for vcount=0
;execute insn 210 times
```

It runs each instruction **210 times** and measures the total, so a one-cycle
error is amplified far above the noise. And the loop counter comment states the
budget explicitly:

> **228 cycles − 18 refresh cycles**

That is a two-scanline window (2 × 114) minus **18 DRAM refresh cycles**. This
is the second place the suite tells us refresh is real and countable — the other
is [`antic_hscrolbug`](antic_hscrolbug.md)'s DMA map legend. Any model that
omits refresh loses 18 cycles per two scanlines, which this test would report as
every illegal opcode being uniformly too fast.

## Subsumed by Harte, with one caveat

Cycle counts for all 256 opcodes are implied by the exact bus traces
`emu/test/harte.c` already checks, so the *instruction* side is gated.

What this test adds is that it measures **in a running system**, with DMA and
refresh stealing cycles around the instruction under test. So it is really a
system-timing test wearing a CPU test's name: if Harte passes and this fails,
the fault is in the DMA/refresh model, not the opcode.
