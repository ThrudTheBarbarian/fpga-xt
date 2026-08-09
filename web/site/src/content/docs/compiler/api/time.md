---
title: Time
description: Read the Atari real-time clock, measure elapsed jiffies and seconds, and busy-wait for fixed durations.
---

`Time` exposes the Atari `RTCLOK` three-byte timer (`$12`/`$13`/`$14`) as a 24-bit jiffy counter, plus helpers for measuring elapsed time in seconds and for busy-waiting for fixed durations. All methods are `static`.

```c
#import <Time.xc>
```

A **jiffy** is one VBI tick — that's 1/50 s on PAL hardware and 1/60 s on NTSC. `Time` detects PAL vs NTSC at runtime by reading the GTIA `PAL` register at `$D014`, so `secondsSince` and `delaySeconds` work correctly without per-platform recompilation.

## Reading the timer

```c
static void clearTimer(void);        // reset RTCLOK to zero
static u32  timerValue(void);        // current RTCLOK as 24-bit jiffies in u32
```

`timerValue` reads all three bytes in 9 cycles to minimise the chance of a VBI firing mid-read and corrupting the result.

```c
Time.clearTimer();
// … work …
u32 elapsed = Time.timerValue();
```

## Elapsed-time helpers

```c
static u32    ticksSince(u32 oldValue);
static float  secondsSince(u32 oldValue);
static double dpSecondsSince(u32 oldValue);
```

`ticksSince` returns elapsed jiffies; `secondsSince` divides by the auto-detected frame rate to give seconds as a `float`. `dpSecondsSince` is the double-precision form — useful for very long-running intervals where `float`'s ~7 significant digits would round away jiffy-level precision.

```c
u32 t0 = Time.timerValue();
heavyWork();
u32   jiffies = Time.ticksSince(t0);
float secs    = Time.secondsSince(t0);

Stdio.printf("work took %lu jiffies (%f s)\n", jiffies, secs);
```

The reason `dpSecondsSince` is named distinctly rather than overloading `secondsSince` by return type: xtc only uses return-type as a tiebreaker for **zero-arg** overloads. A `secondsSince(u32) → float` and `secondsSince(u32) → double` pair would be flagged as a redefinition.

## Busy-wait delays

```c
static void delayJiffies(u32 jiffies);
static void delaySeconds(float secs);
```

Both block until the specified time has passed, polling `RTCLOK` rather than relying on OS timers — so they're robust against OS timer reloads and handle rollover safely.

```c
Stdio.print("starting in ");
for (u8 i = 3; i > 0; i--) {
    Stdio.printf("%u... ", (u16)i);
    Time.delaySeconds(1.0);
}
Stdio.print("go!\n");
```

`delaySeconds` accepts any non-negative `float`. The implementation does not route through `fpMul` (which has a bug on floats whose stored mantissa is zero); instead it converts the float's mantissa to a `u32` and shifts to produce a jiffy count, which is handed to `delayJiffies`. Negative inputs and absurdly large values both fall through to a zero-jiffy delay rather than spinning forever.

## What "jiffy" actually is

Every Atari VBI increments the low byte of `RTCLOK` (`$14`); when it overflows, the mid byte (`$13`) advances; when that overflows, the high byte (`$12`). `timerValue` packs the three into a little-endian `u32`:

```
result = $12 << 16 | $13 << 8 | $14
```

That gives a 24-bit jiffy counter (max `$FFFFFF`, ~16.7 million jiffies). At 50 Hz that's about 93 hours before rollover; at 60 Hz it's about 78 hours. `ticksSince` subtracts using two's-complement arithmetic, so it handles a single rollover transparently — but if more than one rollover happens between the start mark and the read, the result is wrong.

## Platform notes

`Time` is reimplemented per-architecture. The native backends read a real monotonic clock through the host runtime rather than the Atari `RTCLOK` jiffy counter, and the shared methods keep their semantics — but the surface is **not** the same size:

| Method | xt6502 | arm64 |
|---|---|---|
| `clearTimer()`, `timerValue()`, `ticksSince()`, `secondsSince()`, `delayJiffies()` | yes | yes |
| `dpSecondsSince(u32)` | yes | **no** |
| `delaySeconds(float)` | yes | **no** |

Calling one of the missing two on a native backend is a compile error (`No method 'delaySeconds' on class 'Time'`), not a silent no-op. On arm64, `Time.delayJiffies(n)` is the available wait.
