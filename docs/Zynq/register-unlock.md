# XT register unlock

A mechanism to make the XT hardware-register extensions **opt-in**, so a
machine boots and behaves as a bone-stock Atari until something deliberately
unlocks the XT features. Locked is the default and the post-reset state.

## Why

Two problems, one fix:

1. **Stock compatibility.** The XT extensions overlay address space that real
   software touches — ANTIC mirrors (`$D420-$D47F`, e.g. *Bounty Bob Strikes
   Back* reads `$D47B`), the CCTL cartridge window (`$D5xx`), open-bus regions.
   With the extensions always-on, a stock title can collide with an XT register.
2. **Orchestration.** The A9 desktop is the thing that decides "we're now
   running a stock cartridge" vs "we're an XT app." It needs to switch the
   machine's personality.

The fix: a small set of **enable bits**, one per feature group. Locked → the
address decodes exactly like stock silicon (mirrors restored, open bus).
Unlocked → the XT register is live.

## Key structural fact: gate the *native* decode only

The A9 reaches the blitter / kbd-inject / etc. through the **GP0 bridge**, a
path that never goes through the `$D4xx`/`$D5xx` decode being gated. So:

- **The unlock only suppresses the 6502/ANTIC-side decode.** It changes *what
  the 6502 sees*.
- **The A9/bridge path is always live**, regardless of lock state. The A9 can
  present a stock machine to the 6502 *and still drive it from outside*
  (inject keystrokes, pulse reset, even run the blitter).

That last point is what makes the launcher flow work (below).

## The control registers

One 8-bit unlock register, **two write ports**, with the A9 as the authority.

### Bit layout (`xt_unlock[7:0]`)

| Bit | Group | When locked (0) | When unlocked (1) |
|-----|-------|-----------------|-------------------|
| 0 | `ANTIC_CHIPLET` (`$D480-$D49F`: MODE, palette, DRAW, OS-ROM loader) | mirror of `$D400-$D40F` | XT chiplet registers |
| 1 | `SPRITE` (sprite engine page(s)) | mirror | sprite descriptor/control regs |
| 2 | `BLITTER` (native-side `$D4Bx/$D4Cx/…`) | mirror | blitter regs *(native bus only; A9/bridge unaffected)* |
| 3 | `BANK` (`$D5C0/$D5C1` code/data bank select) | open bus / cart | XT banking |
| 4 | `GEM` (`$D5D0-$D5D4` service doorbell) | open bus / cart | GEM doorbell |
| 5 | reserved (kbd? — see Open points) | — | — |
| 6 | reserved | — | — |
| 7 | `NATIVE_UNLOCK_EN` — **A9-only**: 1 = honor the 6502's `$D5CF` writes | 6502 cannot change the unlock | 6502 self-unlock permitted |

Reset → `0x00` (everything locked = stock, and the 6502 can't unlock itself).

### Write port A — A9 (primary)

A **bridge-intercepted control register**, exactly like the existing `gp0_ctrl`
(offset `0x1C`): the A9 writes a chosen GP0 byte offset, the bridge latches it
into the PL flop and exposes `xt_unlock` to `fpga_xt_top`. Not in the cartridge
range — no stock cartridge can reach it. **This is the launcher's path and the
authority.** (Exact offset TBD in implementation — a free intercept offset
distinct from `0x1C`.)

### Write port B — 6502 (secondary, gated)

A native write to **`$D5CF`** sets bits `[6:0]` — **but only while
`NATIVE_UNLOCK_EN` (bit 7, A9-set) is 1**. This closes the hole below.

### The hole: `$D5CF` is in the cartridge window

`$D5xx` is CCTL — stock cartridges bank-switch there (Bounty Bob uses `$D5xx`!).
So the very register that controls stock-vs-XT lives in space a stock cart
writes. Without protection, a stray cart write to `$D5CF` could flip the machine
out of stock mode mid-game.

**Resolution (chosen):** the 6502's `$D5CF` write is honored **only when the A9
has set `NATIVE_UNLOCK_EN`**. By default / after reset that bit is 0, so a stock
cart's `$D5xx` traffic can never touch the unlock state. The A9 grants
6502-self-unlock only when it is deliberately running XT-aware native software.
The A9's own write port (the bridge) is outside the cart range and always
authoritative.

*(Alternative considered: a magic key/value on `$D5CF` (e.g. arm with `$D5CE`=key
then write the mask). Rejected as weaker — a determined-enough cart pattern
could still hit it, and the A9-gate is simpler and strictly safer.)*

## What each bit gates, precisely

For every gated region the rule is: **the XT decode fires iff the group is
unlocked; otherwise the address falls through to the stock decode.**

- `ANTIC_CHIPLET`: gate the `$D480-$D49F` chiplet register decode. Locked →
  `$D480-$D49F` mirrors `$D400-$D40F` (stock ANTIC mirror).
- `SPRITE`: gate `sprite_reg_we`. Locked → the sprite page(s) mirror ANTIC (if
  in mirror space, e.g. a `$D46x/$D47x` home) or read 0.
- `BLITTER`: gate the blitter's **native-bus** register decode only. Locked →
  `$D4Bx/$D4Cx` mirror ANTIC. The bridge/A9 path is never gated.
- `BANK`: gate `$D5C0/$D5C1`. Locked → open bus, so a stock cart's `$D5xx`
  bank-switching is undisturbed.
- `GEM`: gate `$D5D0-$D5D4`. Locked → open bus.

### The core mechanism: a mirror-conditional `$D4xx` decode

Real ANTIC mirrors `$D400-$D40F` across the whole `$D4xx` page. Today the XT
chiplet-ext breaks that mirror **unconditionally** for `$D480-$D4FF`. The change
is to make every XT claim on `$D4xx` **conditional on its unlock bit**:

```
for an address A in $D410..$D4FF:
    claimed = (A in ANTIC_CHIPLET region  && unlock[ANTIC_CHIPLET])
            | (A in SPRITE region         && unlock[SPRITE])
            | (A in BLITTER native region && unlock[BLITTER])
            | ...
    if claimed:  XT register responds
    else:        stock ANTIC mirror responds   // $D400-$D40F mirrored
```

`$D400-$D40F` (canonical ANTIC) always decodes, unaffected. `$D5xx` is simpler
(no mirror) — locked groups just present open bus.

## Reset semantics

**Reset → `xt_unlock = 0` (fully locked / stock).** Both write ports reset to 0.
Consequence: every 6502 cold/warm start lands in stock mode; the A9 (or, once
permitted, XT-aware native code) re-asserts the bits it wants. A wedged XT app +
reset can never leave the 6502 staring at half-enabled XT registers.

Which reset clears it: the **system/PL reset**. Whether a *6502-only* reset (the
SALLY reset the launcher pulses) also clears it is an Open point — see below.

## Worked example: A9 launches Bounty Bob (stock cart, uses `$D47B` + `$D5xx`)

1. A9 writes the unlock reg (bridge) = `0x00` → **all groups locked**, and
   `NATIVE_UNLOCK_EN`=0.
2. Now the 6502 sees stock silicon: `$D47B` is the ANTIC mirror (Bounty Bob
   happy), `$D5xx` is pure CCTL so Bounty Bob's own cartridge bank-switching
   there is undisturbed, no sprite/chiplet/GEM decode shadows anything.
3. A9 mounts Bounty Bob in D1: (disk emulation), **injects Option-hold via
   `$D4CF` (bridge — not gated)**, **pulses 6502 reset (bridge — not gated)**.
4. 6502 cold-boots a stock-looking machine and runs the cart. ✔

Everything the A9 needs in steps 3-4 rides the bridge, so locking the 6502's
view doesn't disarm the A9.

## Worked example: XT-native app

1. A9 (bridge) sets `unlock = {NATIVE_UNLOCK_EN, GEM, BANK, SPRITE, BLITTER,
   ANTIC_CHIPLET}` for the groups the app needs.
2. A9 loads + resets the 6502 into the XT app. If the app self-manages, it may
   adjust bits via `$D5CF` (now honored, since `NATIVE_UNLOCK_EN`=1).
3. The XT registers are live for the 6502; the A9 desktop GEM/blitter also keep
   working over the bridge throughout.

## Open points to settle before RTL

1. **6502-only reset vs the unlock.** If the launcher's SALLY reset clears the
   unlock, the A9 must re-assert XT bits *after* the reset for an XT app (fine,
   and arguably cleaner). If it doesn't clear, a stock-cart reset relies on the
   A9 having locked first. Leaning: **PL/system reset clears; 6502-only reset
   does NOT** — so the A9 owns the policy across a guest reset. Confirm.
2. **`BANK` boot order.** The XTC runtime needs banking; reset → BANK locked. So
   the XTC boot ROM must live in flat bank 0 and the A9 (or that ROM) unlocks
   `BANK` before banked code runs. This is *why* BANK must be gateable (so stock
   carts using `$D5xx` aren't disturbed) — but the XTC boot sequence has to
   account for starting locked.
3. **Is `kbd` a group at all?** Keyboard *injection* is A9→6502 over the bridge
   (`$D4CF`), never a native register the 6502 reads — so it needs no gating.
   Reserve bit 5 only if a *native-visible* keyboard register appears later.
4. **A9 control offset.** Pick the bridge intercept offset for write port A
   (distinct from `gp0_ctrl`'s `0x1C`); and decide if `xt_unlock` is read-backable
   over the bridge (recommended, for the A9 to verify state).
5. **Simultaneous A9 + 6502 write.** Both land at `clk_sys` after CDC. Give the
   A9 write priority on a same-cycle tie (it's the authority).

## Cost

- Unlock register + the two write ports (bridge intercept ~`gp0_ctrl` clone;
  `$D5CF` native decode gated by `NATIVE_UNLOCK_EN`): small.
- Per-group decode gating: ~1 line each, spread across `fpga_xt_top` /
  `antic_regs` / the blitter native decode, plus routing `xt_unlock` to each.
- The mirror-conditional `$D4xx` decode: the one piece needing care.
- Bitstream + tests (stock mirror behaviour locked; XT registers unlocked;
  `$D5CF` ignored unless `NATIVE_UNLOCK_EN`).

A focused ~150-250-line change across the decode modules, low datapath risk.
