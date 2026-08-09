# antic_vscroldli — ANTIC: VSCROL+NMI timing

**Pins down:** the exact scanline cycle by which a write to `VSCROL` (`$D405`)
must land to affect the **current** display-list row — measured indirectly, by
whether the row's DLI fires.

Source: [`src/antic_vscroldli.s`](src/antic_vscroldli.s). Two assertions, one
cycle apart, with opposite expected answers.

## Method

`VSCROL` changes how many scanlines a vertically-scrolled row occupies. If a
write takes effect on the current row, the row is extended and its DLI is
correspondingly delayed; if the write is a cycle too late, the row ends on
schedule and the DLI has already fired. So the test reads `NMIST` bit 7 to find
out which happened — a one-bit answer to a one-cycle question.

The display list places a vertically-scrolled mode line followed by a
blank-plus-DLI line:

```
dlist:  dta $70 / $70 / $70    ; blank 8 x3            -> 8, 16, 24
        dta $28                ; mode 8 + VSCROL bit   -> 32
        dta $f0                ; blank 8 + DLI         -> 40
        dta $70                ; blank 8
        dta $28                ; mode 8 + VSCROL
        dta $f0                ; blank 8 + DLI
        dta $41,a(dlist)
```

## The two probes

Both re-synchronise with `sta wsync` (CPU resumes at 105), spend a known number
of cycles, then write `VSCROL` with `stx vscrol` (`STX abs`, 4 cycles, the write
on its last cycle).

**Probe 1 — must still take effect:**

```
pha:pla         ;*, 104, 105, 106, 107, 108, 109
lda $0100       ;110, 111, 112, 113
stx vscrol      ;0, 1, 2, 3        <- write commits on cycle 3
...
lda nmist / and #$80
_ASSERTA $00, c"VSCROL took effect too late."
```

Expecting `A == $00`: **no DLI yet**, because the row was extended.

**Probe 2 — must be too late:**

```
pha:pla         ;*, 104, 105, 106, 107, 108, 109
inc d0          ;110, 111, 112, 113, 0
stx vscrol      ;1, 2, 3, 4        <- write commits on cycle 4
...
lda nmist / and #$80
_ASSERTA $80, c"VSCROL took effect too early."
```

Expecting `A == $80`: **the DLI has fired**, because the write missed the
sampling point and the row ended on schedule.

## The result

> `VSCROL` is sampled such that a write committing on scanline cycle **3** still
> affects the current row, and one committing on cycle **4** does not.

The two probes are otherwise identical and differ only in the 5-cycle `inc d0`
versus the 4-cycle `lda $0100` preceding them. A model that samples `VSCROL` at
the start or the end of the line fails one of the two.

## To pass this test you must have

1. `VSCROL` sampled for the current row with the boundary between cycle 3 and
   cycle 4.
2. Vertically-scrolled rows whose length actually responds to `VSCROL` mid-row.
3. The DLI on the *following* blank-plus-DLI line moving with the extended row —
   i.e. DLI scheduling derived from the real row length, not from a precomputed
   scanline map.
4. `NMIST` bit 7 reflecting DLI status, and `NMIRES` clearing it.

Point 3 is the one that bites: an ANTIC that precomputes which scanline each DLI
falls on cannot pass this, because the row length is not known until `VSCROL`
is sampled.
