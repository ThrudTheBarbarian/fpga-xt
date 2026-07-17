# gemd — phase 1 implementation plan

Spec: `Rocks/doc/RESPONSIBILITIES.md` (§3–§11 = the design, §12 = capacity/extent, §14 = what
phase 1 is and is not). This file is the *implementation* plan and the running status.

## Status

| | |
|---|---|
| **kernel prerequisites (§14)** | **DONE, board-verified.** variable-size shm; `sys_shm_unmap` |
| **M0 — the channel** | **DONE, board-verified** (commit `3c6f5b4`) |
| **M1 — gemd skeleton + one client** | **DONE, board-verified** (see below) |
| **M2 — window list moves server-side** | **DONE, board-verified** |
| **M3 — desktop becomes a client** | **DONE, board-verified** (see below) |
| **no single-process fallback on XTOS** | **DONE, board-verified** (see below) |
| **M4 — input: routing, focus, live chrome** | **DONE, board-verified** (see below) |
| M4b — the menu strip (§10), grabs, liveness | **DONE, board-verified** — per-app strip surface, input grab, §9 revoke |
| M5 — resize: client-driven (`wind_set`), scroll/content size | **DONE, board-verified.** geometry-as-request (WF_CURRXYWH/Fit), live resize, both-axis scroll + content-size, wheel, the resize discipline, horizontal scrollbars, and the chrome rework (info bar to top, proximity resize + cursor affordance). Optional follow-up only: theme-able hover-resize brackets. |
| M6 — the XL plane (generic: ANY plane) | **DONE, board-verified (2026-07-17)** — `WIND_PLANE` bind + `SYS_plane_window` + the Route-A alpha hole; see below |
| M7 — **the gate** + **the engine composite** | **CODE COMPLETE (2026-07-17); gate + engine proven on the board** (fbgrab fault-killed; blittest full matrix on cached CONTIG), visual/perf pass pending — see below |

## M0 (done): services + poll — block 0x500

XTOS had **no rendezvous**. Pipes need shared ancestry; gemd is the parent of neither the
boot-script desktop nor an ssh-launched app. Sockets are lwIP-only. There was no `select`/`poll`.

```
sys_svc_register(name) -> listen fd    sys_svc_connect(name) -> channel fd
sys_svc_accept(lfd)    -> channel fd   sys_poll(fds, n, ms)
```
A channel is bidirectional (two pipes, one fd). Peer death = EOF. **`SIGCHLD` only reaches the
PARENT — do not build reaping on it (§9 says to; §9 is wrong here). Use channel EOF.**

`poll` also removed the need for kernel-side input injection, so **the kernel knows nothing
about window servers** (§2 satisfied structurally).

## M1 (done): gemd skeleton + one client — board-verified

`gem/gemd/{server,surface,composite}.c` + `gem/gemclient.c` in libGEM.so; `progs/gemd.c` is
thin. gemd registers `"gem"`, owns `sys_fb_info`, clears the plane to its fallback colour,
and runs ONE `poll()` over the listen fd + every client channel. `gemtext` is the first
client and touches no framebuffer.

**Observed on the board** (1920x1080 plane, stride 2048):

| | |
|---|---|
| window appears | `wind_create` 600x180 -> surf 0, capacity 640x192; text composited from the backing store |
| **stride rule proven, not assumed** | 600 is deliberately NOT a multiple of the 64px quantum, so **stride (640) != extent width (600)**. Plane probes: white to x=799, fallback colour at 800 **and at 839** (the capacity edge) — the compositor blits the EXTENT while reading rows at the CAPACITY pitch. A 640-wide window would have passed this test while broken. |
| client killed | window disappears; both probed pixels revert to the fallback colour; **gemd is not the client's parent — death arrives as channel EOF, never SIGCHLD** |
| **no leak, 21 cycles** | the surface id is **always 0** — reclaimed every time. `surf_gen` climbs 1..21 (monotonic by design: it is the stale-damage discriminator). A leaking id would have walked 0,1,2,... and died at 256. |
| **two clients at once** | two windows, surfaces 0 and 1, two pids. Kill one -> gemd drops **only** its window and surface; **the survivor's pixels stay up while its client is asleep** — gemd recomposited from the backing store without asking anyone anything (§3, the promise everything else leans on). A third client then gets the **reclaimed id 0** back while the live one keeps 1: reclamation is *exact*, not merely monotonic. |
| capability | `shmtest`'s child is REFUSED an un-granted `XT_SHM_OWNED` id (before this it could map it and read another process's window), while ordinary shm sharing still works both ways. |

**The surface-capability hole is closed** (`194a966`): `XT_SHM_OWNED` + `SYS_shm_grant`
(owner-only, no re-grant) + `SYS_chan_peer`. gemd grants a surface to the pid the KERNEL
reports for the channel — a pid carried in the client's own message would be a capability
handed out on the say-so of the process being granted it.

> **ssh was down while M1 was being verified — it was a STALE BUILD ARTEFACT, not a loader
> bug and nothing to do with gemd.** A clean kernel rebuild restored it; the M1 gate then ran
> exactly as specified (gemd in one ssh session, `gemtext` in a separate one). Post-mortem, and
> the one real defect it uncovered (the loader reports a nested dependency's missing symbol as
> if it were the object's own): `docs/bugs/dropbear-svr-opts-undefined.md`.

## M2 (done): the window list, the z-order and the chrome move server-side — board-verified

**gemd does not keep a window list beside the AES's — gemd IS the process where
`gem/aes/window.c` runs, in server mode.** So z-order, geometry, the themed frame, the title
bar, the closer/mover/sizer and `wind_redraw_area`'s compositing are the AES's own code,
unchanged, and a client's `wind_create` is a message that lands on the very function it used to
call directly. That is what makes §5 hold: *the signatures did not move, only their bodies.*

**One line in `draw_one` is what M2 exists to break.** It called `W->draw()` — the app's content
callback, a function pointer **in another address space**. It now blits the client's backing
store instead (through `gfx_blit`, the VDI's existing backend seam), and falls back to the
callback when there is no surface — which *is* single-process GEM, so the SDL host is untouched.

`gemtext` stops using the raw transport (M1 scaffolding) and becomes an ordinary AES app.

**Observed on the board:** a 600x180 window with `NAME|CLOSER|MOVER|SIZER` comes back with a
**590x144 work area** — gemd took the chrome out of the rect, and the client is never told the
border width or the title height, only how big its drawable is. On the plane: the title bar
(`0x8D8D8D`) and frame (`0xF5F5F5`) are **gemd's** pixels and the content (white) is the
**client's**, interleaving exactly at the work-area boundary. Kill the client → chrome *and*
content vanish and the surface id is reclaimed, by channel EOF. Two clients → two chromed
windows, surfaces 0 and 1.

> `MAXW` was **16 per app**; it is now **64, system-wide**, because the list lives in gemd.
> `gem/gemd/composite.c` is **deleted**: §14 asks for *a* backend seam for the inner blit, and
> the VDI's (`gfx_blit`) is the one phase 2 has to swap anyway. Two seams is worse than one.

## M3 (done): the desktop is an ordinary client — board-verified

Verified on the board, and it is §4's whole claim:

1. gemd + desktop (as a **client**) + gemtext. Chrome is gemd's, content is the client's,
   `work area 590x144` from a 600x180 window.
2. **Kill the desktop → gemtext survives, intact and still composited**, on gemd's fallback
   colour where the wallpaper used to be. An app outlived the desktop.
3. **Restart the desktop → it comes back UNDERNEATH gemtext**, which is the point. It is created
   **last**, so without `W_BOTTOM` meaning *insert at the bottom* — not merely *never topped by a
   click* — a screen-sized window would land on TOP and swallow the session: every app invisible,
   machine apparently dead. `W_BOTTOM`, not `W_ROOT`: a z-order **position**, not a **role**,
   because gemd must not know what a desktop is.

A window with no chrome bits now gets no chrome (work area == full rect), so the desktop is just
a screen-sized, chromeless, bottom-most window. Under gemd it takes no framebuffer, no
back-buffer, no drag overlay, no `sys_input`; with no gemd it drives the plane exactly as before.

> ⚠ *(M3-era note, now superseded: input routing landed in M4 below — the desktop responds.)*

## M4 (done): INPUT — board-verified

**The kernel problem was the same shape as M0's, and got the same answer.** `SYS_input` (0x700)
BLOCKS, so gemd could not wait on input and on its client channels at once. Input is now a
**pollable fd** — `/OS/dev/input` (`loader/test/freertos/input_dev.c`) — and gemd's loop stays
**ONE `poll()`** over { listen fd, client channels, input fd }. No thread per source, no special
case. And **the kernel still knows nothing about window servers** (§2): it publishes events on a
device, and whoever holds the fd reads them. There is deliberately no kernel-side "post input to
the gem service" path — that would put window-server policy in the kernel.

- One decoder task drains the serial GUI lane into a 64-deep queue; `read()` returns whole
  `struct os_event` records (a burst in one syscall). `SYS_input` now pops the **same queue**, so
  there is never a second reader racing the decoder for bytes.
- The producer stays **swappable**: when input arrives from the STM32F411 over SPI, only
  `input_task()` changes. The kernel keeps the HW cursor sprite — free, tear-free pointer motion.

**gemd's poll IS the AES's event source** (`aes_set_events`), and that is what makes the chrome
live without a line of new hit-testing: `wind_handle_click()` — closer, title drag, sizer,
scrollbars — is the AES's own code running in gemd, and its modal loops wait through
`aes_wait_idle`, which lands in gemd's poll. **While a window is being dragged, gemd is still
accepting connections and still compositing other clients' damage.** The loop is modal for the
pointer, not for the server.

`gem/gemd/route.c` adds only what sits around it: hit-test the z-order; focus follows the CLICK
(so a `W_BOTTOM` desktop can be focused and used without ever being topped); click-to-raise
otherwise; forward `EV_KEY`/`EV_BUTTON`/`EV_MOTION` to exactly one client in **window-local**
coordinates; and turn the AES messages that fall out of frame interaction into wire messages for
the window's OWNER (`MSG_CLOSED`, `MSG_MOVED`, `MSG_SIZED`).

**gemd does NOT close a window when the closer is clicked.** It sends `MSG_CLOSED`; the app
decides (it may want to ask "save changes?"). Classic GEM, and the right split.

### Observed on the board (console log, real clicks over the input device)

```
gemd: click 224,320 -> wh=2 CHROME                     <- 1st click on the LOWER window: raise, consumed
gemd: click 224,320 -> wh=2 (client 1) content         <- 2nd click: now topmost -> forwarded
gemtext: click at 19,139 (MY coordinates — I have no idea where I am)
gemd: click 496,160 -> wh=2 CHROME                     <- title bar
gemd: moved wh=2 -> 296,246 600x180                    <- DRAGGED +96,+96. MSG_MOVED, no redraw.
gemd: click 880,416 -> wh=2 CHROME                     <- the sizer grip
gemd: sized wh=2 -> 296,246 680x266
gemd: resize wh=2 work 670x230 -> surf 4 cap 704x256   <- exceeded cap 640x192 -> NEW surface, granted
gemd: click 1600,896 -> wh=1 (client 0) content        <- the desktop: focused, NOT topped (§4(2))
gemd: closer on wh=2 -> MSG_CLOSED (the app decides)   <- gemtext quits itself
```

| | |
|---|---|
| window-local coords | a click at screen 400,256 reaches the client as **195,75** — it is never told where it is |
| `aes_event_win()` | a client cannot deduce WHICH of its windows an event is for (every window's content starts at 0,0), so gemd says so on the wire |
| **W_BOTTOM is never topped** | `wind_handle_click`'s raise path did NOT honour `W_BOTTOM` (only `wind_raise` did) — a click on the desktop would have topped a screen-sized window and swallowed every app. Fixed; verified |
| §12 capacity, live | a resize past the capacity makes a NEW surface and grants it; the client remaps and keeps drawing |
| a dying client | `write to pid 46 failed — it is dying; EOF will clean up`. gemd survives, as §9 requires |

### What M4 does NOT cover (be honest about it)

- ~~**The menu strip (§10)**~~ — **DONE, board-verified (M4b).** A client that calls `menu_bar()`
  gets its OWN strip-sized surface from gemd (`GEM_MENU_BAR` → `MSG_MENU_SURF`, once, mapped for
  the app's life), opens a VDI workstation on it and draws its bar with the same `draw_bar` as
  local mode. gemd composites the MENU OWNER's strip into the reserved top band — the focused app,
  or the desktop (bottom `W_BOTTOM` window) when no app is active. A press in the band is
  `MSG_MENUCLK`; the dropdown is a chromeless WINDOW under an input GRAB, so the classic modal loop
  runs client-side unchanged (its hit math is absolute, the strip origin IS the screen origin).
- ~~**`wind_title` / `wind_info` / `wind_titlebtns`**~~ — **RESOLVED by the declarative title model**
  (`WF_NAME`/`WF_SUBTITLE`/breadcrumbs/`WM_TBUTTON`, §11): all board-proven. The info footer became
  a client content strip (the info bar, now under the titlebar after the chrome rework).
- ~~**Scrollbars**~~ — **DONE (M5), both axes.** `wind_content_size()` puts the extent on the wire;
  gemd draws the bar; the client scrolls its own store.
- **GRABS + LIVENESS (§9)** — `GEM_GRAB{on}` routes all input to the grabber (screen coords);
  while held, input forwarded to a then-silent client for >7 s revokes it (`MSG_GRAB_REVOKED`).
  The menu interaction is the first grab client; the wedged-app-holding-a-grab case is covered.

## M5 (in progress): geometry is a wire request — WF_CURRXYWH joins the model

**A rect is a REQUEST, not an instruction (§9).** `wind_set(WF_CURRXYWH)` in a client puts the
rect on the wire (`GEM_WIND_SET`, w[3..6]) and changes NOTHING locally: gemd clamps it with the
SAME rules as a sizer drag (`WIND_MIN_W/H` — one rule, two doors — plus `clamp_win`), applies it
through the AES's own `wind_set`, and the client learns the outcome the way it learns about a
drag: `MSG_MOVED` with the clamped rect, then `MSG_SIZED` (the §12 surface dance) when the work
area changed. A client that trusted its own request would disagree with the screen every time
gemd said no.

What it carried with it:

- **The Fit button works under gemd** — `br_fit` in both desktops sends the request instead of
  calling `wind_open` + a repaint. That deleted a FULL-PLANE `wind_redraw()` in the SDL twin and
  a wrong-space repaint in the A9 twin (`wind_redraw_area` with SCREEN coords, which client mode
  reads as SURFACE coords — right-looking, wrong-space).
- **`wind_open` on an already-open window is the same request**, both sides. The classic
  "resizes in place" idiom used to re-run the OPEN handshake: a second workstation client-side
  and an ORPHANED surface server-side (overwritten, never dropped).
- **`MSG_MOVED` now precedes `MSG_SIZED` on the sizer path too**: a left-grip drag moves x as it
  resizes, and `MSG_SIZED` carries only the work area — without the rect the client's
  `wind_get(WF_CURRXYWH)` (the Fit button's anchor) drifts from the screen.

**The scroll model is on the wire too** (build-verified; board pending). The scrollbar is a REAL
control: gemd draws it and runs its interaction, and now it can, because:

- `wind_content_size` sends `WF_CONTENTSIZE` (u32s — a listing outgrows 32767px), **only on
  change**: apps report it from inside their draw callback, so an unconditional send is a wire
  message per paint. gemd repaints ONLY what changed — the bar column when the thumb moved, a
  §12 surface resize (`MSG_SIZED`) when the bar appeared/vanished (the column is reserved from
  the work area). A full recomposite here would double the cost of every damage post.
- `wind_set_scroll` is a REQUEST like a rect — but set optimistically on the client with the
  same clamp gemd will apply, so the next paint needs no round trip; gemd answers `MSG_VSLID`
  **only on disagreement**.
- a scroll's consequence (`MSG_VSLID`, from the bar or a clamped request) reaches the client,
  which shifts its own backing store — an internal blit, only the exposed STRIP is rendered —
  and posts those two dirty rects. A full render per thumb notch is exactly the heavyweight
  repaint this message exists to kill.
- **pinned content is the app's**: the AES scrolls the whole view it was told about, so a
  status bar pinned over it just moved — the app repaints it on `WM_VSLID` through
  `wind_redraw_rect` (NEW: one rect, one window, in the content callback's own coordinate
  space — the dirty-rect tool; `wind_redraw_win` for a one-line change renders the whole
  surface and makes gemd recomposite all of it).

**Board-verified (2026-07-14):** Fit, the fuller (below the menu strip), track/arrow/thumb
scrolling with live content, the pinned status bar staying put. Two lessons the board taught:

- **the scroll blit must stop above anything the app PINS over the scroll** — blitting the
  whole surface dragged a stale copy of the status bar up through the list. The app declares
  its non-scrolling bottom strip (`wind_pin_bottom`, client-side model only — no wire change);
- **"dragging does not scroll" was release-only scrolling**, the classic behaviour, not a bug —
  and it reads as broken the moment the machine is fast enough to expect better. The thumb loop
  now posts `WM_VSLID` per motion, and gemd's event wait flushes the message pipe EVERY LAP, so
  what a modal frame loop posts goes out while it is still modal.

**The scroll slivers were a KERNEL bug, and the scroll blit was only the messenger.** After a
live drag the backing store held stale partial-width rows (fbgrab-proven surface-resident; the
host rig `make scrollsim` drives the identical blit+clip pipeline through hundreds of steps and
PASSES). The on-board bisect — two runtime flags, no reboots per toggle — cleared the drawing
(no-blit mode: clean) and then cleared the blit *logic* (explicit word-loop copy: clean), leaving
only newlib's `memcpy`. Which uses NEON — and `configUSE_TASK_FPU_SUPPORT` was **1**: FPU/NEON
context saved ONLY for tasks that opt in, and only the math-cop worker ever did. Every PL0
process preempted mid-`memcpy` resumed with clobbered NEON registers and left the tail of a row
uncopied. Now **2**: every task gets the context (264 B stack each). The corruption class was
latent under every float-touching process — FreeType, printf `%f`, all of it — not just scroll.

**RESIZE is live too** (sizer grips post `WM_SIZED` per motion; the client reflows while the
frame moves), and interaction cost came down the same trail: a pathological 1-column→7-column
widening went **~12 s → ~4 s** with (a) drags acting on the NEWEST pointer position — the modal
loops soak the motion backlog instead of replaying one composite per queued event — and (b) the
per-motion console lines going quiet (three printf over 115200-baud serial = ~15 ms of BLOCKING
UART time per step; user-spotted). What remains per step is the composite+present pair, twice
(the server's frame redraw and the client's damage) — the HW blitter's job.

**Scroll cost, measured on the board (user-timed full-track drag, ~14 serial-lane motions):**
~9 s → ~3 s → ~2.5 s across three fixes. (1) a scroll step repaints only the BAR server-side —
the content cannot change until the client's damage arrives, and the full-window recomposite
per thumb notch was the largest slice; (2) `aes_damage()` lets the content callback CULL: the
VDI clip guarantees correctness, not thrift, and every visible tile used to render its FreeType
label for the clip to discard — both desktops now hand the damage rect to `objc_draw` and skip
text rows / the status bar outside it, and the scroll path posts ONE whole-band damage
(`client_render`, split from `client_paint`); (3) scroll bursts COALESCE client-side — VSLID
carries the absolute offset, so the newest supersedes the backlog (peek + one-slot stash,
nothing dropped or reordered). What remains per step is one composite+present; the HW blitter
taking over gemd's inner blit and present copy is the phase-2 multiplier.

**The wheel is DONE** (board deploy 2026-07-14): `os_event` grew the field, the serial decoder
stopped discarding wheel reports, gemd routes `AES_WHEEL` to `wind_handle_wheel` — a wheel notch
is a scroll step, with the scroll-step rules (bar-only repaint, coalescing).

**The blitter bursts now** (board-verified 2026-07-14): engine COPY **187 → 433 MB/s**
(`/OS/bin/blitbench`; CPU uncached memcpy 121 / fill 203), `blittest` all-green on silicon. The
serial engine already burst 16 beats but serialized read → write → B per segment; the FC engine
(BLOCK_BLIT, raster-op SRC, 8B-aligned rows both sides — every `/dev/blitter` COPY) overlaps
them: ping-pong buffers, two ARs in flight, counted B responses, and 4KB clamps on BOTH sides
(the serial path never clamped; no HW test had ever handed it a crossing rect). The tb gained a
queued-AR slave with read latency, a THROUGHPUT GATE (1.90 cy/beat measured; >2200 cycles for
1024 beats fails the suite) and a 4KB-legality test. Timing: three directive-luck gate failures
(clk_sally −0.200/−0.200/−0.073, the binding path ALTERNATING between the two free-floating
overlay CPU-read BRAMs) → the timing study's **Lever A** (pin them into `pb_sally`, XDC-only)
closed it ON THE DEFAULT DIRECTIVE at +0.025/+0.062 — determinism claim proven. (Lever B, the
mux split, was already in since 909c65f.)

**The engine presents for gemd now** (8be0f91, board-verified): `/dev/blitter` gained the two
well-known handles (PLANE + WALLPAPER — fixed regions, kernel-known geometry, driver-side
cache-clean of the cached source; WALLPAPER refused as a destination), and `gemd_present` is a
submit + SEQ fence with the CPU rows as automatic fallback (qemu, or any failed submit). Live
resize composites only the L-shaped DELTA between reflows (dd1b778).

**And then the profilers ended the perf chase with a verdict** (018c056, probes marked TEMP in
input_dev.c/server.c): during a drag the terminal delivers **12-13 motion events/s**, gemd
consumes every one, and the whole render pipeline idles at ~15 ms of work per second. The
remaining resize lag is INPUT CADENCE — the serial GUI lane (SGR mouse over 115200) was always
the transitional hack, and the **STM32F411 HID companion is the fix of record**. Two software
follow-ups remain worth having: an IRQ-backed blocking fence (the SVC-spin fence burned 55 ms
against 19 ms of blitting on full-screen presents; the engine's completion IRQ already exists)
and the AR pipeline 2 → 4 (~850 MB/s). The compositor's inner blit stays CPU for now — the
engine composite is DESIGNED and DEFERRED TO M7 (see "The engine composite" below).

**Both follow-ups landed overnight 2026-07-14/15** (6a1b191 + 5b19048, board-verified): four
segment buffers keep the R stream continuous — engine COPY **433 → 777 MB/s** (4.15× the
morning's 187 baseline), blittest all-green — and the fence is ONE blocking syscall
(`XT_BLIT_WAIT`: kernel register-spin then tick sleeps, 200 ms bound) instead of the SVC storm
that burned 55 ms per full-screen present. Timing note for the record: the 4-buffer netlist
closed at clk_sally **+0.003** and only under Explore (default/ExtraTimingOpt both −0.381 on
the screen-bank → line-reader CE path). The pinned region is at its congestion tipping point;
the next clk_sally session (study Lever C, or rebalancing the overlay BRAMs adjacent) should
happen BEFORE the next netlist growth, not after it fails a gate.

**THE RESIZE DISCIPLINE (M5, user-derived general rule — BOARD-VERIFIED 2026-07-15,
with the day's full perf trail: transfer_bits fast paths + Bresenham stepping + frame-strip
overdraw + left-grip union compositing; the user's verdict: "everything is working really
nicely"):** scroll's rule, generalised. Within
a §12 capacity the old∩new work-area pixels are already rendered — they sit in the backing
store — so a resize step owes only (a) the exposed strips and (b) whatever the app's own
LAYOUT invalidates, and only the app knows (b): the icon grid reflows on a column-count
change, never on height; a vertical shrink owes nothing at all (the vacated screen estate is
gemd's, recomposited from the desktop's store). `WIND_RESIZE_APP` (aes.h; default stays
FULL = always correct): `client_sized` paints nothing within capacity and the app answers
`WM_SIZED` with what its layout demands; a FRESH surface (capacity realloc, pixels gone) is
repainted fully by the AES and flagged `msg[5]=1`. Client-side model only — no wire change.

**The drag capacity policy (M5, board-verified):** a grow drag crossed the §12 quantum every
~64px and every crossing was a FRESH surface — a dozen realloc+full-repaint blinks per drag.
The AES exposes `wind_drag_sizing()` (the sizer modal loops set it); gemd allocates ONCE and
generously while a drag is live (screen-size capacity) and shrink-fits in ONE realloc on
release. The swap is CONTENT-PRESERVING (old intersection memcpy'd across before the switch)
so a realloc is visually a non-event — the black flash was uninitialized shm compositing
before the client's repaint landed. And a breadcrumb PRESS is not yet a click: release in
place navigates, motion past 3px falls through to the mover with the original grab point.

**THE CHROME REWORK (M5 close-out, 2026-07-15, user-designed):** the info strip lives at the
TOP of the work area under the titlebar (lighter fill, 1px divider below as the demarcation;
`wind_pin_top` bounds the scroll blit and never goes on the wire); the horizontal scrollbar is
a clean reservation off the work BOTTOM (mirror of the vertical column, which stops above it);
and the permanent grips are GONE — a W_SIZER window resizes from its frame ring (corner + edge-
midpoint proximity zones, border + 8px outside, interior always wins) with THE CURSOR as the
affordance (`SYS_cursor_shape`: HW-sprite glyph swap on hover transitions; theme-able hover
brackets remain open as a second layer). One anchor-parameterized drag covers all four corners
and edges. First h-scroll consumer: the text views floor their column width instead of
crushing, and consume `scroll_x` symmetrically with `scroll_y`. Board visual pass pending.

## The composite is CPU-bound in transfer_bits, and the engine composite is M7 work

The M5 resize-lag chase ended in three board-measured verdicts, each found by the
`-DINSTRUMENTATION` profiler (`[gemprof cli]`/`[gemprof srv]` klog lines, 1/s; `dmesg -c`
between tests) — recorded here so M7 starts from facts, not a re-investigation:

1. **`vr_transfer_bits`' generic loop is a per-pixel function call**, and `blend_op` re-derived
   the four blend pen colours per pixel. One full-desktop render (wallpaper VR_OVER through it)
   measured **1365 ms → 51 ms** once unscaled COPY/VR_OVER got dedicated bit-identical loops
   (`d42265a`), and the chrome (9-slice edges + title bars, which STRETCH and so missed the
   unscaled paths) measured **550 ns/px** — 1.1 s/s of composite, gemd saturated, the window
   chasing the mouse at 3-5 resize steps/s against 30-39 motions/s — until the scaled
   COPY/VR_OVER loops joined them.
2. **Client rendering was never the problem** (16-30 ms a frame at 9 columns, 92% idle), and
   neither was the §12 surface dance (alloc/remap 0-6 ms). The profiler's lesson generalises:
   when `render` dwarfs the sum of its parts, the time is in a path the ledger does not cover —
   instrument the gap before theorizing (two wrong theories died to this rule in one session).
3. **The mappings are NOT the bottleneck**: gemd's boot-time membench (INSTRUMENTATION-gated,
   kept as the attribute-regression canary) measures every edge of {shm surface, heap,
   back-buffer} at ~5.5 ms/MB — uniform, cacheable, no Device mapping anywhere. Window
   surfaces are ordinary cached shm (`L2_SHM`), the back-buffer is the cached wallpaper
   region, and chrome text blends at ~30 ns/px through both.

**The engine composite — LANDED 2026-07-17 (M7a).** As built: surfaces are `XT_SHM_CONTIG`
plv with **CACHED per-process views** (`SEC_SHM_C`, nG — the settled "client-side story":
software still renders through the caches, and `/dev/blitter` owns coherency per submit —
cached source rows CLEANED before the engine reads, cached destination rows
CLEAN+INVALIDATED on both sides of the engine's write, which runs synchronously in the
driver for that case). plv is a budget: exhaustion falls back to pooled shm and the CPU
path (`gsurface.contig`). gemd declares each surface (id → stride) at attach; the AES seam
is `aes_set_compose_blit` — draw_content's opaque inner blit goes to the engine (min 4096
px), odd leading/trailing columns are CPU-copied (the damage clip is a hard boundary), and
`clamp_win` snaps the work-origin x even so the FC path co-aligns. W_ALPHA windows and all
chrome stay CPU. Recycled plv sections are clean+invalidated at create (a prior tenant's
dirty lines must not evict over the new owner). The original design notes, all satisfied:

1. **Driver**: accept the cached back-buffer (`XT_BLIT_SURF_WALLPAPER`) as a blit
   *destination* (refused today) and **invalidate the destination rows after the engine
   writes** — clean+invalidate at unaligned edges, the SD-DMA lesson, symmetric to the
   existing source-row cleaning.
2. **gemd**: declare each client surface to `/dev/blitter` at `wind_attach_surface` time and
   give `draw_one`'s inner blit an engine path (the `blit_rect` backend seam §14 asks for).
   Surfaces would need to be physically contiguous for the engine — they are pool-backed
   scattered pages today, so this is `XT_SHM_CONTIG`/plv **at the same time**, which is
   exactly §14's "backing stores move to plv when the VDI's blitter backend moves, and not
   one commit before". plv is uncached, so the CLIENT keeps a cached view or eats uncached
   writes — the client-side story must be settled as part of this design, not assumed.
3. **FC constraints**: 8-byte co-alignment + even width. With the 64px capacity quantum and
   even strides everywhere, co-alignment parity reduces to the window's screen x — snap
   window x to even in the AES (invisible), widen odd rects a pixel within bounds, CPU-copy
   a 1 px edge column when clamped.
4. **Chrome fills and text stay CPU** — small, and never the problem.

## gemd renders CACHED and presents rects (the 3-second redraw)

Observed on the board while testing M5: **one window redraw took ~3 seconds.** The plane is
NON-cacheable (the HW compositor scans it), and gemd's VDI was rendering straight into it —
FreeType blends, 9-slice edges and pattern fills read-modify-write nearly every pixel they
touch, and every one of those reads was an uncached DDR round-trip. §14 called drawing into the
plane "the worst of both worlds"; this is what it costs. The old desktop had the cure
(`SYS_fb_wallpaper` + a present) and the no-fallback commit deleted it APP-side — correctly,
apps must not present — but it never moved INTO gemd.

Now it has: gemd's VDI renders into the kernel's **cached** back-buffer (`SYS_fb_wallpaper` — a
dedicated 16 MB PL0-RW cacheable region, no heap cost), and `gemd_present` (the
`aes_flush_rect` hook, which `wind_redraw_area` already calls with exactly the damage rect) is
the ONLY thing that touches the plane: cached reads, sequential uncached row writes, then
`SYS_fb_present`'s dsb. No kernel change. Follow-ups when someone wants them: the blitter's
SRC_BLIT as the present copy, and the HW drag overlay (gemd registers no `begin` hook, so drags
still redraw-per-motion).

**The menu strip's SPACE is reserved before the strip exists** (`aes_reserve_top(AES_MENUBAR_H)`
at gemd startup): the fuller was maximising to the full 1920×1080 with no room left for the
M4b menu bar. `W_BOTTOM` windows are exempt from the top clamp — the desktop is wallpaper and
must run UNDER the bar, which draws over it (always-on-top chrome) when M4b lands.

## M6 — the plane bind (the "new server call" the blocked-by-design analysis asked for)

A plane is gemd's (Rule 1) and a client does not know where its window is (§5) — so the bind
is a **protocol message**, and the client's whole involvement is one call:

- **`wind_plane_bind(wh, plane_id, scale)`** → `GEM_WIND_PLANE {wh, plane_id, scale}` on the
  wire. `plane_id=0` unbinds; ids are the KERNEL's namespace (`XT_PLANE_XL=1` in xtsys.h,
  aliased `AES_PLANE_XL` in aes.h), generic from day one (m68k gets an id when its GP0 block
  exists). One window per plane; a re-bind of the same window updates the scale; close or
  client death unbinds. `desktop.c`'s `xl_sync()` is this call.
- **gemd owns the placement.** The bind handler records (plane → window) and marks the awin;
  from then on `draw_content` composites that window's work area as an **alpha=0 HOLE**
  (`gfx_fill_rect` with a raw 0-alpha word — the VDI's own paths force alpha opaque, which is
  why nothing else ever punches one by accident), and every ordinary window composited above
  stamps opaque pixels: **per-pixel occlusion of the live plane, no clip-rect list** (Route A,
  HW-proven — docs/OS/m6-routeA-handoff.md, memory `m6_routeA_alpha_hole`).
- **The plane follows the window through ONE hook.** `aes_set_plane_sync(gemd_plane_sync)`
  runs at the end of every `wind_redraw_area` — every move, resize drag, raise, maximise,
  scroll-column change and close ends in a composite, so there is no mutation path to hook
  individually. gemd re-reads the work-area screen rect and calls `SYS_plane_window` only when
  it changed (change-detected: a composite that moved nothing costs one comparison).
- **`SYS_plane_window(plane, x, y, w, h, scale, en)` (0x605)** generalises `SYS_xl_window`
  over a kernel table `plane_id → GP0 placement block` (XLCTL `0x43C0_0500`; XLCTL-shaped:
  X/Y/W/H/SCALE, EN commits across the clk_pix CDC). The kernel clips to the screen (x/y are
  signed — a window may overhang an edge) and owns the **CMPCFG arrangement**: the first
  active plane writes Route-A (`0x00010132`, desktop on top + alpha) BEFORE un-parking, the
  last park lands BEFORE the reset arrangement (`0x210`, XL opaque on top) returns — ordered
  so the reset arrangement never scans an un-parked plane. PS-only; no bitstream change.

v1 corners, deliberate: a window overhanging the LEFT edge shifts the plane picture (the
placement block has no source-offset register — the origin clamps at 0); two plane-bound
windows overlapping EACH OTHER resolve by plane depth, not window z (the blend is top-2).
Both documented in the handoff doc; neither blocks the single-emulator-window case.

## Traps found while doing M4 (do not rediscover)

- **A resident init cannot be waited for.** `init(1)` became the reaper and stopped exiting — but
  the kernel's `shell_task` still ended `boot_run()` with `frtos_waitpid(init)`, and that task is
  the one that starts the login shell / kernel menu. It blocked forever, so **the machine came up
  with no console output at all**. The board hid it (the desktop is the UI, and ssh still worked);
  under headless qemu, where the console *is* the machine, it looked like a kernel that died before
  its first write, and it blocked the compiler/arm9 thread for a day. init now says it is done
  (`SYS_boot_done`) and the kernel waits for THAT — with a 30s ceiling, so a wedged boot script
  costs you the script, never the console. **Anything that assumed init exits is now wrong.**
- **The child outruns the spawn.** A PL0 process is created at a priority that preempts
  `shell_task`, so it can reach its first syscall *before* `frtos_spawn_argv()` returns. Recording
  init's pid from the returned value was too late: init's `SYS_boot_done` arrived while
  `g_init_pid` was still 0 and was refused, and the console waited for a signal that had already
  been sent and thrown away. The kernel now claims init's identity at pid assignment
  (`frtos_claim_next_as_init()`), not after the spawn call returns.
- **Headless qemu has no `/bin/sh`** (the romfs deliberately carries no shell — the board's lives
  on the SD). qemu therefore lands on the **kernel menu**, not toysh. That is correct, and it is
  what `make hosttest` drives. Do not "fix" it by putting a shell back in the romfs.
- **A device that starts its producer on first READ deadlocks a poller.** A poller never reads
  until `poll()` says readable, and `poll()` never says readable until something has been
  produced. `/dev/input` starts its decoder at **open**.
- **A blocking device read must honour a kill** (`xt_block_check()`). Without it a process parked
  in `read()` is unkillable — and on an event device it stays a READER, silently drinking the
  events its replacement is waiting for. A debugging `cat /OS/dev/input` cost an hour of
  "input is broken" that was really "input works and something else is drinking it".
- **`vfs_open()` must clear EVERY op.** fd slots are reused; a driver that does not set a field
  inherits the last file's function pointer.
- **libGEM.so is cached by soname for the life of the boot.** `sdpush` + restarting gemd does
  **not** pick up a libGEM change — the loader hands out the already-loaded image. **Reboot the
  board.** (The HW romfs carries no libGEM, so the SD copy *is* the one that loads — but only on
  the next cold boot.)
- **The console's GUI lane is reachable over netcon now.** `sh_inject()` ignored the focus toggle,
  so the pointer/key lane could only be driven from the physical serial port. One console, two
  transports: the transport must not change what a byte means. (`` ` `` flips focus; it TOGGLES,
  so a test script that sends it twice ends up back on the shell.)

## 🔴 DECIDED (user, 2026-07-13): on XTOS there is NO single-process fallback — DONE

**Everything goes through gemd. No exceptions.** The "single-process GEM" path — where an app
that finds no `gem` service keeps the old behaviour and paints the plane itself — is being
REMOVED on XTOS. It must not survive, because:

- **It defeats the M7 gate.** "No app draws direct any more" is the completion criterion, and a
  fallback whose whole purpose is *draw direct when gemd is missing* is a permanent exception.
- **It is a silent failure mode.** If gemd is dead or slow, an app does not error — it quietly
  paints the framebuffer and looks fine. That is the "works by accident" class of bug.
- It doubles every AES code path for a mode nobody wants.

**Not a contradiction:** the **host/SDL** build is genuinely single-process (no gemd, no plane).
That is a different *platform* (`GEM_XTOS` undefined), not a fallback. Rule: **on XTOS,
everything goes through gemd; on the host, single-process is the only mode.**

**DONE, board-verified.** `wind_client_attach()` waits for gemd (`gem_connect_set_wait`, default
2 s — "still coming up" must not look like "not there") and then **fails hard**: a message on
stderr and `exit(1)`. No local path, no plane access.

```
xtos$ /OS/bin/gemtext          (with gemd killed)
gem: no window server — is gemd running? (there is no single-process mode on XTOS)
gemtext exit=1
xtos$ /OS/bin/desktop          (waits its 5 s, then:)
gem: no window server — is gemd running? (there is no single-process mode on XTOS)
desktop exit=1                 (5.05 s. It did NOT paint the plane.)
```

`desktop.c`'s `present_rect()` / `present()` / `repaint()`, the `DRAG_BASE` overlay ops
(`ovl_begin`/`move`/`end`), the `SYS_fb_wallpaper` back-buffer and `a9_events()` (its direct
`sys_input`) are **DELETED, not disabled** — they were the last direct-plane code in an app, and
the M7 gate is "no app draws direct any more". The desktop is now ONE mode: a client. `HV` became
`aes_handle()`, because under gemd the workstation is bound PER WINDOW and a cached handle would
paint window 2's content into window 1's buffer.

**The host/SDL build is untouched** and still single-process: `GEM_XTOS` is undefined there, which
is a different PLATFORM, not a fallback.

## gemd does NOT spawn the desktop (decided)

`99-Desktop` starts **both**, as siblings: `gemd &` then `desktop &`. They race, and the
desktop's connect **retries** until gemd is listening. gemd must never know what a desktop is
(§2, §4) — the moment gemd launches it, "the desktop is just an app" stops being true. It also
means the desktop can be killed and restarted at will without touching gemd, which is the §4
property that makes it come back *underneath* the apps that outlived it. **Verified on a cold
boot:** `init(1)`, then `gemd` and `desktop` as siblings, desktop attaching as a `W_BOTTOM`
client at 1920x1080.

## Wire protocol (fixed 16-bit LE words, AES-message shaped)

**Client → gemd:** `WIND_CREATE {kind,x,y,w,h} -> WIND_CREATED {wh, surf_id, cap_w, cap_h}`,
`WIND_OPEN`, `WIND_SET`, `WIND_CLOSE`, `WIND_DELETE`, `MENU_BAR -> MENU_SURF`,
`GRAB_BEGIN/END`, `SURF_DROP {surf_id}`, `WIND_PLANE {wh, plane_id, scale}` (M6: show a HW
plane through this window's work area; 0 unbinds), and:

```c
DAMAGE { u16 wh;                /* 0 = the menu strip */
         s16 x,y,w,h;           /* SURFACE coords; gemd clamps (§9) */
         u32 surf_id;           /* handle, NEVER an address (§13.1) */
         u32 surf_gen;          /* stale-damage discard (§11) */
         u32 retire_seq; }      /* §14: DEAD IN PHASE 1. Client sends 0. DO NOT OMIT. */
```

**gemd → client:** `EV_KEY`, `EV_BUTTON`, `EV_MOTION` (window-local coords), `MSG_REDRAW`
(first-paint + resize ONLY — §3), `MSG_MOVED` (no redraw implied), `MSG_SIZED {…, new_surf_id,
cap_w, cap_h}` (**same id ⇒ resize within capacity ⇒ nothing to remap**, §12), `MSG_CLOSED`,
`MSG_ACTIVATE`, `GRAB_REVOKED` (§9 liveness).

### The three that must be right on day one (§14)

1. **`retire_seq` in `DAMAGE` from the first commit**, unused, always 0. Adding it later is a
   protocol break across every client.
2. **Surfaces named by `u32 surf_id` everywhere, never an address.** Phase 2 then changes only
   the allocator behind the id.
3. **`stride == capacity width`, not extent width.** Client draws into the top-left sub-rect.

## Module layout

```
gem/gemd/{server,surface,chrome,route}.c             NEW (server half; in libGEM.so)
gem/gemclient.c                                      NEW (client transport — NOT an app API)
gem/aes/window.c                                     one file, two modes: gemd owns g_w[]/g_z[]/chrome
loader/test/freertos/progs/gemd.c                    NEW (thin)
loader/sd/boot/99-Desktop                            -> /OS/bin/gemd &  THEN  /OS/bin/desktop &
```

### gemd does NOT spawn the desktop (decided 2026-07-13 — supersedes §4's "gemd launches it")

The boot script starts **gemd as a system service, then the desktop as an ordinary program**.
Both are children of the script; gemd is the parent of neither.

**Because gemd spawning it would smuggle back exactly the knowledge §4 forbids.** "gemd must
not know what a desktop is" — but a gemd that launches one has to know such a program exists,
where it lives, and when to restart it. §4's ordering guarantee ("gemd starts first") survives;
its mechanism does not, and the mechanism was the part that carried the role.

It also **deletes a trap instead of managing one**: the plan previously had to set the
do-not-inherit mask (`stdfds[3]`) so the spawned desktop would not inherit gemd's channel fds
(fds 3+ are same-slot-inherited). If gemd spawns nobody, nobody can inherit anything.

Two things move to the boot script / a supervisor, where they belong:
- **ordering** — gemd must be listening before the desktop connects (`appl_init()` retries the
  connect briefly, so the script does not have to sleep and guess);
- **restart** — "who brings the desktop back" is a service question, not a window-server one.
  Which is precisely §4's point: the desktop dies, `gemd` does not notice or care, and
  `W_BOTTOM` puts the replacement back *underneath* the apps that outlived it.

### One library, two modes (§5) — and the mode is chosen in `appl_init()`, not `aes_init()`

`aes_init(vdi_handle, theme)` already exists and **every app calls it today** (the desktop, every
demo) — it binds a VDI workstation and a theme, nothing more. Making it "the server entry point"
would turn every app into a window server. So:

- **`appl_init()`** connects to `"gem"`; if the service is there the app is a **client**, and if
  it is not (the SDL host, a single-process build) it stays **local** — today's behaviour,
  unchanged. That *is* §5's promise ("an app written against single-process GEM compiles and runs
  against gemd unmodified"), and it keeps the SDL testbed alive.
- **gemd** puts the library in **server** mode explicitly.

## ⚠ Known holes and traps

- ~~**`vm_shm_map` has NO ownership check**~~ — **CLOSED in M1** (`194a966`). `XT_SHM_OWNED`
  makes an id a capability: only the creator and the spaces it `SYS_shm_grant`s may map it, and
  a grantee cannot re-grant. Opt-in, because plain shm is also how a process shares a buffer
  with its own children and how the fs page cache is reached. Space indices are recycled, so
  `vm_space_create` scrubs the incoming index's owner/grant bits.
- ~~**`gem/aes/window.c:326` uses `d->w` where it means `d->stride`**~~ — **FIXED** (`729a9ca`).
- ~~**`input_next_event` swallows `-EINTR`**~~ — **moot (M4)**: the decoder now runs in a kernel
  task that loops forever, so a lost wake *reason* costs one lap and nothing else. It was NOT
  re-enshrined: the -4 is treated as "nothing to give", not as a timer event for anybody.
- **`DRAG_BASE` as the §12 resize scratch:** it is inside `SEC_PLANE`, which M7 makes PL0-none,
  so the client cannot map it. **Use an ordinary shm surface for the scratch**; keep `DRAG_BASE`
  gemd-private for the move overlay. A deliberate divergence from §12.
- **The compositor's inner loop must go through a backend interface** (`blit_rect`), or phase 2's
  `/dev/blitter` composite is a rewrite (§14).
- **Backing stores stay in ORDINARY CACHED memory. NOT `plv`.** §14 is explicit: `plv` is
  uncached, and a software VDI writing to uncached memory is the worst of both worlds. They move
  when the VDI's blitter backend moves — one change, not two.
- `MAXW = 16` (`window.c:15`) becomes a **system-wide** limit once it lives in gemd. Raise it.
- `NFD = 32` per process caps gemd at ~30 clients. Fine for now; know it is there.
- **⚠ ORPHANS ARE NEVER REAPED** (kernel bug, not gemd's). A process whose parent has exited
  (e.g. anything started from an ssh shell that then closed) stays in `ps` forever after it dies:
  `kill -0 <pid>` says "No such process" while `ps` still lists it. It looked exactly like "two
  desktops are running" during the M3 test. Orphans need re-parenting to a reaper (init/pid 1).

## The M7 gate — FLIPPED (2026-07-17): "no app draws direct any more" is enforced

The whole PL-shared band (0x2000_0000–0x3FFF_FFFF) is **PL0-none in the master table**
(`SEC_PLANE_K`/`SEC_PLANE_CK`, mmu.c), per the 2026-07-13 whole-range decision; the math-cop
chunk stack (`0x2080_0000`, 2 MB) stays PL0-RW as the deliberate exception. Three legs:

- **The grant**: the FIRST `SYS_fb_wallpaper` caller becomes THE DISPLAY OWNER (gemd, by boot
  order — the `XT_BLIT_PRIORITY` first-caller-wins shape, so the kernel still knows nothing
  about window servers, only that one process composites). `vm_map_fb_band` maps the plane,
  `DRAG_BASE` and the wallpaper back into that space only (identity VA, nG). Owner death
  resets the latch, so a restarted gemd re-claims. Everyone else gets fb *numbers* only.
- **The syscall leg**: `SYS_overlay` and `SYS_plane_window` refuse non-owners.
- **The driver leg**: `/dev/blitter` refuses the well-known `PLANE`/`WALLPAPER` handles from
  non-owners (own declared surfaces stay fair game — blittest passes untouched).

Side effect, deliberate: plv is PL0-none at its identity address too, so a CONTIG shm id is
now a real **capability at the memory level** (reachable only via `vm_shm_map`) — the caveat
vm.c carried since plv exists is closed. `fbgrab` lost its direct mapping (board-verified
fault-kill — the gate's negative test) and now reads **`/dev/fb0`**, a read-only
kernel-mediated stream of the raw plane: grabs stay a legitimate diagnostic, no PL0 mapping.
`DRAG_BASE` is gemd-private; wiring gemd's `wind_set_overlay` to the HW overlay is still a
free win whenever someone wants it.

⚠ **The gate is a DISCIPLINE boundary, not a security one, while `SYS_devmem` exists**: the
debug peek/poke syscall reaches any physical word from any process (mem/shmtest depend on
it). Fine for a development OS; revisit (boot-flag it off?) if the gate ever needs to hold
against hostile code.
