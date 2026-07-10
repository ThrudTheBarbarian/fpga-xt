# GEM interaction upgrade: forms, menus, drag & drop

> **Proposed design — not built.** A major interaction upgrade for the XTOS
> AES (`gem/aes/`): movable dialogs, keyboard mnemonics, editable text
> fields, per-app menu bars + popup menus, and a GEM-wide drag & drop
> mechanism. Everything is specified as AES API so the two desktop twins
> (`gem/xtdesk.c` host / `loader/test/freertos/progs/aesdesk.c` A9) and
> future multi-app clients (GApplication `.so` apps, XEX class `$FFFE` GEM
> apps — [app-launch](app-launch.md)) consume the same mechanism. Stage 1
> is sized to unblock the FujiNet **Add Server…** dialog
> ([fujinet-network](fujinet-network.md) §4).

## Where we are (code inventory)

- **Events** (`aes/event.c`): `evnt_multi` with `MU_KEYBD|BUTTON|M1|M2|MESAG|
  TIMER|QUIT` — the M1/M2 mouse rectangles *are* implemented. One host
  source (`aes_set_events`); `aes_event` has a `shift` field but **neither
  source fills it** (the SDL desktop never sets it, the A9 terminal decoder
  hardwires 0). `key` is host-flavoured: SDL keysym on the host, raw ASCII
  on the A9. `appl_write` ignores `dest_id` — one global 8-word message
  queue.
- **Forms** (`aes/form.c`): `form_do` = buttons (flash + release-inside),
  checkbox/radio, Return fires `OF_DEFAULT`. No editing, no Esc, no TAB, no
  mnemonics, not movable. `form_alert` builds/saves-under/restores its own
  dialog — the save-under machinery exists but is private to alerts.
- **Menus** (`aes/menu.c`): a single global top-of-screen bar exists
  (`menu_build`/`menu_bar`, modal pull-down inside `evnt_multi` via
  `menu_handle_click`, posts `MN_SELECTED` msg[3]=title obj, msg[4]=item
  obj). No per-app switching, no popups, no accelerators, and the pull-down
  draws without `aes_flush_rect` — invisible on the A9 back-buffer target.
- **Objects** (`aes/object.c`): draw-only `G_FTEXT`/`G_FIELD`; `OF_EDITABLE`
  is declared and never read. `G_POPUP` draws a popup-shaped field, nothing
  runs it.
- **Windows** (`aes/window.c`): frame drag/resize/close in
  `wind_handle_click`, HW drag-overlay hooks (`wind_set_overlay` →
  `SYS_overlay`, DRAG_BASE plane), `aes_flush_rect` present hook.
- **Desktops**: click-select + double-click via a `MU_BUTTON|MU_TIMER`
  re-wait (`desk_click`/`br_click`); async fujinetd I/O drained by
  `net_pump()` off a 40 ms `MU_TIMER` tick while requests are pending.
  Desktop icons come from the registry (`desktopIcons` — opened
  **read-only**; fujinetd owns all registry writes today). Headless render
  modes (`--ppm --sel --browse --fuji*`) snapshot to PPM for tests.
- **A9 input** (`loader/test/freertos/sprite.c`, `SYS_input`): terminal
  escape-sequence decoder — SGR/X10 mouse reports, arrows *move the
  pointer*, `Tab` and `Enter` are synthesized clicks, `\` toggles
  press-and-hold for drags, keys are single ASCII bytes (Ctrl → control
  chars; no Alt, no scancodes, no key-up, `shift` always 0). The cursor is
  a kernel-side HW sprite. Real HID (STM32 keyboard/mouse) will replace
  this; the design below must degrade gracefully on the terminal decoder.

## Survey: the modern GEM world

What the surviving AES implementations and desktops do, and what we take.

| Area | Prior art | We adopt | We reject |
|------|-----------|----------|-----------|
| Movable dialogs | MagiC **flying dialogs**: every dialog/alert gets a "fly corner" (*Eselsohr*, dog-ear) top-right to drag it by; right-button/Alt drags move it transparently ([MagiC manual p.53](https://www.dsd.net/files/dl.php?File=Magic.pdf), API = `form_xdial`/`form_xdo` ["flydials"](https://www.exxosforum.co.uk/atari/mirror/toshyp/00800b.html)). XaAES instead hosts `form_do` in real **windows** — movable only if `xa_nomove` is off ([XaAES wiki](https://github.com/freemint/freemint/wiki/XaAES)) | The fly-corner handle **plus** grab-anywhere-inert, save-under move (§Forms) | Windowed dialogs (form_do stays modal; revisit for multi-app); transparent move (no alpha win worth the blend) |
| Editable fields | AES `TEDINFO` + `G_FTEXT`, [`objc_edit`](https://www.exxosforum.co.uk/atari/mirror/toshyp/008010.html) with `ED_START=0/ED_INIT=1/ED_CHAR=2/ED_END=3`, `te_ptmplt` `'_'` templates, [`te_pvalid` validation set](https://www.exxosforum.co.uk/atari/mirror/toshyp/008016.html) | The classic call shape, template + pvalid semantics, a reduced TEDINFO (§Editable fields) | The six font/colour/thickness TEDINFO words (the theme owns appearance) |
| Dialog shortcuts | The **WHITEBAK convention**: `OS_WHITEBAK (0x40)` in `ob_state` + high byte = index of the underlined char ([TOS.hyp fundamentals](https://freemint.github.io/tos.hyp/en/aes_fundamentals.html); XaAES masks bits 8–14, [`ob_fix_shortcuts`](https://github.com/freemint/freemint/blob/master/xaaes/src.km/obtree.c)). XaAES **auto-assigns** Alt-shortcuts to every `form_do` dialog since 0.999. Geneva instead marks with `'['` inside button strings. MagiC: UNDO fires the Cancel/Abort button, F1–F3 fire alert buttons ([manual pp.53-54](https://www.dsd.net/files/dl.php?File=Magic.pdf)) | WHITEBAK storage verbatim + XaAES-style auto-assign; Return=default (built), Esc=cancel via a new flag | Geneva's in-string marker (encoding rot); UNDO key (no such key on our boards) |
| Drag & drop | MultiTOS **D&D protocol**: `AP_DRAGDROP (63)` AES message (msg[3]=dest window, [4]/[5]=mouse x/y, [6]=kbshift, [7]=pipe suffix) + a named-pipe handshake (`U:\PIPE\DRAGDROP.xx`, acks `DD_OK=0/DD_NAK=1/DD_EXT=2/DD_LEN=3/DD_TRASH=4/DD_PRINTER=5/DD_CLIPBOARD=6`, types `"ARGS"`/`"PATH"`) ([TOS.hyp D&D](https://freemint.github.io/tos.hyp/en/proto_dd.html)) | The message word-layout verbatim, the ARGS/PATH type vocabulary | The pipe transport (one AES process; the doorbell ABI moves 16-bit arrays, not fds) |
| Drop conventions | [TeraDesk](https://github.com/freemint/teradesk) (manual §5.3): plain drop=**copy**, Ctrl=move, Alt=rename-on-copy, Esc aborts; symlinks via a menu, never a drag. Windows: plain = move-within-volume / copy-across, Ctrl=copy, Shift=move, [Alt/Ctrl+Shift=shortcut](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/mmc/using-copy-as-the-default-drag-and-drop-verb); Mac: plain=move, [Option=copy, Cmd-Option=alias](https://support.apple.com/en-us/102650) | The Windows modifier table (§Modifiers) — same-volume moves are what a desktop mostly does, and it degrades best to no-modifier input | TeraDesk's always-copy default (surprising for local reorganising) |
| Drop-on-executable | TeraDesk ("the name of the file is passed to it as a parameter") & Windows both launch the target with the dropped file as argument | Yes — resolves through the same launcher as a double-click | — |
| Menus | Classic `menu_bar(tree,1)` + `MN_SELECTED` (msg[3]=title, msg[4]=item; AES 3.30 adds msg[5..6]=tree address, msg[7]=parent obj); multitasking AES swaps the visible bar to the **topped app's** (`MENU_INSTL=100` = install without topping); [`menu_popup`](https://freemint.github.io/tos.hyp/en/menu.html) (AES 3.30+, `MENU{mn_tree,mn_menu,mn_item,mn_scroll,mn_keystate}`) and MagiC `form_popup` (1.11+) "run a popup" | Per-app bars keyed by `ap_id`, swapped on topping; a run-a-popup call | Scrolling popups (`mn_scroll`), `menu_attach` submenus (v1); pointer words in MN_SELECTED (handles, not addresses, cross the doorbell) |

## Event layer: the full `evnt_multi` treatment

The five features below all need two things the event layer doesn't carry
today: **modifier state** and **portable key codes**.

### Key + shift normalisation

```c
// aes_event.key: low byte = ASCII (0 if none), high byte = scancode.
// Scancodes use the Atari keyboard table (free m68k-app compat later):
enum { XK_UP=0x48, XK_DOWN=0x50, XK_LEFT=0x4B, XK_RIGHT=0x4D,
       XK_HOME=0x47, XK_DEL=0x53, XK_INS=0x52, XK_F1=0x3B /*…F10=0x44*/ };
// aes_event.shift / evnt_multi kstate: classic Kbshift bits:
enum { K_RSHIFT=0x01, K_LSHIFT=0x02, K_CTRL=0x04, K_ALT=0x08, K_CAPS=0x10 };
```

- **Host** (`xtdesk.c present_and_wait`): fill `ev.shift` from
  `SDL_GetModState()`, map SDL keysyms → the table above. ~15 lines.
- **A9** (`sprite.c input_next_event` / `struct os_event`): the struct
  already has `shift`; the kernel input layer fills it once HID lands. The
  terminal decoder can only infer Ctrl (control chars) — it reports
  `K_CTRL` for `0x01–0x1A` and leaves the rest 0. Documented degradation,
  not a blocker (see A9 specifics).
- `evnt_multi` already returns `kstate` through `oks`; it just starts being
  real. `MU_M1`/`MU_M2` are already live — no new event classes are needed;
  D&D and editing are built on `BTN_DOWN/MOTION/BTN_UP` + `MU_TIMER`.

### Idle hook (the net_pump problem)

`form_do`, `menu_handle_click` and the window-drag loops are **modal**
(`aes_wait(-1)` loops), so today a dialog freezes in-flight FujiNet
transfers until it closes. Fix once, centrally:

```c
void aes_set_idle(void (*fn)(void), int period_ms);   // NULL = none
```

Every modal AES loop waits with `period_ms` instead of forever and calls
`fn` on timeout. The desktops register `net_pump` (40 ms, matching their
main-loop tick). This replaces per-loop hacks and keeps the async pattern
in [fujinet-network](fujinet-network.md) honest inside dialogs.

### Message pipe, multi-app shape

`appl_write(dest, …)` starts honouring `dest_id`: one queue per registered
app (`appl_init` returns distinct `ap_id`s; the in-process desktop is app
0). All new protocol below is **8-word AES messages** — they survive the
[GEM service ABI](../GEM/gem-service-abi.md) doorbell (16-bit word arrays)
unchanged, which is why pipes were rejected for D&D.

## Forms

### Movable dialogs (req 1)

`form_do` owns a save-under the way `form_alert` already does — the
save/centre/restore moves into a wrapper both use:

```c
int form_do_dialog(OBJECT *tree, int edobj);   // centre + save-under + form_do + restore
```

Move triggers, checked on `AES_BTN_DOWN` inside `form_do`:

1. **Corner handle**: a theme-drawn grip in the root box's top-right 16×16
   (drawn whenever the tree root has the new `OF_MOVEABLE` flag) — MagiC's
   fly corner, so moving is discoverable.
2. **Grab-anywhere-inert**: `objc_find` returned the root, or an object
   with no `OF_SELECTABLE|OF_EXIT|OF_TOUCHEXIT|OF_EDITABLE` — i.e. not an
   active control.

The drag loop restores the save-under, offsets `tree[0].ob_x/y`, re-saves
and redraws per motion (host), or lifts the dialog rect into the HW drag
overlay exactly like a window drag (A9 — same `wind_set_overlay` hooks,
`aes_flush_rect` at drop). Dialogs clamp to the work area like windows.

### Mnemonics (req 2)

Every control with attached text gets an underlined shortcut letter *as
basic functionality* — so assignment is automatic, not opt-in:

- **Storage**: the WHITEBAK convention, verbatim — `OS_WHITEBAK (0x40)`
  set in `ob_state` means bits 8–14 hold the index of the underlined
  character in the label (XaAES's 7-bit reading, bit 15 reserved). Apps
  may pre-set it to pick their letter; resource-compatible if m68k apps
  ever hand us trees.
- **Auto-assign**: on `form_do` entry, a tree scan gives each
  `G_BUTTON/G_CHECKBOX/G_RADIO` (and each `G_STRING` immediately preceding
  an editable field) without a preset WHITEBAK the first letter of its
  label not yet claimed in this dialog, case-insensitive; collisions fall
  through to later letters. (Precedent: XaAES has auto-assigned dialog
  shortcuts this way since 0.999.)
- **Draw**: `objc_draw` underlines that character (a 1-px `v_pline` under
  the glyph, position via `vqt_extent` of the prefix).
- **Fire**: a key matching a mnemonic acts as a click on the object —
  buttons press (EXIT terminates), checkboxes toggle, radios select,
  labels-of-fields focus the field. Bare letters fire when **no editable
  field has focus**; `Alt+letter` (and, on the terminal testbed,
  `Ctrl+letter`) fires always.

### Default, cancel, TAB (req 3)

- **Return** fires `OF_DEFAULT` — already built; kept.
- **Esc** fires the object carrying the new flag `OF_CANCEL (0x200)`; if
  no object has it, Esc is ignored (a modal dialog with no cancel button
  stays modal, it does not become "exit -1"). `form_alert` sets
  `OF_CANCEL` on its sole button in single-button alerts, so Esc dismisses
  them.
- **TAB / Shift-TAB** move focus to the next / previous `OF_EDITABLE`
  object in tree order (wrap). A click in an editable field focuses it.

### Editable fields (the TEDINFO decision)

**Simplified TEDINFO, faithful call shape.** We keep the classic names and
semantics for the fields that carry meaning, and drop the six
font/colour/thickness words — the theme draws the field
(`textfield` slice), so per-object styling is dead weight:

```c
typedef struct {
    char   *te_ptext;    // the editable text (caller's buffer)
    char   *te_ptmplt;   // display template, '_' = input position ("__:__")
    char   *te_pvalid;   // one validation char per input position
    int16_t te_txtlen;   // sizeof buffer at te_ptext (incl. NUL)
    int16_t te_just;     // TE_LEFT / TE_RIGHT / TE_CNTR
} TEDINFO;
```

`G_FTEXT` (and `G_FBOXTEXT`) take `ob_spec = TEDINFO*`; with `OF_EDITABLE`
they render as a themed text field with a caret when focused. `te_pvalid`
implements the classic set — `'9'` digits, `'A'` uppercase+space, `'a'`
letters+space, `'N'` digits+uppercase+space, `'n'` alnum+space,
`'F'`/`'f'`/`'P'`/`'p'` filename/path chars, `'X'` anything, `'x'`
anything-uppercased — because the classic set is small, well documented,
and future m68k apps expect it. Template literals (e.g. the `:` in
`__:__`) are skipped over automatically.

Justification for *not* being fully faithful: our `OBJECT.ob_spec` is
already a host-width pointer (not the ST 32-bit long), so binary layout
compatibility is off the table anyway — the m68k binding layer will
marshal either way. Semantics-compatibility is what we keep.

**`objc_edit` — editing for bare `evnt_multi` clients.** The edit engine
is public, exactly the classic entry points, so a GApplication app that
runs its own event loop gets the same behaviour `form_do` has:

```c
enum { ED_START=0, ED_INIT=1, ED_CHAR=2, ED_END=3 };
int objc_edit(OBJECT *tree, int obj, int key, int *idx, int kind);
// ED_INIT: focus + caret on (idx -> caret pos, -1 = end)
// ED_CHAR: process one aes_event key (insert/Backspace/Del/arrows/Ctrl-U clear);
//          returns 1 if consumed; redraws + aes_flush_rect's the field
// ED_END:  caret off
int form_keybd(OBJECT *tree, int edobj, int key, int kstate,
               int *new_edobj);   // the full form key policy (Return/Esc/TAB/
                                  // mnemonic/ED_CHAR) as one call; returns the
                                  // exit object or -1 (keep going)
```

`form_do` becomes a thin loop over `form_keybd` + the existing button
logic; an `evnt_multi` client calls `form_keybd` from its `MU_KEYBD` arm
and `objc_draw` from its redraw. Caret is static in v1 (blink = a later
`aes_set_idle` client; every caret repaint is a tiny `aes_flush_rect`).

`form_do(tree, start)`'s ignored `start` becomes the classic meaning:
initial edit object (`0` = first editable, `-1` = none).

## Menus (req 5)

### Per-app menu bars

`menu_bar` keeps its signature but registers the bar **for the calling
app**; the AES shows the bar of whichever app owns the top window:

```c
void menu_bar(OBJECT *tree, int show);       // registers/clears ap_id's bar
int  wind_create_for(int ap_id, int kind, int x,int y,int w,int h);
// wind_create keeps working: owner = current app (0 today)
```

Topping a window whose owner differs swaps the visible bar and repaints
the strip (`aes_reserve_top` height is constant, so no window reflow).
Single-app today this is a no-op refactor — but the API stops assuming
the desktop is the only client, which is the requirement.

`MN_SELECTED` grows: msg[3]=title obj, msg[4]=item obj (as today),
**msg[5]=menu tree id**, **msg[6]=kbshift** at pick time. This is a
deliberate deviation from AES 3.30's msg[5..6]=tree *address* +
msg[7]=parent object: raw pointers can't cross the doorbell, so trees get
small registration handles; the m68k binding layer can synthesise the
classic words if a ported app ever needs them.

### Menu content upgrades

`menu_def` items grow structure (menu_build today takes bare strings):

```c
typedef struct { const char *text;      // "---" = separator (disabled rule)
                 uint8_t     accel;     // 0 or 'Q' -> Ctrl+Q, drawn right-aligned
                 uint8_t     flags;     // MDF_DISABLED | MDF_CHECKED
} menu_item;
typedef struct { const char *title; const menu_item *items; int nitems; } menu_def;
```

Accelerators are matched inside `evnt_multi` *before* `MU_KEYBD`
delivery: `Ctrl+letter` that matches the **topped app's** bar posts
`MN_SELECTED` instead. Structured accel beats XaAES-style text parsing —
we own `menu_build`, and parsing display strings is how encodings rot.

The pull-down/save-under path gains the missing `aes_flush_rect` calls
(today the open menu never reaches the A9 plane) and calls the idle hook.

### Popup menus

Two layers, matching how the ecosystem split (AES `menu_popup` vs MagiC
`form_popup`):

```c
// run-a-popup: modal, save-under, returns picked index or -1
int menu_popup(const menu_item *items, int n, int x, int y);
```

(The classic `menu_popup(MENU*, x, y, MENU*)` shape is deliberately not
copied — `MENU`'s tree/scroll plumbing serves resource-file popups we
don't have; the m68k binding can wrap ours under the classic name.)

`form_do` wires `G_POPUP` objects to it: `ob_spec` becomes
`POPUPINFO { const menu_item *items; int nitems; int sel; }`; a click on
the object runs `menu_popup` at the object's rect, stores `sel`, redraws
the field with the picked text. That gives dialogs combo-boxes (the
Add-Server transport `udp/tcp/auto` picker) for free.

## Drag & drop (req 4)

A general AES mechanism — the desktop is just the first client. In-process
today; every hand-off is shaped as an AES message so the future multi-app
world keeps the protocol and only swaps the payload transport.

### Message flow

```c
// -- source side ----------------------------------------------------------
typedef struct {
    char type[5];            // "PATH" (VFS path list) | "ARGS" (command tail)
    const char *data;        // NUL-separated paths, double-NUL terminated
    int  len;
    const gfx_surface *icon; // drag feedback image (may be NULL)
} dnd_payload;
int dnd_drag(const dnd_payload *p, int mx, int my);  // runs the modal drag;
                                                     // returns 1 delivered / 0 cancelled
// -- target side (arrives via evnt_mesag) ----------------------------------
// Word layout mirrors AP_DRAGDROP(63) exactly, except msg[7] carries a
// payload id instead of a pipe-name suffix:
enum { WM_DROPPED = 40 };    // msg[3]=window handle (0 = desktop),
                             // msg[4]=drop x, msg[5]=drop y,
                             // msg[6]=kbshift at drop, msg[7]=payload id
int dnd_payload_read(int id, dnd_payload *out);      // valid until next drag
```

1. **Source**: button-down on an icon + motion past a 4-px slop starts the
   drag (`desk_click`/`br_click` grow a slop check before their
   double-click wait). The source builds a `dnd_payload` — a browser entry
   drags its **VFS path** (`/Media/6502/Games/foo.xex`, or the
   `/Network/<server>/…` path for net entries), a desktop icon drags its
   own row reference.
2. **AES drag loop** (`dnd_drag`): cursor carries the ghosted icon — A9:
   the DRAG_BASE overlay plane (same machinery as window drag, a ~48×48
   rect); host: redraw-per-motion + `aes_flush_rect`. The loop calls the
   idle hook. Esc cancels.
3. **Drop**: `wind_find(mx,my)` resolves the target window (0 = desktop);
   the AES posts `WM_DROPPED` to the owning app's queue and parks the
   payload. The in-process desktop reads it from its `MU_MESAG` arm —
   the identical code a doorbell app will run.

Rejected: the MiNT pipe handshake (DD_OK/DD_NAK over `U:\PIPE\DRAGDROP`).
It exists to stream arbitrary bytes between two *processes*; our payloads
are paths, the AES is one process, and the doorbell ABI is array-based.
The `"PATH"/"ARGS"` type vocabulary is kept so a MiNT-style extension
negotiation can be added later without changing the message.

### Modifier semantics

Read from `msg[6]` (kbshift at drop) by the **target**:

| Modifier | Drop in folder window | Drop on desktop background |
|----------|----------------------|-----------------------------|
| none | move within volume, copy across volumes | **link** (home the icon) |
| Ctrl | copy | link |
| Shift | move | link |
| Ctrl+Shift | link — *rejected in v1: no symlinks in the VFS/FAT* | link |

- **Drop on the desktop = home a link, always.** The desktop has no
  backing directory; a homed icon is a *reference*, like a Mac alias.
  Copy/move onto the desktop background is meaningless and refused
  (alert). This sidesteps inventing a `/Desktop` folder.
- **Drop on an executable icon** (a `desktopIcons` row or browser entry
  whose type is launchable): run it with the dropped file as first
  argument — resolves through the same `desk_launch` path as a
  double-click, payload appended (`RUN prog.xex file.dat`).
- **Drop on an open emulator window**: insert/boot the media (D1:/CART by
  extension) — a natural follow-up, listed in the plan, not v1.

### Link representation: the registry

Homed icons are `desktopIcons` rows. The table grows:

```sql
ALTER TABLE desktopIcons ADD COLUMN target TEXT;      -- VFS path ('' = none)
ALTER TABLE desktopIcons ADD COLUMN mediaType INT;    -- launch class (ICT_*)
```

Double-click on a homed icon = `desk_launch(target, mediaType)`. The icon
bitmap resolves through the existing `windowIcons` glob rules at home
time, `displayName` = the filename.

**Write path**: the desktop currently opens the registry read-only and
fujinetd owns all writes. `desktopIcons` is the desktop's own table — the
desktop opens the DB read-write and becomes the single writer *for its
tables* (fujinetd keeps `fujinet`/`fujiCache`); SQLite's locking covers
the cross-process case. (Flagged as an open question — routing through a
daemon command is the alternative.)

**FujiNet ghosts as drag sources**: dragging an uncached (ghosted) entry
drags its `/Network/<server>/…` path.

- Homed on the desktop → a link whose double-click is fetch-then-launch —
  exactly the ghost double-click semantics, already async via `net_pump`.
- Copied into a folder window → the target issues a daemon `fetch` with a
  destination override; progress lands in the target window's info bar
  like any fetch. Move is refused (the remote is read-only in v1).
- A homed network link's icon should show cache state (solid/ghost); v1
  draws it solid and re-checks on launch — badge-on-refresh is listed
  under open questions.

## Event-loop integration summary

- **`form_do` clients** (desktops' dialogs, `form_alert`): get movability,
  mnemonics, Return/Esc, TAB and editing with **no call-site changes**
  beyond providing TEDINFOs and (optionally) `OF_CANCEL`/`OF_MOVEABLE`.
- **Bare `evnt_multi` clients** (GApplication apps, windowed tools): use
  `form_keybd`/`objc_edit` from their `MU_KEYBD` arm, receive
  `MN_SELECTED` (bar + popup) and `WM_DROPPED` from `MU_MESAG`, and call
  `dnd_drag` to be a source. Nothing modal is forced on them except the
  drag loop itself.
- **net_pump**: registered once via `aes_set_idle(net_pump, 40)`; every
  modal AES loop (forms, menus, drags) keeps async I/O alive. The
  desktops' main loops keep their explicit `pend?40:0` tick (belt and
  braces, zero cost).

## A9 specifics

- **`struct os_event` already carries `shift`** (`loader/kernel/xtsys.h`)
  — the syscall ABI needs no change, only the kernel input layer filling
  it (HID) and the two desktops copying it through (they already do).
- **Terminal-decoder degradation** (`sprite.c`): arrows move the pointer
  and `Tab` *is* a click, so TAB-focus and arrow-editing are unavailable
  on the serial testbed — click-to-focus and plain-letter mnemonics still
  work, and `Ctrl+letter` arrives as control chars (mapped to `K_CTRL` +
  letter). Modifier-based drop semantics degrade to the no-modifier
  column (move/copy-by-volume, desktop=link) — acceptable: the testbed is
  a debug surface; real HID lands scancodes + modifiers.
- **HW cursor during drags**: the pointer sprite stays kernel-side; the
  dragged icon rides the **DRAG_BASE overlay plane** (`SYS_overlay`), the
  same lift/move/drop ops as window drag — tear-free, no per-motion
  repaint. Window drag and icon drag can't overlap (both are modal), so
  sharing the single overlay plane is safe.
- **`aes_flush_rect` discipline**: every new modal draw — open menus,
  popups, dialog moves, caret updates, drag feedback on hosts without the
  overlay — must flush its rect. Keep rects tight: a full-plane present
  starves the compositor (the HDMI-drop lesson in `aesdesk.c
  present_rect`). Caret = one glyph cell; menu = the dropdown box.

## Staged implementation plan

### Stage 1 — forms (unblocks the FujiNet Add-Server dialog)

Movable dialogs + mnemonics + Return/Esc + editable fields + TAB order.

| Files | Change | ~Size |
|-------|--------|-------|
| `gem/aes/aes.h` | TEDINFO, `OF_CANCEL/OF_MOVEABLE/OS_WHITEBAK`, ED_*, XK_*/K_* codes, `objc_edit`/`form_keybd`/`form_do_dialog`/`aes_set_idle` | +60 |
| `gem/aes/form.c` | move/save-under unification, key policy (`form_keybd`), focus/TAB, mnemonic auto-assign, idle hook | +220 |
| `gem/aes/edit.c` (new) | `objc_edit`: caret, insert/delete, template skip, pvalid | ~200 |
| `gem/aes/object.c` | `G_FTEXT` themed render + caret + mnemonic underline | +80 |
| `gem/aes/event.c` | `aes_set_idle`, kstate pass-through | +25 |
| `gem/xtdesk.c` | SDL modifiers + key mapping; **Add Server… dialog** (host+name+port G_FTEXT, transport G_POPUP stub as radio for now, OK/Cancel) driving daemon `add-server` | +150 |
| `progs/aesdesk.c` | same dialog (kept line-parallel); pass `oe.shift` | +150 |

Testability: extend the headless pattern — a scripted event source
(`aes_set_events` fed from a canned `aes_event[]`) drives `form_do`
end-to-end with **no SDL**; `--dialog` renders the Add-Server dialog to
PPM (`--ppm` idiom) for visual regression; typed-text assertions check
the TEDINFO buffer after replay.

### Stage 2 — menus

| Files | Change | ~Size |
|-------|--------|-------|
| `gem/aes/menu.c` | `menu_item` flags/accel/separators, per-app bar table + swap-on-top, `menu_popup`, accel match in `evnt_multi`, `aes_flush_rect` + idle in the pulldown | +250 |
| `gem/aes/window.c` | window owner ap_id, bar swap on raise | +30 |
| `gem/aes/form.c` | `G_POPUP` → `menu_popup` wiring (`POPUPINFO`) | +40 |
| desktops ×2 | adopt a real bar (File/View/Network…), replace the transport radio in Add-Server with the popup | +80 each |

Testability: `menu_render_open` already exists for screenshot tests;
add `--menu`/`--popup` PPM modes; MN_SELECTED asserted via scripted
replay (click bar → move → release on item → drain message queue).

### Stage 3 — drag & drop

| Files | Change | ~Size |
|-------|--------|-------|
| `gem/aes/dnd.c` (new) | `dnd_drag` loop (host redraw + A9 overlay), payload park, target resolve, `WM_DROPPED` post | ~250 |
| `gem/aes/aes.h` | `dnd_payload`, `WM_DROPPED` | +25 |
| `gem/registry.c/h` | read-write open, `registry_home_icon()` insert/update/delete, schema migration | +80 |
| desktops ×2 | drag sources in `desk_click`/`br_click` (slop check), desktop drop target (home link), browser drop target (copy/move + ghost fetch), exec-target launch, icon reload | +200 each |

Testability: scripted replay drags (down-motion-up sequences) headlessly;
assert the `desktopIcons` row via the `sqlite3` CLI; PPM snapshot of the
homed icon; ghost-source case against `mock_tnfsd.py` + fujinetd.

Follow-ups (post-stage-3): drop-on-emulator-window media insert, windowed
dialogs for multi-app, cache-state badges on network links, caret blink.

## Open questions (for the owner)

1. **Esc in a focused edit field**: classic GEM Esc *clears the field*
   (universally implemented, though no primary spec sentence survives —
   MagiC's key table only implies it); this design makes Esc always
   cancel-the-dialog (field clear = Ctrl-U). OK, or
   Esc-clears-field-first, second Esc cancels?
2. **Desktop drop = link only**: copy/move onto the desktop background is
   refused (no backing directory). Acceptable, or do you want a real
   `/Desktop` folder so plain drops materialise files?
3. **Registry writes from the desktop**: open read-write and own
   `desktopIcons` directly (proposed), or route homing through a daemon
   command in the fujinetd style?
4. **Auto-assigned mnemonics** (req 2 "as basic functionality"): letters
   are picked automatically on dialog entry when the app didn't mark one —
   assignments can shift as labels change. Fine, or app-declared only?
5. **Menu accelerators**: structured `accel` field (proposed) means future
   m68k apps' text-embedded `"^Q"` conventions need translation in the
   binding layer. Acceptable?
6. **A9 modifiers**: is STM HID keyboard delivery (scancodes + modifier
   state) scheduled? Until then the terminal testbed can't express
   Ctrl/Shift drops — is the no-modifier fallback column enough?
7. **Ghost links' cache-state display**: homed network links draw solid in
   v1 and re-check at launch. Is a lazy state badge (daemon `stat` on
   desktop redraw) worth stage-3 scope?
