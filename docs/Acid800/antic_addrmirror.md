# antic_addrmirror — ANTIC: Address mirroring

**Pins down:** that ANTIC's registers are **mirrored every `$20` bytes** across
its address space, for reads *and* for write strobes.

Source: [`src/antic_addrmirror.s`](src/antic_addrmirror.s). Asserts by control
flow (`_FAIL`).

## What it checks

| check | `_FAIL` message |
|---|---|
| `VCOUNT` read through the mirror at `vcount+$20` matches the real one | `VCOUNT mirror mismatch: $%x != $10` |
| `NMIST` bit 6 sets on VBLANK | `NMIST bit 6 was not set on VBLANK.` |
| …and is visible through the mirror | `NMIST mirror bit 6 was not set on VBLANK.` |
| `NMIRES` clears it | `NMIST bit 6 was not cleared by NMIRES.` |
| …and the clear is visible through the mirror | `NMIST mirror bit 6 was not cleared by NMIRES.` |

The test reads `vcount` and `vcount+$20` at the same VCOUNT value and requires
them to agree, so the mirror must be a genuine alias rather than a separate
register that happens to be initialised the same.

## To pass this test you must have

ANTIC decoded on **5 address bits** (`$D400`–`$D41F`) with the rest of the
`$D4xx` page aliasing onto it — for reads, and for write-triggered strobes like
`NMIRES`. A decoder that matches the full address, or that mirrors reads but not
strobes, fails.
