# antic_addresswrap — ANTIC: Address wrapping

**Pins down:** that the **display-list address counter wraps at a 1 KB
boundary** and the **playfield (LMS) address counter wraps at a 4 KB boundary** —
and that the display-list wrap happens even in the middle of an instruction's
operand.

Source: [`src/antic_addresswrap.s`](src/antic_addresswrap.s). Two assertions
plus a `_FAIL` in a DLI.

## The construction

This test is built almost entirely out of its display list, and the comment says
it plainly:

> *"The display list itself wraps around from `$27fb` to `$2403`, with the break
> in the middle of an LMS address. The playfield is located at `$2ff0` so that it
> contains a 4K wrap back to `$2000`."*

```
        org $2400
        dta $2f                 ; high byte of the $2ff0 LMS — read AFTER the wrap
        dta $41,a(dlist)
        org $27fb
dlist:  dta $70 / $70 / $70
        dta $4f,$f0,$3f         ; 1K address boundary in the middle of the address!
        dta $80                 ; fires a DLI if the wrap did NOT happen
        dta $41,a(dlist)
```

So ANTIC must fetch the LMS opcode and low byte near `$27fd`, wrap to `$2400`,
and take the **high byte from there**. If it instead ran on into `$2800`, it
would read the `$80` byte, fire a DLI, and hit `_FAIL c"Display list failed to
wrap at 1K boundary."`.

## The readout

Two players are parked over the screen and collisions report the result:

| assertion | expect | meaning |
|---|---|---|
| `p0pf` | `$00` | `Display list LMS address did not wrap at 1K boundary.` |
| `p1pf` | `$00` | `Playfield DMA did not wrap at 4K boundary.` |

A wrap failure puts the playfield somewhere it should not be, which the players
then collide with. Absence of collision is the pass.

## To pass this test you must have

1. The **display-list address counter 10 bits wide within its 1 KB page** — the
   high 6 bits do not increment.
2. The wrap applying **mid-instruction**, so an LMS operand can straddle it.
3. The **playfield/LMS address counter wrapping at 4 KB**.
4. Collision detection, again, as the readout.

Both counters are commonly implemented as plain 16-bit adders, which passes
casual testing and fails this immediately.
