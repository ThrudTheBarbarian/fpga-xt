---
title: Vbi
description: Install and remove Vertical-Blank-Interrupt handlers via the OS-safe SETVBV path.
---

`Vbi` installs and removes Vertical-Blank-Interrupt handlers. Atari 8-bit machines fire a VBI roughly 50 times per second on PAL or 60 on NTSC, and the OS dispatches first to an **immediate** vector for time-critical work, then to a **deferred** vector after its own housekeeping.

```c
#import <Vbi.xt>
```

All methods are `static`. Install / remove always go through `SETVBV` (`$E45C`) so the OS performs the SEI-safe atomic write to the vector pair — without that, the VBI could fire between the lo and hi byte writes and call into the wrong half of the new pointer.

## The two vectors

The Atari OS holds two vectors and walks them in order during every vertical blank:

| Vector | Address | Default | Use for |
|--------|---------|---------|---------|
| **Immediate** (`VVBLKI`) | `$0222` | `SYSVBV` (`$E45F`) | display-list updates, scroll registers — anything that must run before ANTIC starts the next frame |
| **Deferred** (`VVBLKD`) | `$0224` | `XITVBV` (`$E462`) | counters, music, slow state machines — everything else |

After the deferred handler returns, the OS exits via `XITVBV`.

## Methods

```c
static void addImmediate(pointer fn);    // install fn at VVBLKI
static void addDeferred(pointer fn);     // install fn at VVBLKD

static void removeImmediate(void);       // restore VVBLKI to SYSVBV
static void removeDeferred(void);        // restore VVBLKD to XITVBV
```

## The `:vbi` annotation is required

Your handler **must** be declared with the `:vbi` function annotation. That tells the codegen to:

- save A / X / Y in the prologue,
- restore A / X / Y in the epilogue, and
- replace the usual `RTS` with a `JMP XITVBV` so the OS finishes the interrupt cleanly.

A plain function would corrupt registers across the interrupted code and either lock the machine up or skip the rest of the OS chain.

```c
volatile u8@ COLBK = @$D01A;        // background colour register

void rainbow(void) :vbi
{
    @COLBK = @COLBK + 1;             // change border colour every frame
}

void main(void)
{
    Vbi.addDeferred(&rainbow);
    while (1) { /* spin */ }
}
```

To remove the handler later, call the matching `removeImmediate()` / `removeDeferred()`.

## Choosing immediate vs deferred

- **Immediate** runs **before** the OS does its per-frame housekeeping (RTCLOK, key auto-repeat, attract mode). It runs **before** ANTIC starts the next frame, so it's the right place to update display-list pointers, scroll registers, or anything else that has to be in place by the time the next frame begins.
- **Deferred** runs **after** the OS housekeeping, just before `XITVBV`. It's the right place for counters, music players, AI ticks — work that just needs to happen 50/60 times a second, not work that's bound to a specific point in the display cycle.

If you don't have a clear reason to use immediate, prefer deferred — your handler isn't in the critical path of the OS's own vector chasing.

## Banking

On `xt` and `xe` (banked targets), `:vbi` and `:irq` handlers are placed in **main RAM** at a stable address — the OS dispatcher `JMP`s through the vector slot directly, with no opportunity for the bank-switch trampoline to swap the right page in. The codegen handles this automatically; you don't need to annotate the function `:main`.
