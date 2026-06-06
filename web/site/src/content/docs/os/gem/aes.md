---
title: "AES reference"
description: "The GEM AES layer — the OBJECT tree, form_do / form_alert, the evnt_multi multiplexer and message pipe, menus, and themed windows."
---

The AES (Application Environment Services) is the layer above the [VDI](/os/gem/vdi/): objects,
dialogs, events, menus and windows. It is event-driven by a single host source, and every
widget is drawn through the [theme](/os/gem/theme/) — the AES itself never touches pixels.

## The OBJECT tree

Dialogs, forms and menus are described as a tree of `OBJECT`s, the classic GEM layout:

```c
typedef struct {
    int16_t  ob_next, ob_head, ob_tail;   // sibling, first child, last child (-1 = none)
    uint16_t ob_type;                      // G_*
    uint16_t ob_flags;                     // OF_*
    uint16_t ob_state;                     // OS_*
    void    *ob_spec;                      // type-specific (G_STRING / G_BUTTON: char *)
    int16_t  ob_x, ob_y, ob_w, ob_h;       // relative to the parent
} OBJECT;
```

Children hang off `ob_head`…`ob_tail`; the last child's `ob_next` points back to the parent.
Coordinates are relative to the parent (the root's are absolute).

- **Types** — `G_BOX`, `G_IBOX`, `G_BOXTEXT`, `G_STRING`, `G_TEXT`, `G_FTEXT`, `G_TITLE`,
  `G_BUTTON`, `G_IMAGE` (drawn as a theme element). Themed extensions: `G_CHECKBOX`, `G_RADIO`,
  `G_POPUP`, `G_FIELD`.
- **Flags** — `OF_SELECTABLE`, `OF_DEFAULT`, `OF_EXIT`, `OF_EDITABLE`, `OF_RBUTTON`,
  `OF_LASTOB`, `OF_TOUCHEXIT`, `OF_HIDETREE`.
- **States** — `OS_SELECTED`, `OS_CROSSED`, `OS_CHECKED`, `OS_DISABLED`, `OS_OUTLINED`,
  `OS_SHADOWED`.

| Call | Notes |
|------|-------|
| `objc_draw(tree, start, depth, …)` | render a tree (each object → a theme element or VDI primitive), clipped |
| `objc_find(tree, start, depth, x, y)` | topmost object under a point |
| `objc_offset(tree, obj, &x, &y)` | absolute position of an object |

## Forms

| Call | Notes |
|------|-------|
| `form_do(tree, start)` | run a modal form: push buttons flash while held and trigger on release; checkboxes toggle; radio buttons exclude their siblings; Return fires the `OF_DEFAULT` button. Returns the EXIT object clicked |
| `form_alert(default, "[icon][msg|lines][btn1|btn2|btn3]")` | a canned alert: parses the GEM alert string (icon 0–3 = none / note / wait / stop), centres + runs the dialog, returns the 1-based button. Icons are themed |

## Events

The AES is driven by one host source, `aes_wait(ev, timeout)`: it presents the current frame,
then blocks (up to a timeout) for the next input — on the host that is present +
`SDL_WaitEventTimeout`; on hardware it is the event pump over the [VDI input layer](/os/gem/vdi/#input).

| Call | Notes |
|------|-------|
| `evnt_multi(flags, …)` | wait on keyboard / button / mouse-rectangle / message / timer at once; returns the `MU_*` that fired with the live pointer/key state |
| `evnt_keybd` | wait for a key |
| `evnt_button(clicks, mask, state, …)` | wait for a button state |
| `evnt_mouse(leave, x, y, w, h, …)` | wait for the pointer to enter / leave a rectangle |
| `evnt_mesag(buf)` | wait for a message |
| `evnt_timer(lo, hi)` | wait for a timer |

### Message pipe

Menus and windows post messages an application reads with `evnt_mesag` / `evnt_multi`.

| Call | Notes |
|------|-------|
| `appl_init` | initialise; returns an application id |
| `appl_write(dest, len, msg)` | post a message |
| `appl_read(id, len, buf)` | read a queued message |
| `appl_exit` | shut down |

## Menus

A menu is a GEM `OBJECT` tree (a bar of `G_TITLE`s plus one dropdown `G_BOX` of `G_STRING`
items per title). `menu_build` assembles one from a simple description.

| Call | Notes |
|------|-------|
| `menu_build(menus, n, screen_w)` | assemble a menu tree from a `{title, items[]}` description |
| `menu_bar(tree, show)` | show / erase the active menu bar (drawn above every window) |
| `menu_tnormal(tree, title, normal)` | (un)highlight a title |
| `menu_icheck(tree, item, check)` | tick / untick an item |
| `menu_ienable(tree, item, enable)` | enable / disable an item |

A click in the bar is caught inside `evnt_multi`: it runs the pull-down (themed, with item
highlighting and drag-to-switch), then posts an **`MN_SELECTED`** message — so the application
just receives the selection (`msg[3]` = title object, `msg[4]` = item object).

## Windows

Themed windows: the AES draws the frame (9-slice window + titlebar + traffic-light gadgets per
the kind flags), and the application draws the work area through a content callback and reacts
to `WM_*` messages.

| Call | Notes |
|------|-------|
| `wind_create(kind, x, y, w, h)` | create a window; returns a handle |
| `wind_open` / `wind_close` / `wind_delete` | open / close / destroy |
| `wind_set_name(handle, name)` | set the title |
| `wind_get(handle, field, …)` / `wind_set(handle, field, …)` | query / set (work area, current rect, …); `wind_get(0, WF_WORKXYWH)` reports the desktop work area |
| `wind_calc(dir, kind, …)` | convert between work area and full (bordered) area |
| `wind_find(x, y)` | the topmost window at a point |
| `wind_content(handle, fn, ud)` | set the work-area draw callback |

**Kind gadgets** — `W_NAME`, `W_CLOSER`, `W_FULLER`, `W_MOVER`, `W_SIZER`, plus the slider /
arrow gadgets. Frame interaction is caught inside `evnt_multi`: raise-on-click
(`WM_TOPPED`), live title drag (`WM_MOVED`), corner resize (`WM_SIZED`), and the close box
(`WM_CLOSED`) — all posted to the message pipe.

A window can never be dragged out of reach: the AES clamps the title bar to the desktop work
area. The work area defaults to the screen minus the menu bar, and the desktop can reserve more
(`aes_set_workarea`) for a dock or sidebar.
