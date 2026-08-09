# gtia_collision — GTIA: Collision test

**Pins down:** *where* collisions are detected — the horizontal and vertical
blanking boundaries — rather than the logic of which object hits which.

Source: [`src/gtia_collision.s`](src/gtia_collision.s). 13 assertions.

**Do this test first.** `antic_pfstarttiming`, `antic_pfstoptiming`,
`antic_linebuffering`, `antic_addresswrap` and `antic_hiresbug` all read their
answers out through collision registers, so until this passes those five give
ambiguous failures.

## The map it builds

| region | M/P collisions | P/P collisions | assertion |
|---|---|---|---|
| all sprites parked in HBLANK | — | — | `Phantom collisions detected.` (expect `$00`) |
| overlapping, fully visible | `$0f` | | `M/P collisions were not correct in total case.` |
| HBLANK, left | `$0f` | `$00` | `M/P collisions were detected in HBLANK on left.` / `P/P collisions were detected in HBLANK on left.` |
| HBLANK, right | `$0f` | `$00` | same pair for the right side |
| visible, left edge (`$22`) | `$0f` | | `Missing M/P collisions on left at $22.` |
| visible, right edge (`$DD`) | `$0f` | | `Missing P/M collisions on right at $DD.` |
| straddling the left HBLANK edge (`$21`–`$22`) | `$0f` | | `Missing M/P collisions on left at $21-$22.` |
| VBLANK | `$00` | `$00` | four assertions: P/M, P/P, M/PF and P/PF all clear |

## What that adds up to

1. **No collisions of any kind during VBLANK** — all four register classes must
   read `$00`. A model that runs its collision comparator every colour clock of
   every scanline fails four assertions here.
2. **Horizontal blanking is asymmetric between collision classes.** In HBLANK
   the missile/player registers still show `$0f` while player/player shows
   `$00`. So HBLANK does not simply gate "all collisions off"; the classes
   behave differently.
3. **The visible-region boundaries are specific**: `$22` on the left and `$DD`
   on the right are named positions, and a sprite **straddling** the left edge
   at `$21`–`$22` must still collide. So the boundary is per-colour-clock, not
   per-sprite: partial overlap counts.
4. **Phantom collisions are a real failure mode** — the first assertion exists
   because parking everything in HBLANK is exactly when a sloppy model invents
   collisions.

## To pass this test you must have

1. A collision comparator gated **off entirely during VBLANK**.
2. Per-class HBLANK behaviour: M/P still registering, P/P not.
3. Per-colour-clock evaluation so a partially-blanked sprite collides on the
   visible clocks only.
4. Correct visible-region edges at `$22` and `$DD`.

Point 3 is the structural requirement and it matches the rule already in
[`../../emu/antic-design.md`](../../emu/antic-design.md): collisions come off the
emitted pixel stream, one colour clock at a time. A renderer that composes a
scanline in one step cannot express "collided on the visible half of the sprite
only".
