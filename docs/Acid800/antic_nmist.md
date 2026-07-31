# antic_nmist — ANTIC: NMIST/NMIRES

**Pins down:** the semantics of the `NMIST` status register (`$D40F` read) and
the `NMIRES` reset strobe (`$D40F` write) — including the **exact scanline cycle**
at which each status bit is set, at which `NMIRES` takes effect, and at which a
write to `NMIEN` is still in time to arm the interrupt.

Source: [`src/antic_nmist.s`](src/antic_nmist.s). **24 assertions** — the
densest ANTIC test in the suite, and the one that establishes cycle 6 as a
landmark.

## Status-bit semantics (independent of NMIEN)

| assertion | establishes |
|---|---|
| `DLI bit was not set in NMIST with DLIs disabled` (expect `$80`) | the DLI bit sets **regardless of `NMIEN`** — `NMIEN` gates the *interrupt*, not the *status* |
| `DLI bit was not set at scan line 246` (expect `$80`) | still set going into VBLANK |
| `DLI bit was not cleared at scan line 248` (expect `$00`) | the DLI bit is **auto-cleared** when the VBI arrives |
| `VBI bit was not set at scan line 248` (expect `$40`) | VBI bit sets at 248 |
| `VBI bit was cleared before scan line 39` (expect `$40`) | it persists |
| `VBI bit was not cleared at scan line 39` (expect `$00`) | and is cleared when the DLI bit turns on |
| `VBI bit was not set in NMIST with VBIs disabled` (expect `$40`) | same rule as the DLI bit — status is not gated by `NMIEN` |

So the two status bits are **mutually exclusive in practice**: each one's arrival
clears the other. A model that treats `NMIST` as two independent sticky flags
fails four of these.

## The cycle-6 landmark

Four assertions bracket the moment the status bit appears, by reading `NMIST`
one cycle either side:

| assertion | expect |
|---|---|
| `DLI bit set too early (<cycle 6)` | `$00` |
| `DLI bit set too late (>cycle 6)` | `$80` |
| `VBI bit set too early (<cycle 6)` | `$00` |
| `VBI bit set too late (>cycle 6)` | `$40` |

> **`NMIST` status bits are set at scanline cycle 6.**

## NMIRES is one cycle later

| assertion | expect | meaning |
|---|---|---|
| `VBI bit was reset too early` | `$40` | `NMIRES` struck on **cycle 6** does *not* clear the bit |
| `VBI bit was reset too late` | `$00` | `NMIRES` struck on **cycle 7** does |

So the strobe cannot cancel the bit that is being set in the same cycle — it
takes effect from cycle 7 onward. And separately:

> `NMIRES` on cycle 7 clears the status bit but does **not** block the interrupt:
> `_FAIL c"VBI was blocked by NMIRES."`

That is a genuinely easy thing to get wrong. Clearing the status must not
retract an interrupt request that has already been raised.

## NMIEN is sampled at cycle 6 too

| assertion | expect | meaning |
|---|---|---|
| `DLI was not activated by write to NMIEN on cycle 6` | `d1 = $ff` | a write **completing on cycle 6** arms the DLI |
| `DLI was activated by write to NMIEN on cycle 7` | `d1 = $00` | one cycle later is too late |
| `VBI was not activated by write to NMIEN on cycle 6` | `d1 = $ff` | same for the VBI |
| `VBI was activated by write to NMIEN on cycle 7` | `d1 = $00` | |

The two probes differ only by substituting a 5-cycle `inc d2` for a 4-cycle
`lda $0100` plus a `nop`, shifting the `mva #$80 nmien` by exactly one cycle.

> **`NMIEN` is sampled at cycle 6.** A write that commits on cycle 6 arms the
> interrupt for that scanline; a write that commits on cycle 7 does not.

## Handler-invocation checks

Two more assert by control flow:

* `The DLI1 handler was invoked more than once.`
* `The DLI2 handler was invoked more than once.`
* `NMIRES did not clear the DLI bit: $%x` (expect `$00`)

An NMI that re-triggers because the status was not properly consumed shows up
here rather than as a wrong value.

## To pass this test you must have

1. `NMIST` bits set **at cycle 6**, and set **regardless of `NMIEN`**.
2. The DLI and VBI status bits clearing each other on arrival.
3. `NMIRES` effective from **cycle 7**, not cycle 6.
4. `NMIRES` clearing status **without** retracting an already-raised interrupt.
5. `NMIEN` sampled at **cycle 6** for arming.
6. One NMI per event — no re-entry.

## A note on "cycle 6" versus "cycle 8"

This project's fabric work records the DLI landmark as *"physical-scanline map +
cycle 8"*. That is not necessarily in conflict: this test measures when the
**`NMIST` status bit becomes visible** and when **`NMIEN` is sampled**, both of
which are cycle 6, whereas the fabric figure is about when the NMI is
**delivered** to the CPU. The two are separated by the request-to-recognition
path. Worth resolving explicitly once the software model can measure both, since
an unexamined two-cycle discrepancy between them is exactly the kind of thing
that produces a stubborn off-by-one later.
