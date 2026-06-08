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
| 5 | `KBD` (keyboard-inject region's native decode) | mirror | XT decode (see note) |
| 6 | reserved | — | — |
| 7 | `NATIVE_UNLOCK_EN` — **A9-only**: 1 = honor the 6502's `$D1DF` writes | 6502 cannot change the unlock | 6502 self-unlock permitted |

Reset → `0x00` (everything locked = stock, and the 6502 can't unlock itself).

`KBD` note: keyboard *injection* is A9→6502 over the bridge and is never gated
(see below). The `KBD` bit exists defensively — it masks the kbd region's
*native-bus* decode so a stock program hitting that ANTIC-mirror address can't
trip any XT keyboard logic; locked → the address is the plain ANTIC mirror.

### Write port A — A9 (primary)

A **bridge-intercepted control register**, exactly like the existing `gp0_ctrl`
(offset `0x1C`): the A9 writes a chosen GP0 byte offset, the bridge latches it
into the PL flop and exposes `xt_unlock` to `fpga_xt_top`. Not in the cartridge
range — no stock cartridge can reach it. **This is the launcher's path and the
authority.** (Exact offset TBD in implementation — a free intercept offset
distinct from `0x1C`.)

### Write port B — 6502 (secondary, gated)

A native write to **`$D1DF`** (PBI window) sets bits `[6:0]` — **but only while
`NATIVE_UNLOCK_EN` (bit 7, A9-set) is 1**. Readable too (the 6502 can check the
current unlock state). `$D1DF` is decoded **unconditionally** by the XT — it is
the master switch and must always be reachable, so it has no lock bit of its own.

### Why `$D1DF`, and the hole it dodges

The earlier candidate, `$D5CF`, sits in the **CCTL cartridge window** — the very
space stock cartridges bank-switch through (Bounty Bob writes `$D5xx`). Putting
the master stock-vs-XT switch *inside the space it governs* is asking for
trouble: a stray cart write could flip the machine out of stock mode mid-game,
and the register would be self-referential with the `BANK`/`GEM` decodes around it.

`$D1DF` is in the **PBI window** (`$D100-$D1FF`), in the documented-free gap
between the 1090 XL Amy block (`$D1D1-$D1DD`) and the MIO ACIA (`$D1E0+`). Stock
*cartridges* never touch PBI space, and a bare machine leaves it open bus — so
the master switch lives well clear of everything it controls.

**Defense in depth:** even there, the `$D1DF` write is gated by
`NATIVE_UNLOCK_EN` (A9-set, resets to 0). So a stock PBI driver poking the
region can't change the unlock state unless the A9 has explicitly opened that
door. The A9's own write port (the GP0 bridge) is outside all Atari I/O space
and is always authoritative — it can lock the machine down (incl. clearing
`NATIVE_UNLOCK_EN`) for a stock session.

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
- `KBD`: gate the kbd region's native-bus decode. Locked → the address is the
  plain ANTIC mirror, so a stock program hitting that mirror can't reach any XT
  keyboard logic. (A9 bridge injection is unaffected — always live.)

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

**The PL/system reset clears `xt_unlock` to 0 (fully locked / stock).** A
**6502-only reset** (the SALLY reset the launcher pulses to boot a guest) does
**NOT** clear it — so the A9 owns the unlock policy *across* a guest reset.
The A9 sets the desired lock state, then pulses the 6502 reset; the guest comes
up against exactly the personality the A9 chose, and a wedged XT app + 6502
reset can't leave the 6502 staring at half-enabled XT registers. Only a full
power-on / PL reconfigure returns to the all-locked default.

## Worked example: A9 launches Bounty Bob (stock cart, uses `$D47B` + `$D5xx`)

1. A9 writes the unlock reg (bridge) = `0x00` → **all groups locked**, and
   `NATIVE_UNLOCK_EN`=0 (so the guest can't even reach the `$D1DF` switch).
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
   adjust bits via `$D1DF` (now honored, since `NATIVE_UNLOCK_EN`=1).
3. The XT registers are live for the 6502; the A9 desktop GEM/blitter also keep
   working over the bridge throughout.

## Decisions (settled)

1. **Reset semantics — SETTLED.** PL/system reset clears; a 6502-only reset does
   NOT (the A9 owns the policy across a guest reset). See *Reset semantics*.
2. **`BANK` boot order — SETTLED.** The A9 unlocks `BANK` **pre-launch** (before
   it boots the XTC environment), since the XTC runtime needs banking but reset
   leaves it locked. Stock carts (which never expect XT banking) run with `BANK`
   locked, so their `$D5xx` cart-switching is undisturbed.
3. **`KBD` is a group — SETTLED.** Kept as a defensive mask (bit 5): even though
   injection rides the bridge, the kbd region's *native* decode is gated so a
   stock program hitting that mirror address can't trip XT keyboard logic.
4. **`$D1DF` location — SETTLED.** The 6502-side switch moved out of the CCTL
   window into the free PBI gap (`$D1DF`), clear of the space it governs.

## Open points to settle before RTL

1. **A9 control offset.** Pick the bridge intercept offset for write port A
   (distinct from `gp0_ctrl`'s `0x1C`); make `xt_unlock` read-backable over the
   bridge so the A9 can verify state.
2. **Simultaneous A9 + 6502 write.** Both land at `clk_sys` after CDC. Give the
   A9 write priority on a same-cycle tie (it's the authority).
3. **`$D1DF` decode in a PBI-equipped machine.** The XT decodes `$D1DF`
   unconditionally; if a real PBI device ever claims that exact byte it would be
   shadowed. Documented-free today; revisit only if a PBI device lands there.

## Cost

- Unlock register + the two write ports (bridge intercept ~`gp0_ctrl` clone;
  `$D1DF` native decode gated by `NATIVE_UNLOCK_EN`): small.
- Per-group decode gating: ~1 line each, spread across `fpga_xt_top` /
  `antic_regs` / the blitter native decode, plus routing `xt_unlock` to each.
- The mirror-conditional `$D4xx` decode: the one piece needing care.
- Bitstream + tests (stock mirror behaviour locked; XT registers unlocked;
  `$D1DF` ignored unless `NATIVE_UNLOCK_EN`).

A focused ~150-250-line change across the decode modules, low datapath risk.
