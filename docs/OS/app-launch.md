# Launching 8-bit (XL) apps from the desktop

> **Proposed design — not built.** How the XTOS desktop launches Atari 8-bit
> programs onto the fabric 6502, and how they present (classic full/windowed vs
> GEM-native).

## Session model

Launching = the A9 spins up an **XL session**: cold-reset the fabric 6502, get the
real XL OS to a known state, get the program in, present it. The desktop never
leaves — it is its own compositor surface, and the XL realm is another surface that
comes to the front. Closing returns focus to the desktop. The legacy Atari is a
**hosted app on the XTOS desktop**, not a mode you reboot into.

**Cold-boot per launch** for now (classic *and* GEM) — a fresh machine each time,
no leftover state; milliseconds at turbo. Once the multitasking kernel lands this
becomes **"launch task"** (spawn a 6502 task rather than cold-boot the whole
machine), which is also what lets several GEM apps coexist.

## App classes (by XEX header)

| Header | Class | Presents as |
|--------|-------|-------------|
| `$FFFF` (or ATR / CAR) | **Classic** | the emulator surface — scaled 1–5 / "fullscreen" |
| `$FFFE` | **GEM app** | a GEM **window on the desktop**; emulator surface hidden (debug-openable) |

`$FFFE` is a safe marker: a valid XEX's *first* header must be `$FFFF`, so a real
Atari/DOS just rejects it — it is an XTOS-only flag the launcher reads.

## Launch decision tree

1. Read header → classic vs GEM.
2. Look up the app's prefs in the registry (below), else defaults.
3. Build the medium and **cold-boot** the 6502:
   - **ATR/XFD** → A9 serves it as D1:.
   - **XEX** → A9 wraps it in a **synthesized boot disk** — a canned 6502
     boot-loader stub in the boot sectors plus the XEX as payload; the stub does the
     segment load and the INIT/RUN-vector dance — and serves that.
   - **CAR/ROM** → map into the cart window (`$8000`/`$A000`) + assert the RD4/RD5
     cart-sense; the OS detects it.
4. **Classic** → foreground the emulator surface at the chosen scale/position, route
   **raw input** to POKEY/PIA/GTIA, chrome-on-mouse + `[Home]` to close.
   **GEM** → leave the emulator surface hidden; the app opens its GEM window; AES
   handles input and close.

## Disk serving

The **A9 serves virtual disks** — the file is in its VFS, and this keeps the STM's
5 MHz SPI free for HID + *physical* SIO peripherals (STM = real SIO drives, A9 =
virtual). Crucially the A9 never drives the 6502's PC: it cold-boots and serves
sectors, and the XL OS does the load itself.

## SIO coexistence — virtual disks vs a real D1: on the port

**One mount table, arbitrated by SIO device ID.** On a real SIO bus arbitration
*is* the device ID — every command frame names its target (D1:=$31 … D8:=$38) and
whoever owns that ID answers. So the OS keeps a single device table, visible to
the desktop: each slot is **virtual** (an A9 VFS file — an ATR, a synthesized XEX
boot disk), **physical** (pass through to the real bus), or **empty**. Every
routing decision is a per-slot lookup; there is no other mechanism.

**Explicit action wins.** Launching an ATR mounts it at D1: *for that session* —
the virtual disk deliberately shadows a physical drive with the same ID, exactly
as inserting media should. Close the session and the mount evaporates; the real
D1: is visible again. Booting the actual floppy is a desktop action too ("boot
from real D1:" = cold-boot with the virtual slot empty). Nothing forces a fight:
launch prefs can mount the virtual disk at D2: instead, leaving a real D1:
bootable — a per-app registry setting, not a special case.

**Two transports behind the same table:**

- **Tier 1 — the SIOV hook (now).** The patched OS image routes `SIOV` through a
  paravirtual stub: DCB → the math-cop mailbox → the A9 serves the sector from
  the VFS. Slots marked *physical* fall through to the **original** OS SIO code,
  which drives POKEY serial — the path the STM terminates. Instant sector loads
  at turbo speed; the classic limitation applies (custom loaders that bang POKEY
  directly bypass any vector patch).
- **Tier 2 — the byte-level interposer (when the STM lands).** The fabric already
  sits between POKEY's byte-level serial engine and the SPI link (`peri_bridge`,
  pins tied off today). When a command frame goes out, the A9 peeks the device
  ID: virtual slot → the A9 answers by injecting response bytes into POKEY's
  receive side and the physical bus never sees the frame; physical/empty → bytes
  flow to the STM untouched. Device-ID-granular, zero bus collisions, and it
  works for custom loaders — the same arbitration model FujiNet uses to live
  alongside real drives. The SIOV hook then survives purely as the per-slot
  fast path, switchable via the same prefs.

The table and per-ID routing are the contract; transports change underneath
without the desktop, the registry schema, or the launch flow changing shape.

## Preferences — one SQLite registry

App/system settings live as a **namespace in the single SQLite database** (the XTOS
registry), *not* a separate store. Keyed by **app identity** (hash / canonical
path) so renames and duplicates do not cross wires. Per-app keys: `scale`,
`fullscreen`, `isGem`, window position, plus arbitrary properties a GEM-aware app
stores for itself.

- First launch → no prefs → sensible defaults (classic → max-scale fullscreen;
  GEM → default window size/pos), then persisted.
- The DB lives on the **persistent store (NAND)**, separate from the **SD** boot
  medium — so settings **survive an OS field-upgrade** (swap the SD, keep your
  prefs). Stale prefs for apps removed on an SD swap are a lazy-GC item, not a
  blocker.

## Display & chrome (classic apps)

The emulator surface already runs at **scale 1–5**; "fullscreen" is just
`scale = 5` + pillarbox borders (the integer-scale slack). That unused border is
where the **chrome** lives: on **mouse-move**, draw a border + **close-button**
around the used area, auto-hiding when the mouse idles (fullscreen-player style).
`[Home]` — intercepted by the A9 **before** POKEY — is the keyboard equivalent.
Both end the session. Windowed (scale < 5) uses the same chrome at the smaller
rectangle.

## GEM apps (the desktop-native path)

A `$FFFE` app is just **another GEM client** in the GEM-service architecture: the
6502 calls VDI/AES through **thin 6502 bindings**, marshalled over the
doorbell/param-block ABI to the **A9 GEM service**, which draws the window onto the
**desktop** surface — peer to desktop-native and (later) m68k GEM apps. So:

- **Input** is **AES events** (clicks in its window, menu picks, keys) — normal
  window focus, not raw-Atari input.
- **Exit** is the window's **close box** (AES delivers the close event, the app
  exits) — not `[Home]`/chrome (that is the classic path).
- The 6502's own ANTIC screen still renders underneath as the hidden,
  debug-openable surface.
- The **load path is identical** to a classic XEX (a GEM app is a 6502 binary that
  links the GEM bindings); only the *presentation* differs.

## Evolution

- **Now:** cold-boot per launch, one XL session, A9-served disk.
- **With multitasking:** "launch task" instead of cold-boot; multiple 6502 tasks →
  multiple GEM windows from the 6502, classic + GEM coexisting.

## v1 implementation (BUILT 2026-07-17 — pending the bitstream + board)

The pieces, as landed:

- **RTL (one bitstream):** `CTRL SALLYRST` (GP0 `0x43C0_031C` bit 0) holds/releases the
  6502 core + its clock gen — the A9's cold-boot control the design lacked. `sally_mem`
  and the ROM-loader keep the plain reset so uploads work WHILE the core is held.
  (Bundled the clk_sally overlay-read wait-state opener in the same build — see the
  timing study.)
- **`SYS_xl_boot(path, drive)`** (`0x606`, `loader/test/freertos/xl_boot.c`): holds
  SALLYRST, builds the 64 KB OS image from `/OS/roms/atari-{xl,basic}.rom`, PATCHES it
  (SIOV's JMP → the paravirtual SIO stub; RESET vector → a coldstart-forcing stub that
  clears PUPBT so a warm RAM still cold-boots), uploads `$1000-$FFFF` through the
  `sally_rom_loader` window (which also scrubs RAM), mounts the ATR (whole file in kernel
  memory), releases. `path=NULL` = eject + boot to BASIC.
- **The stubs** (`tools/xl_sio_stub.s`, `xl_reset_stub.s`, assembled with `xa`, bytes
  embedded in `xl_boot.c`): position-independent, each ending in a `JMP` whose target the
  kernel fixes up to the original vector. The SIO stub writes the DCB into the mailbox
  **through the `$D5CD`/`$D5CE` register port** — `$D5CD` selects a byte, `$D5CE` is that
  byte, and every access post-increments the index — rings the doorbell, and either reads
  the payload back through the same port (boot sectors, DBUF < $1000) or lets the A9
  deliver straight to BRAM (DBUF ≥ $1000). **It maps nothing.** Earlier revisions reached
  the mailbox through the `$D5C6.0` aperture over `$4000-$5FFF`, which is the guest's own
  RAM, and held that map across the whole A9 round-trip: any interrupt in those
  milliseconds ran with `$4000-$5FFF` replaced. See `hdl/xt_sio_mbox.sv`.
- **Sector service** rides the **math-cop worker** (`xl_sio_service`, dispatched from
  `mc_run_chunk` on the `MC_OP_SIO` opcode): decode DCB → the mount table → serve from the
  RAM-resident ATR. Mounts change only while the 6502 is held in reset, so no locks.
- **Desktop:** `desk_launch` on an 8-bit **disk** calls `SYS_xl_boot(full, 1)` then opens
  the framed plane window; the close box / `WM_CLOSED` ejects (`SYS_xl_boot(NULL,0)`).

**v1 boots ATRs only.** Documented gaps, all software follow-ups: XEX (needs the boot-disk
synth), CAR/cart (no cart-window RTL), and media write-back to the SD (writes hit the RAM
image only). The old "a write FROM a `$4000-$5FFF` buffer" gap is gone with the aperture —
no address is special to the stub any more.
