# gtia_vdelay — GTIA: Vertical Delay

**Pins down:** what `VDELAY` (`$D01C`) does to a player/missile in two-line
resolution — which of the two scanlines of each pair the object appears on.

Source: [`src/gtia_vdelay.s`](src/gtia_vdelay.s). Eight assertions, in two sets
of four consecutive scanlines.

| | line 1 | line 2 | line 3 | line 4 |
|---|---|---|---|---|
| **no `VDELAY`** | on (`$01`) | on (`$01`) | off (`$00`) | off (`$00`) |
| **`VDELAY`** | off (`$00`) | on (`$01`) | on (`$01`) | off (`$00`) |

The test's own comments say it plainly: *"should be on, on, off, off"* and
*"should be off, on, on, off"*.

> `VDELAY` **shifts the object down by one scanline** — it does not stretch it,
> blank it, or change its height. The two-scanline extent is preserved and moved.

That is the whole rule, and it is easy to implement as "skip the first line"
(giving on/off/on/off or a one-line object) which fails half the assertions.

## To pass this test you must have

1. `VDELAY` per-object (it has a bit per player and per missile).
2. A one-scanline downward shift preserving the object's extent.
3. Only meaningful in two-line resolution — the pairing is what is being
   delayed.
