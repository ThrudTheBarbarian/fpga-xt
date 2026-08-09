# gtia_collision2 — GTIA: Special modes collision test

**Pins down:** how collisions behave in hi-res (Gr.8) and in the GTIA special
modes 9, 10 and 11 (`PRIOR` `$40`/`$80`/`$C0`).

Source: [`src/gtia_collision2.s`](src/gtia_collision2.s). **58 assertions** —
the densest test in the whole suite.

This is the test the fabric P/M cluster was blocked on: GTIA modes 9/10/11 have
to work before that cluster can move.

## Gr.8 (hi-res) — every set pixel collides as PF2

With `PRIOR = $00` and a hi-res playfield, the test walks the four possible
half-clock pixel pairs and checks all eight playfield-collision registers:

| pixel pair | `p0pf`–`p3pf` and `m0pf`–`m3pf` |
|---|---|
| `%00` | `$00` |
| `%01` | `$04` |
| `%10` | `$04` |
| `%11` | `$04` |

> In hi-res, **any** set pixel in the colour-clock collides as **PF2** (`$04`),
> regardless of which half of the pair it is or whether both are set.

That is the mechanism behind [`antic_hiresbug`](antic_hiresbug.md): hi-res does
not present its two half-clock pixels to the collision logic individually — it
presents "something is lit here" as PF2. A model that maps hi-res pixels to
PF1/PF2 by luminance, or that evaluates each half-clock separately, fails all
six of these at once.

## Gr.9 (`PRIOR = $40`) — no playfield collisions at all

```
mva #$40 prior
...
_ASSERTA $00, c"Playfield collisions detected in Gr.9."
```

One assertion, one rule: **mode 9 produces no playfield collisions**. In this
mode the playfield byte is a luminance value rather than a colour index, so
there is no playfield *colour* to collide with.

## Gr.10 (`PRIOR = $80`) — bogus early and late collisions

The largest block. For each of the four players and four missiles it checks
three things:

* `Gr.10 P0 bogus early collision` … `M3 bogus early collision` — expect `$00`
* `Gr.10 $0 collision incorrect` … `$3 collision incorrect` — expect `$00`
* `Gr.10 M0 bogus late collision` … — expect `$00`

The "early" and "late" framing is the point: mode 10 shifts the playfield by one
colour clock relative to the other modes, and a model that does not account for
that produces collisions one clock **before** or **after** the real playfield —
which is what "bogus early/late" names. All expected values here are `$00`, so
any misalignment shows up immediately.

## To pass this test you must have

1. Hi-res collision reported as **PF2 for any set pixel**, not per half-clock
   and not by luminance mapping.
2. Mode 9 (`PRIOR $40`) producing **no** playfield collisions.
3. Mode 10 (`PRIOR $80`) playfield alignment correct to the colour clock, both
   edges.
4. All four players and all four missiles evaluated independently against all
   four playfield classes.

## Sequencing note

The test does *"a second `waitvbl` to make sure we're not in bugged mode"*
before its first measurement — a reminder that GTIA mode changes take effect on
a frame boundary and that reading collisions too soon after a `PRIOR` write
measures the previous mode. Worth reproducing: it is exactly the kind of thing
that makes an otherwise-correct model fail intermittently.
