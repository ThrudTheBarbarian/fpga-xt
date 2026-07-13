# gemd — phase 1 implementation plan

Spec: `Rocks/doc/RESPONSIBILITIES.md` (§3–§11 = the design, §12 = capacity/extent, §14 = what
phase 1 is and is not). This file is the *implementation* plan and the running status.

## Status

| | |
|---|---|
| **kernel prerequisites (§14)** | **DONE, board-verified.** variable-size shm; `sys_shm_unmap` |
| **M0 — the channel** | **DONE, board-verified** (commit `3c6f5b4`) |
| **M1 — gemd skeleton + one client** | **DONE, board-verified** (see below) |
| M2 — window list moves server-side | |
| M3 — desktop becomes a client | |
| M4 — menu strip, grabs, liveness | |
| M5 — resize (capacity/extent) | |
| M6 — the XL plane | |
| M7 — **the gate**: `SEC_PLANE` → PL0-none | |

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
| capability | `shmtest`'s child is REFUSED an un-granted `XT_SHM_OWNED` id (before this it could map it and read another process's window), while ordinary shm sharing still works both ways. |

**The surface-capability hole is closed** (`194a966`): `XT_SHM_OWNED` + `SYS_shm_grant`
(owner-only, no re-grant) + `SYS_chan_peer`. gemd grants a surface to the pid the KERNEL
reports for the channel — a pid carried in the client's own message would be a capability
handed out on the say-so of the process being granted it.

> ⚠ **ssh is currently down on the board** — unrelated to gemd: `/bin/sshd-session`
> (`dropbear.so`) fails to load with `xtld_load err: svr_opts rc=undefined symbol`. It is a
> loader/link issue exposed by a *relink* (any edit to `loader/kernel/xtsys.h` cascades:
> `libc.so` -> `dropbear.so`). M1 was verified over the netcon console instead (telnet :23),
> which preserves the property that matters: gemd is not the client's parent either way.
> Written up for the compiler/loader thread.

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
gem/gemd/{server,surface,composite,chrome,route}.c   NEW (server half; in libGEM.so)
gem/gemclient.c                                      NEW (client transport)
gem/aes/window.c                                     GUTTED client-side; g_w[]/g_z[]/chrome -> gemd/
loader/test/freertos/progs/gemd.c                    NEW (thin: aes_init + run)
loader/sd/boot/99-Desktop                            -> /OS/bin/gemd &   (gemd spawns the desktop)
```
One library, two modes (§5): `aes_init()` = server, `appl_init()` = client. Keeps AES signatures
identical. **Set the do-not-inherit mask (`stdfds[3]`) when gemd spawns the desktop** — fds 3+ are
same-slot-inherited by default, so a spawned app would otherwise inherit gemd's channel.

## ⚠ Known holes and traps

- ~~**`vm_shm_map` has NO ownership check**~~ — **CLOSED in M1** (`194a966`). `XT_SHM_OWNED`
  makes an id a capability: only the creator and the spaces it `SYS_shm_grant`s may map it, and
  a grantee cannot re-grant. Opt-in, because plain shm is also how a process shares a buffer
  with its own children and how the fs page cache is reached. Space indices are recycled, so
  `vm_space_create` scrubs the incoming index's owner/grant bits.
- ~~**`gem/aes/window.c:326` uses `d->w` where it means `d->stride`**~~ — **FIXED** (`729a9ca`).
- **`input_next_event` swallows `-EINTR`** (`sprite.c:273`): `-4 < 0` is reported as a spurious
  `OS_EV_TIMER`. The wake happens, the *reason* is lost. Moot once input is an fd gemd polls.
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

## Still to draw direct to the plane (the M7 gate = "no app draws direct any more")

Only two: **`desktop.c`** (`present_rect()` :81 → framebuffer; `ovl_begin()` :127 → `DRAG_BASE`)
and **`gemtext.c`** (its whole body). Nothing in `gem/` touches the plane — it goes through the
`aes_flush_rect` / `wind_set_overlay` hooks, which is why the split is tractable.

**Decided (2026-07-13): the gate locks the WHOLE `SEC_PLANE` range**, not just the framebuffer.
So the desktop's drag-overlay writes break too — **two** things must become server calls, not one.
The math-cop buffer (`0x2080_0000`) is a deliberate exception and stays PL0-RW.
