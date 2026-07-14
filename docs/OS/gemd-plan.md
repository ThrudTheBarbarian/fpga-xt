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
| M4b — the menu strip (§10), grabs, liveness | *owed — see "What M4 does NOT cover"* |
| M5 — resize: client-driven (`wind_set`), scroll/content size | in progress: **geometry is a wire request (WF_CURRXYWH) — the Fit button works**, build-verified; board + scroll/content size open |
| M6 — the XL plane | *blocked by design: a client cannot place a plane — see below* |
| M7 — **the gate**: `SEC_PLANE` → PL0-none | the last app-side plane code is now GONE, so this is a kernel flip |

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

- **The menu strip is §10 and is NOT done (M4b).** Under gemd the desktop does not call
  `menu_bar()`: menus draw through the AES's workstation, which in a client is bound per-window
  and only during a content callback. A menu strip needs its own surface (§10), which is the
  next piece of work. The desktop's menu bar, its context menus and its `form_do` dialogs are
  therefore **unreachable under gemd today** — the code is intact, not deleted.
- **`wind_title` / `wind_info` / `wind_titlebtns` cannot survive the split as they are.** They
  are *app callbacks that draw INSIDE the chrome*, and gemd cannot call a function pointer in
  another address space (that is the one line M2 exists to break). Browser windows therefore lose
  their breadcrumb title, their info footer and their title buttons under gemd. **This is a
  design question, not a bug to patch**: either those become client-drawn surfaces composited
  into the chrome, or the AES grows a declarative title model. Flagged, not guessed at.
- **Scrollbars**: `wind_content_size()` is a local call, so gemd does not know a client's content
  height and draws no scrollbar. Needs a `WIND_SET` message (M5).

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

**Still owed in M5 — scroll/content size.** The scrollbar is a REAL control: gemd draws it and
runs its interaction (it is chrome), but it cannot know a client's content height until
`wind_content_size` goes on the wire, and a scroll's consequence must reach the client so it can
shift its own backing store (an internal VDI blit) and post the dirty rects. Not started.

## M6 is blocked BY DESIGN, and that is the right answer

The XL plane (emulator video) is placed with `SYS_xl_window(x,y,w,h)` — **screen** coordinates.
A client does not know where its window is and may not ask (§5), and a plane is gemd's (Rule 1).
So `xl_sync()` in `desktop.c` is now a **no-op**, deliberately: `wind_get(WF_WORKXYWH)` honestly
returns SURFACE coordinates in client mode, and faking the placement with those numbers would put
the emulator picture at the top-left of the screen and call it working. **M6 needs a new server
call** ("gemd, put plane N on my window"), which is a protocol decision, not a rearrangement.

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
`GRAB_BEGIN/END`, `SURF_DROP {surf_id}`, and:

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

## Still to draw direct to the plane (the M7 gate = "no app draws direct any more")

**NOTHING DOES, as of the no-fallback commit.** `desktop.c`'s `present_rect()` and the `DRAG_BASE`
overlay ops are deleted; `gemtext.c` was already an ordinary client. Nothing in `gem/` touches the
plane — it goes through the `aes_flush_rect` / `wind_set_overlay` hooks, which is why the split
was tractable. **M7 is now a kernel flip, not an app port.**

**Decided (2026-07-13): the gate locks the WHOLE `SEC_PLANE` range**, not just the framebuffer.
The math-cop buffer (`0x2080_0000`) is a deliberate exception and stays PL0-RW. Before flipping
it, note that gemd itself must keep the plane (it is the compositor) and that `DRAG_BASE` is now
**gemd-private** (no app writes it) — the drag currently uses the classic redraw-per-motion path
because gemd registers no overlay hook. Wiring gemd's own `wind_set_overlay` to the HW overlay is
a free win whenever someone wants it.
