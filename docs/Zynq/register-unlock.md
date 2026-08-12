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
| 6-7 | reserved | — | — |

Reset → `0x00` (everything locked = stock).

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

### Write port B — 6502 (secondary)

A native read/write at **`$D1DF`** (PBI window) — XT-aware native software
self-unlocks the groups it needs, and can read back the current state. Decoded
**unconditionally** by the XT (it's the master switch, always reachable, no lock
bit of its own). No permission gate — the location is the protection (below).

### Why `$D1DF` — the location is the protection

The earlier candidate, `$D5CF`, sits in the **CCTL cartridge window** — the very
space stock cartridges bank-switch through (Bounty Bob writes `$D5xx`). Putting
the master stock-vs-XT switch *inside the space it governs* is asking for
trouble: a stray cart write could flip the machine out of stock mode mid-game,
and the register would be self-referential with the `BANK`/`GEM` decodes around it.

`$D1DF` is in the **PBI window** (`$D100-$D1FF`), in the documented-free gap
between the 1090 XL Amy block (`$D1D1-$D1DD`) and the MIO ACIA (`$D1E0+`):

- stock **cartridges** never touch PBI space;
- the OS **PBI scan** probes `$D1FF` / the `$D800` signature — it never *writes*
  `$D1DF`;
- no real **peripheral** claims the byte (documented free).

So nothing stock writes `$D1DF`, and the stock-vs-XT split falls out naturally
from *whether software writes it at all* — which is why an earlier
`NATIVE_UNLOCK_EN` permission bit was dropped as redundant complexity. The A9
still owns the policy through its bridge port (it sets the lock state before
launching a guest); it simply can't *forbid* an XT-aware 6502 program from
self-unlocking, which isn't a requirement (the 6502 is the machine).

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

1. A9 writes the unlock reg (bridge) = `0x00` → **all groups locked**. (Bounty
   Bob never writes `$D1DF`, so it can't un-lock anything.)
2. Now the 6502 sees stock silicon: `$D47B` is the ANTIC mirror (Bounty Bob
   happy), `$D5xx` is pure CCTL so Bounty Bob's own cartridge bank-switching
   there is undisturbed, no sprite/chiplet/GEM decode shadows anything.
3. A9 mounts Bounty Bob in D1: (disk emulation), **injects Option-hold via
   `$D4CF` (bridge — not gated)**, **pulses 6502 reset (bridge — not gated)**.
4. 6502 cold-boots a stock-looking machine and runs the cart. ✔

Everything the A9 needs in steps 3-4 rides the bridge, so locking the 6502's
view doesn't disarm the A9.

## Worked example: XT-native app

1. A9 (bridge) sets `unlock = {GEM, BANK, SPRITE, BLITTER, ANTIC_CHIPLET}` for
   the groups the app needs.
2. A9 loads + resets the 6502 into the XT app. If the app self-manages, it may
   adjust bits via `$D1DF` itself.
3. The XT registers are live for the 6502; the A9 desktop GEM/blitter also keep
   working over the bridge throughout.

## Decisions (settled)

1. **Reset semantics — SETTLED.** PL/system reset clears; a 6502-only reset does
   NOT (the A9 owns the policy across a guest reset). See *Reset semantics*.
2. **`BANK` boot order — SETTLED.** The A9 unlocks `BANK` **pre-launch** (before
   it boots the XCC environment), since the XCC runtime needs banking but reset
   leaves it locked. Stock carts (which never expect XT banking) run with `BANK`
   locked, so their `$D5xx` cart-switching is undisturbed.
3. **`KBD` is a group — SETTLED.** Kept as a defensive mask (bit 5): even though
   injection rides the bridge, the kbd region's *native* decode is gated so a
   stock program hitting that mirror address can't trip XT keyboard logic.
4. **`$D1DF` location — SETTLED.** The 6502-side switch moved out of the CCTL
   window into the free PBI gap (`$D1DF`), clear of the space it governs.
5. **`NATIVE_UNLOCK_EN` dropped — SETTLED.** It existed only to plug the
   `$D5CF`-in-cart-window hole; with the switch at `$D1DF` (which nothing stock
   writes) the gate is redundant, so `$D1DF` is always honored. The A9 still
   owns policy via the bridge; it just doesn't *forbid* 6502 self-unlock.

## Settled in implementation

1. **A9 control offset — `0x20`.** The bridge intercepts GP0 byte-offset `0x20`
   (maps to `$D4D0` on the native bus — blitter ignores it, sprites are
   native-only, so it's free) as the unlock write port, and returns the
   effective `xt_unlock` on a read of the same offset so the A9 can verify
   state (incl. any 6502 self-unlock). Distinct from `gp0_ctrl`'s `0x1C`.
2. **Simultaneous A9 + 6502 write — A9 wins.** Both land at `clk_sys`; the
   unlock register's update is `if (a9_we) … else if (d1df_we) …`, so the A9
   (authority) takes a same-cycle tie.
3. **`$D1DF` reaches the core via the existing hwreg CDC.** `sally_mem`'s
   `is_hwreg_page` already forwards the whole `$D000-$D7FF` I/O page, so a native
   `$D1DF` write appears on the post-CDC bus in `fpga_xt_top` — decoded there
   directly, no `antic_top`/PBI-output change.

## Remaining caveat

- **`$D1DF` in a PBI-equipped machine.** The XT decodes `$D1DF`
  unconditionally; if a real PBI device ever claims that exact byte it would be
  shadowed. Documented-free today; revisit only if a PBI device lands there.

## Implementation map (where each gate lives)

- **Unlock register + `$D1DF` port:** `fpga_xt_top.sv` (`xt_unlock`, two write
  ports; bits named `UNLK_*`).
- **A9 write port + read-back:** `axi_blitter_bridge.sv` (offset `0x20` →
  `xt_unlock_we` strobe; `xt_unlock_state` fed back for the read).
- **ANTIC_CHIPLET:** `antic_regs.sv` (`is_chiplet`/`is_canon_r` gated by
  `unlock_antic` — the mirror-conditional decode) + `antic_top.sv` gates the
  `draw_regs` write-enable.
- **SPRITE / BLITTER (+ `$D4CA` turbo):** `fpga_xt_top.sv` (`sprite_reg_we`,
  `bl_we_mux` native term).
- **BANK:** `sally_mem.sv` (`unlock_bank` gates the `$D5C0/$D5C1` write, the
  read-shadow, and the hwreg-forward exclusion).
- **A9 helper:** `xt_unlock_set()` / `xt_unlock_get()` in `vitis/xtos/src/xt_blitter.{h,c}`.
- **Sim:** `make unlock` (`sim/tb_unlock.sv`) verifies the mirror-conditional
  chiplet decode both ways; the boot/sally/blitter-bridge sims regress green.

## Cost

- Unlock register + the two write ports (bridge intercept ~`gp0_ctrl` clone;
  `$D1DF` native read/write): small.
- Per-group decode gating: ~1 line each, spread across `fpga_xt_top` /
  `antic_regs` / the blitter native decode, plus routing `xt_unlock` to each.
- The mirror-conditional `$D4xx` decode: the one piece needing care.
- Bitstream + tests (stock mirror behaviour locked; XT registers unlocked;
  `$D1DF` round-trips).

A focused ~150-250-line change across the decode modules, low datapath risk.
