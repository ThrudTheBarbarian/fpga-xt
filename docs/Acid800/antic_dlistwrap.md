# antic_dlistwrap — ANTIC: Display list wrapping

**Pins down:** what happens to a display list that runs past the bottom of the
frame, and whether a pending DLI survives VBLANK and `NMIRES`.

Source: [`src/antic_dlistwrap.s`](src/antic_dlistwrap.s). Three tests, three
assertions.

| # | assertion | establishes |
|---|---|---|
| 1 | `Display list did not wrap around.` (`d0 = $01`) | a display list longer than 240 lines **continues into the next frame** rather than being abandoned at the frame boundary |
| 2 | `DLI was not carried over around VBLANK.` (`d0 = $01`) | a DLI pending when VBLANK arrives is **still delivered afterwards**, with display-list DMA enabled |
| 3 | *(third test)* | **`NMIRES` does not clear a pending DLI** |

Test 2's method is worth noting: it disables display-list DMA at scanline 14/15,
waits through VBLANK, then re-enables NMIs at scanline 32 of the *next* frame and
checks the DLI still arrives. So the pending request survives both the DMA being
turned off and the frame boundary.

Test 3 is the counterpart to the `NMIRES` rule in
[`antic_nmist`](antic_nmist.md): `NMIRES` clears the **status bit** but must not
retract a **request** already raised. Here that is checked across the frame
boundary as well.

## To pass this test you must have

1. Display-list execution that does not reset at the frame boundary — the list
   continues where it left off.
2. A pending DLI request that survives VBLANK **and** display-list DMA being
   disabled.
3. `NMIRES` clearing status only, never a pending request.

Point 2 is the one that catches models which rebuild their DLI schedule per
frame: a request raised in the old frame has to survive into the new one.
