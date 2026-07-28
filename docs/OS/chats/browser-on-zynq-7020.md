# A browser on the Zynq-7020 — conversation digest

Source: Google AI Mode chat, 2026-07-28, 21:25–23:14.
Opening question: *"How feasible is it to get an HTML renderer and JavaScript engine
running as a web browser on a small-footprint machine like a Zynq 7020 with 512MB of
user RAM?"*

The conversation is a progressive reveal: each time the real shape of XTOS is
disclosed, the answer gets more optimistic. It starts at "only if you're careful"
and ends at "this will be fast."

---

## The arc in one paragraph

The assistant's first answer assumed embedded Linux and warned off Chromium/Gecko
(1–2GB minimum, instant OOM). Once it learned there's no Linux — 512MB is *net*
of OS and framebuffer, on a heavily-extended FreeRTOS with an MMU, VFS, dynamic
linking and BSD sockets — memory stopped being the constraint at all, and the
question became *which portable engine to bolt on*. The recommendation converged
on **NetSurf's library stack** (Hubbub parser + libdom + LibCSS) for arbitrary
HTML, with **QuickJS** for JavaScript, driven from an **Operation/OperationQueue**
concurrency model, rendered through the existing GEM virtual-workstation and
hardware blitter.

---

## Turn by turn

### 1. The opening frame — "avoid desktop engines"

Assistant's initial matrix, assuming Linux:

| Class | Examples | RAM | Verdict |
|---|---|---|---|
| Desktop | Chromium, WebKitGTK, Firefox | 1–2GB+ | Impossible |
| Embedded HTML5 | Ultralight, Ekioh Flow | 32–128MB | Feasible (commercial) |
| Lightweight OSS | NetSurf, Luakit | 30–100MB | Feasible |
| JS only | QuickJS, JerryScript | 1–5MB | Feasible (headless) |

Plus the standing hardware caveats: dual Cortex-A9, ARMv7, no hardened GPU —
so rasterisation is CPU or FPGA, nothing in between.

### 2. "It's not Linux, and the 512MB is *after* OS and framebuffer"

This reframes everything. Memory capacity ceases to be the bottleneck; the
challenges become OS abstractions (threads, mutexes, allocation) and software
rasterisation. Three candidate stacks offered:

- **QuickJS + litehtml** — pure C/C++, zero OS dependencies, <30MB. litehtml
  doesn't touch pixels; it emits draw commands to a `document_container` you
  implement.
- **Sciter.JS** — proprietary, HTML/CSS/JS already coupled, ~30–50MB, commercial
  licence for RTOS porting.
- **JerryScript + IoT.js** — for sub-512KB targets; more manual DOM work.

### 3. "We have a Linux-lite: /proc, /dev, MMU, GEM, shared-memory windows, gemd"

With `/dev/blitter` doing stretched/bilinear block ops, the assistant's assessment
sharpens: this is an ultra-lean POSIX environment, and the blitter removes the
single biggest embedded-browser pitfall (software image stretching). The proposal
becomes litehtml mapped onto GEM surfaces:

- `draw_background` → the shared-memory window surface; stretches go to `/dev/blitter`
- `draw_text` → bundle `stb_truetype`, write glyphs into the GEM surface
- `import_page` → `open()`/`read()` through the VFS

Caveat noted: no kernel threads yet, so a cooperative single-threaded loop with a
`usleep(16000)` yield.

### 4. "TrueType is already there; images are pre-rasterised RGBA32. Should I do threads first?"

**Verdict: yes, threads first.** Three reasons given:

1. **Non-blocking fetch** — a single-threaded loop freezes the whole renderer on
   any `read()` or socket call.
2. **GC and long scripts** — an intensive JS loop starves the render loop if they
   share a thread.
3. **Cleaner event routing** — separates input handling from layout and painting.

Proposed split: UI thread owns litehtml, fonts, blitter calls and the GEM surface;
worker thread owns QuickJS, VFS I/O and networking; they communicate via a
thread-safe message queue.

### 5. "It's FreeRTOS, much extended — VM, shared objects, dynamic linking, BSD sockets via syscalls"

Called an "optimised microkernel architecture." Key points:

- QuickJS spins no threads internally — a `JSRuntime` is an isolated instance,
  so it drops cleanly into its own FreeRTOS task.
- `std::mutex` → `xSemaphoreCreateMutex`; `std::condition_variable` → `xQueueCreate`
  or task notifications.
- Dynamic linking pays off: `liblitehtml.so` / `libquickjs.so` share one text
  segment across every tab, window and app.

**The real hurdle identified: DOM glue.** litehtml builds a C++ tree; QuickJS runs
JavaScript; neither knows the other exists. `document.getElementById(...)` throws
because `document` is undefined. Two paths:

- **A: manual C++ hooks** — fine for a fixed/kiosk UI.
- **B: use an existing glue project** — Ultralight (proprietary), or NetSurf's
  libdom + Hubbub, which already carry JS execution abstractions.

### 6. "I want arbitrary HTML, so libdom. Networking does TLS."

> **Correction — the TLS claim is not true.** Verified against the tree afterwards:
> there is no TLS anywhere. See "Secure networking: the premise doesn't hold" below.
> Everything the assistant says from here on about fetching live pages over HTTPS
> rests on a capability that does not exist yet.

This is the pivot point. NetSurf's component breakdown:

| Library | Role |
|---|---|
| **Hubbub** | HTML5 parser — streams socket buffers into a DOM token stream |
| **libdom** | Live tree, W3C DOM bindings that JS hooks into |
| **LibCSS** | CSS3 parse, cascade, computed dimensions |
| **NSJS** | The binding layer gluing libdom to a JS engine |

Integration is via NetSurf's frontend driver interface — you write a "GEM frontend"
overriding their wrappers. Fonts map to `font_width` / `font_position` / `font_paint`.
Hubbub tokenises the network stream chunk-by-chunk, so the full raw HTML never has
to sit in RAM. Estimate: 40–60MB resident for arbitrary pages.

### 7. "Everything's message-queue driven, more AppKit than evnt_multi. Apps never touch the framebuffer."

Called "an absolute dream architecture" — it mirrors how macOS and Windows do
high-performance browser rendering. NetSurf decouples drawing via an `nsplot_cb`
callback struct, which maps onto a two-phase Invalidation → Deferred Redraw model:

1. JS/DOM change triggers layout
2. NetSurf computes altered bounds
3. App posts `APP_WINDOW_NEEDS_DISPLAY` with the rect onto its own queue
4. Event loop pops it, sets NetSurf's clipping rect, renders into private shared memory
5. `gemd_post_damage_rect()` — gemd blits only that region

Concurrency rule: the main thread exclusively owns the queue, the GEM surface, the
font system and the layout tree. Worker threads never touch the GEM buffer — they
post `APP_DOM_MODIFIED` messages back to main.

### 8. "Each window is a virtual workstation. The blitter is queued 1024-deep at ~800MB/s."

Perspective offered: a 1080p RGBA32 frame is ~8MB, so 800MB/s is ~100 full-HD
frames per second of pure blit bandwidth.

Two techniques fall out:

- **Zero-CPU scrolling** — blit the existing content block up/down *within the
  window's own backing store* (no IPC), then paint only the newly-exposed sliver.
- **Localised invalidation** — a spinning icon in a corner invalidates only its own
  box; the A9s spend zero cycles on unchanged pixels.

On memory isolation, the recommendation is explicit: **do not** put layout and JS
in separate processes. Every `document.body.children.length` would become a syscall,
IPC payload and context switch. Instead: **single process, shared heap, thread-level
concurrency**, with mutexes only around libdom mutation hooks.

### 9. "The blitter does alpha too — text is alpha-blits from an LRU RGBA32 glyph cache. And I have a self-hosting ARC language with Foundation; I'll add Operation/OperationQueue."

Characterised as "an optimised, low-overhead CoreGraphics + Grand Central Dispatch."

Text rendering becomes: layout queries metrics → `font_paint` loops glyphs → LRU
cache lookup → miss rasterises via TrueType → register an alpha-blit in the
1024-deep queue. The CPU only writes geometry into memory-mapped registers.

Queue topology proposed:

- **MainQueue** (high priority): input, libdom re-layout, blitter calls, damage posting
- **BackgroundQueue** (low): sockets, VFS I/O, QuickJS execution

Mutation flow: JS never locks the DOM. It builds a `DOMMutationOperation`, sets its
fields, and enqueues it on MainQueue. Main executes it, invalidates, repaints.
ARC handles the lifetimes across the hand-off. Core 0 runs MainQueue, Core 1 runs
background work.

### 10. "Course correction — xtc has no blocks. Bound functions (object + method as one type) have been sufficient."

Response: bound functions are **arguably cleaner and safer** here. No captured
scope means no hidden retain cycles — the classic block-based browser leak (block
captures the layout engine, engine owns the queue) becomes structurally impossible.

The pattern: an explicit *command object* holds all the state, and you bind its
method:

```
class ImagePlacementCommand {
    var domElement:   NodePtr
    var rawPixelData: ImageDataPtr
    func applyToDOM() { ... }
}
let op = Operation(targetAction: cmd.applyToDOM)
MainOperationQueue.shared().addOperation(op)
```

Bonus: deterministic debugging (you can count live `ImagePlacementCommand`s on the
heap) and trivial cancellation — dropping a pending operation cascades through ARC
and frees the wrapped buffers immediately.

### 11. "Generic containers mean a `params` dictionary gives latitude and future-proofing"

Endorsed as decoupling the queue from the browser entirely — `Operation` never needs
recompiling as the W3C spec moves. `typealias Params = Dictionary<String, AnyRef>`,
a bound function of type `(Params) -> Void`, and ARC drops every reference in the
envelope the moment the operation completes.

### 12. "We have a `value` object, autoboxing/unboxing, and try/catch/defer (used heavily in the compiler)"

Two payoffs identified:

- **Autoboxing** means damage rects and geometry go into `Params` as plain ints and
  come back out with near-zero overhead — no bespoke wrapper types.
- **`defer`** is the right tool for HTML/CSS parsers, which are deeply nested and
  state-heavy. Malformed markup or a dropped socket mid-parse unwinds cleanly, the
  layout lock always releases, and a fatal parse error shows an error page instead
  of taking down the platform.

### 13. "xtc can `#import` a shared object, read its DWARF symbols and types, and expose them. It targets A9, macOS, Linux x86_64 and Windows — and xg renders via Cocoa/Win32/GTK or GEM."

Called out as bypassing the most tedious phase of the whole port: **no hand-written
binding headers.** Compile libdom/libcss/hubbub with `-g` and xtc digests them
directly. And the xg cross-targeting means the browser's layout and operation logic
can be developed, debugged and profiled on the Mac before it ever touches the Zynq.

This turn also covered **JavaScript timers**. A `JSTimerDescriptor` ledger
(id, callback ref, target FreeRTOS tick, interval, cancelled flag) is polled by one
low-overhead background task sleeping ~10ms. On fire, it packages a `Params`
envelope and enqueues onto the background JS queue; if that callback mutates the
DOM, it dispatches a mutation operation back up to MainQueue.

### 14. "Wrapping library statics in a class and redirecting the bindings at load time"

Described as "loader-level virtualization" — it solves the oldest ugly problem in
C libraries (static global state defeating multiple instances) without forking the
upstream code.

> **Assessment.** Feasible, but with a caveat that inverts the difficulty: the
> technique works for the case you don't need it for, and fails for the case you do.
>
> It comes down to how the variable is reached. **Exported globals** in PIC go
> through the GOT, which the dynamic linker fills at load time — redirecting those
> is just interposition, and the hook already exists. **`static` file-scope
> variables** are the problem: the compiler knows they cannot be preempted, so on
> ARM it reaches them PC-relative or via a literal pool, *not* through the GOT.
> There is no indirection to patch. Redirecting them means locating every access
> site and rewriting instructions — and since PC-relative accesses frequently leave
> no relocation behind, that means disassembling to find them. Fragile. And
> "library statics" are, definitionally, mostly this second kind.
>
> **The better mechanism, given we own the loader: private instances.** This is
> glibc's `dlmopen(LM_ID_NEWLM)` — load a second, independent copy of the .so into
> its own link-map namespace, with its own data segment and relocations. Strictly
> more general than wrap-and-redirect:
>
> - handles `static`, exported globals and any other hidden state uniformly
> - zero per-library work — no bespoke wrapper per dependency
> - cheap: only data/BSS duplicates. Text is read-only PIC, so the same physical
>   pages map into both virtual ranges, exactly as two processes share libc text
>   today. The PC-relative text→data distance is identical in both mappings.
>
> A bounded addition to a linker we already wrote, and it pays off for freetype,
> libtomcrypt and anything else carrying hidden state.
>
> **Measure before building either.** `nm --defined-only` over the built
> libdom/libcss/hubbub objects, filtered for `b`/`B`/`d`/`D`, answers this in about
> a minute. Five symbols means hand-wrap and move on; two hundred means build the
> namespace loader.
>
> **And neither may be needed.** NetSurf is multi-window by design, so its
> libraries mostly thread context through explicit structs rather than globals —
> that is why `browser_window` is a parameter everywhere. The static problem may be
> far smaller than it looks.
>
> Failing that, there is a zero-engineering escape hatch that turn 17 already sets
> up: **process per window.** gemd does not care whether thirty windows come from
> one process or thirty, the .so text is shared across them regardless, and windows
> are genuinely independent so there is no IPC to pay for. It is also what every
> real browser does, for isolation. If libdom turns out to be static-riddled, that
> is the answer and it costs nothing.

Also here: the **flashing damage-rect debug overlay** idea was accepted. Render
dirty regions in neon green on the *host* (macOS/Linux via xg) and layout
inefficiencies become visible instantly — if a typing cursor flashes a 400×400 box,
you see it on a desktop monitor long before it reaches the FPGA.

### 15. "`#import <c>` found libc.so and then printf() just worked"

The input pipeline got mapped out. Mouse: gemd message → localise coordinates →
`Params` → MainQueue → `browser_window_mouse_click(nsWindow, state, x, y)`, called
directly through the DWARF-imported symbols. Keyboard: NetSurf tracks focus
internally, so it's `browser_window_key_press(handle, unicode)` and the glyph cache
does the rest.

### 16. "We already handle wheel events — CollectionView scrolls thousands of icons via delegate/datasource"

Recognised as the NSTableView/RecyclerView pattern. Applied to the browser, it
forks scrolling into two cases:

- **Heavy layouts** (sticky headers, `position: fixed`) — let NetSurf drive:
  `browser_window_scroll`, recompute intersections, repaint the dirty list.
- **Flat text/image pages** — bypass the engine: blit the viewport pixels up/down
  in the backing store, query NetSurf only for the newly-exposed sliver. CPU load
  near zero.

Focus switching separates cleanly into three layers: gemd restacks and posts
`APP_WINDOW_DID_BECOME_KEY`; the app repaints its border; libdom gets
`browser_window_set_focused` and revives the text cursor.

### 17. "Apps can have many windows; gemd handles one window per process or thirty"

Memory scaling for 30 windows:

- **Code segments**: loaded once — 30 windows don't multiply engine cost
- **Glyph pool**: one shared cache regardless of window count
- **Per-window linear cost**: layout tree + frame buffer. 1024×768 RGBA32 = 3.1MB,
  so 30 windows ≈ 93MB of surfaces, leaving 350MB+ for DOM trees and JS heaps

And retained mode means occluded windows cost nothing: a background window paints
into its private surface and posts damage; gemd sees the region is occluded and
discards the blit. The framebuffer is never touched.

### 18. "The glyph pool is system-wide — 64MB outside user-process space. Three rules define the UI."

The three constraints, restated:

1. **gemd owns screen state** — window hierarchy and framebuffer, but knows nothing
   about drawing
2. **The app owns pixel composition** — knows how to draw, but has no framebuffer
   access, so a rogue write can't tear or corrupt the screen
3. **Every window is a virtual workstation** — an isolated (0,0) origin space where
   every GEM operation written for the screen works unchanged

Consequences: NetSurf draws at (10, 10) with no idea where the window sits or what
occludes it. A runaway script can only corrupt its own backing store. Any app that
has already rasterised a glyph at that size has warmed the cache for everyone.

Two capabilities this unlocks: hardware CSS transform-scales (stretch-blit the
pre-rendered block instead of rebuilding the layout tree), and instant live
thumbnails of all 30 windows (downscale 30 retained surfaces into a grid without
waking a single browser process).

### 19. "Bitmap-based virtual workstations already exist — it's just a context and pointers. And the blitter does affine + bilinear together."

RGBA32-only across the whole OS is called out as eliminating the colour-space
conversion overhead that bogs down embedded graphics stacks.

**CSS animation** becomes parameterised blits: the queue handles timer ticks,
computes the updated matrix, and passes source pointer + destination + transform to
`/dev/blitter`. Bilinear interpolation happens in fabric, so scaling stays smooth.

**HTML5 `<canvas>`** maps perfectly onto the existing primitive: `getContext('2d')`
spawns a bitmap virtual workstation at the canvas dimensions; `fillRect`/`drawImage`
map to standard GEM calls; the finished canvas alpha-blits into the page layout.

Also suggested: page transitions (render the new page in a hidden window, then have
gemd slide/fade between them), and drop-shadows/rounded corners as alpha-composited
RGBA32 masks.

### 20. "OperationQueue shouldn't be slaved to display timing — many operations retire per display cycle"

Agreed, and called a major bottleneck if done otherwise. A browser retires hundreds
of non-visual operations (parsing, JS compile, microtasks, DOM mutation) inside one
16.6ms frame; gating the queue on a display tick starves logic throughput.

The **deferred display synchronisation** model:

1. **Accumulate** — operations mutate state and append to a local dirty list. No
   syscalls, no blitter commands. Just bounding boxes in memory.
2. **Trigger** — an `APP_DISPLAY_SYNC_TICK` message arrives. If the dirty flag is
   false, discard it with zero overhead. If true, consolidate the rects, submit the
   blits in one burst, reset the flag, post damage to gemd.

Plus **frame-skip resilience**: expose blitter queue depth as a status register.
Before dumping a large animation batch, read the depth; if the hardware is falling
behind, skip the render phase for that frame while JS timers keep advancing. Input
and scrolling stay responsive under graphical load.

On USB touch: no structural rewrite needed. A touch driver just posts
`APP_MOUSE_DOWN`/`APP_MOUSE_DRAG` into the existing queue, and nothing downstream
knows or cares whether the events came from glass or a mouse.

---

## The stack, as landed

```
Language      xtc — ARC, classes, Foundation, autoboxing, try/catch/defer,
              bound functions, DWARF #import of foreign .so, self-hosting on A9
Concurrency   Operation / OperationQueue, generic Params dictionary payloads,
              MainQueue (high) + BackgroundQueue (low), shared process heap
OS            FreeRTOS + VM, dynamic linking, VFS, BSD sockets (plaintext only —
              no TLS yet), signals
Graphics      gemd retained compositor, per-window virtual workstations, RGBA32
              only, 64MB system-wide LRU glyph cache, 1024-deep ~800MB/s blitter
              with alpha, affine transforms and bilinear filtering
Browser       Hubbub (HTML5 parse) + libdom (DOM) + LibCSS (cascade) + QuickJS (JS)
Estimate      40–60MB resident for arbitrary pages
```

---

## Reality check

The assistant is enthusiastic to a fault — it opens most turns by praising the
architecture, and its numbers are estimates rather than measurements. Three things
worth flagging before any of this becomes a plan:

**The DOM-binding work is understated.** It correctly identifies glue as the main
hurdle in turn 5, then treats picking libdom as having solved it. NetSurf's JS
support is real but partial; NSJS was built around Duktape, and how much of the
modern DOM surface arbitrary sites actually need is an open question. "Renders
arbitrary HTML" and "runs arbitrary sites' JavaScript" are very different bars.

**The 40–60MB figure is for layout, not content.** Decoded images, JS heaps and
the DOM for a heavy modern page dwarf the engine footprint. 512MB is comfortable,
but "memory is a non-issue" is too strong.

**A9 single-thread performance is the thing not discussed.** The blitter genuinely
removes the pixel-pushing bottleneck — that part is sound. But CSS cascade
computation, HTML parsing and JS execution are all serial CPU work on a
~667MHz-class ARMv7 core, and no amount of blit bandwidth helps there. That, not
RAM and not rasterisation, is where a heavy page will actually stall.

Some of the architectural advice is sound regardless: single-process shared heap,
decoupled display sync, bypassing the engine for flat scrolling. Those are the
right calls. The concurrency model it proposes is not — see below.

---

## Threading-first: right conclusion, wrong reasons

The chat's turn-4 verdict ("implement threads before the browser") is correct, but
every argument it gives for it is weak, and two describe an architecture no browser
actually uses.

### Why its three reasons don't hold

**"Single-threaded fetch freezes the renderer."** NetSurf is single-threaded *by
design*. It targets RISC OS, AmigaOS and Atari — it has a `schedule()` callback and
non-blocking fetch precisely so it never needs threads. libdom, libcss and hubbub
carry no internal locking because they assume none is needed. The proposed "QuickJS
on a worker thread, mutex the libdom mutation hooks" would bolt concurrency onto a
codebase with no concept of it — and locking *mutation* isn't sufficient anyway,
because layout reads traverse the same tree, refcounts and listener lists.

**"Put QuickJS on its own thread so long scripts don't starve the UI."** No browser
does this. Blink moves compositing and raster off-main; script and DOM stay on the
main thread. That is forced by the spec, not legacy: `offsetWidth` and
`getBoundingClientRect` are synchronous layout queries — script demands a value and
layout must complete mid-script. Cross-thread, that is a round-trip and a stall on
every access, and frameworks hit those constantly. The MainQueue/BackgroundQueue
split in turn 9 breaks on the first `getBoundingClientRect()`.

**"Unresponsive scripts need a separate thread."** QuickJS has an interrupt handler
— it calls you periodically during execution and you can bail. That is the
responsiveness answer, single-threaded.

For the browser specifically, threadless is more viable than the chat allows.

### The actual reason to do threads first

Threading is not a kernel feature to be added later. It is a set of decisions that
propagate into codegen and the syscall ABI:

- **Is ARC refcounting atomic?** The decisive one. If retain/release are plain
  increments today, making them atomic later changes codegen for every object
  operation in the system, and the performance profile with it — LDREX/STREX versus
  a plain add on ARMv7. This cannot be A/B'd after the fact; it is a
  recompile-the-world change.
- **`errno`** — needs TLS, which needs a register convention and loader support for
  a TLS section.
- **malloc** — the intra-process heap almost certainly assumes a single mutator.
- **Signals** — which thread receives one? That answer is ABI-visible.
- **Lazy binding in the dynamic linker** — reentrant?
- **Foundation collections** — which are safe, and is that documented or accidental?

Each is cheap now and expensive once Foundation, xg, aesdesk and a browser have all
shipped against the threadless answer. The browser is merely what surfaced the
question.

On ARC: make it atomic unconditionally, measure, and only then consider the
Swift-style "non-atomic until it escapes" optimisation. Uncontended LDREX/STREX on
A9 is not free but it is not a cliff, and the alternative is a far subtler compiler.

### The bootstrap wrinkle

Changing retain/release codegen while xtc is self-hosting is a bootstrap event. The
stage-1 compiler, built with non-atomic ARC, compiles a stage-2 compiler that emits
atomic ARC; stage-2 then compiles itself and must produce a bit-identical stage-3.
That is entirely standard, but it is much better to have the multi-stage build
discipline and the stage-2/stage-3 comparison already in place *before* making an
ABI-level codegen change, rather than discovering the need for it while debugging
one.

This is a small piece of work the language thread can land now, at no cost, that
de-risks the threading work later. It is also the point where the two currently
independent workstreams — XL emulation conformance on one side, xtc self-hosting on
the other — first have a real ordering dependency between them.

### What the browser should look like anyway

Even with threads available, keep the core single-threaded. The main thread owns
parse, DOM, layout, JS and paint. Only work with no shared mutable state goes
off-thread:

- **Socket I/O and TLS handshakes** — byte streams in, byte streams out
- **Image decode** — byte buffer in, RGBA32 buffer out; embarrassingly parallel,
  and needed once pages come from the live web rather than pre-rasterised assets
- **Glyph rasterisation into the cache** — arguably, though a miss may be fast
  enough that the hand-off costs more than it saves

That is a useful amount of Core 1 without a single lock on the DOM.

---

## Secure networking: the premise doesn't hold

Turn 6 asserts "the networking handles secure sockets (i ssh into the board)", and
every later turn about fetching live pages builds on it. Verified against the tree,
it is wrong: **SSH is not TLS.** They are different protocols that share primitives.

What actually exists:

- **Dropbear** at `third_party/dropbear`, built to `dropbear.so` — a complete SSH
  implementation with its own key exchange, handshake and record format.
- Crypto from `libtomcrypt.a` + `libtommath.a`, built by
  `loader/tools/build-dropbear.sh`, which notes *"linker pulls only referenced
  members"*. So the binary contains exactly what SSH needed — AES, SHA, RSA, ECC,
  curve25519, chacha20-poly1305 — and nothing more. It is not a general crypto
  facility.
- **No TLS library.** No mbedtls, wolfSSL, BearSSL or OpenSSL vendored. The only
  mbedtls references are lwIP's optional `altcp_tls` shim, which requires mbedtls
  to be supplied; `LWIP_ALTCP` / `LWIP_ALTCP_TLS` appear nowhere in the config, so
  the shim is dead code.
- **No X.509, no trust store, no hostname verification.** SSH does not need them —
  it uses trust-on-first-use with host key fingerprints. TLS cannot work without.
- **No HTTP client.** Only `loader/test/freertos/progs/httpd.c`, a server.
- The socket ABI (`loader/kernel/xtsys.h:261`, block `0x320`) has no secure-socket
  concept: `SYS_socket(type: 1=TCP, 2=UDP)`, `SYS_connect(fd, ip_be32, port)`.

### Is this Foundation-First material?

Partly, but less so than threading. TLS does not belong in the kernel — mbedtls and
peers normally sit in userspace over read/write callbacks, so it can be a library
over existing socket fds without touching the frozen ABI. That makes it genuinely
deferrable in a way ARC atomicity is not.

Three things *are* foundation-shaped:

1. **The hostname problem — the sharp one.** `SYS_connect` takes a raw `be32` IP.
   TLS needs the *hostname* for SNI and for certificate verification. If the
   Foundation networking API resolves DNS early and passes only an address
   downward, the name needed for verification is gone, and no library work recovers
   it. Cheap to avoid now, expensive later.
2. **Where the trust store lives.** A root-CA bundle needs a path convention, and
   that is a namespace decision (`/System` romfs versus `/OS` on SD).
3. **Scheme dispatch.** If anything like `URLSession` is coming, the `http:` /
   `https:` split wants designing once rather than bolting on.

### What is already solved

The two classic embedded-TLS blockers are both handled:

- **Entropy** — hardware TRNG (`hdl/xt_trng.sv`), wired through GP0, exposed via
  devfs, with `sys/random.h` in libc-compat.
- **Wall clock** — `SYS_gettimeofday` / `SYS_settime` plus kernel SNTP on an hourly
  re-sync, started by `SYS_net_up`. Certificate validity windows need a real clock;
  boards without one usually end up disabling verification. This one will not have
  to.

So the expensive prerequisites exist. What is missing is a TLS stack and a CA
bundle — and note that browsing the modern web without HTTPS is not a partial
capability, it is close to no capability at all.

---

## On the JS engine

Split the problem. **QuickJS's language conformance is not the risk** — it is
~ES2023 and scores very high on test262. The risk is entirely the **Web API
surface**, and the "vast majority of pages" bar in 2026 means enough DOM, CSSOM and
`fetch` for a framework runtime to boot, because most sites are framework-rendered.

Two things to establish before scoping:

1. **NetSurf's own JS support is weak and frequently built off.** What gets
   inherited is not a working DOM binding — that still has to be built. Budget for
   it honestly.
2. **Check `nsgenbind`.** NetSurf generates bindings from WebIDL — for Duktape, as
   far as I know. If that holds, retargeting the generator's backend to QuickJS is a
   bounded piece of work that yields a large part of the surface mechanically, from
   the same WebIDL the spec publishes. Far better than hand-writing bindings, and
   the chat never mentions it despite recommending both halves.

For scoping "vast majority" empirically: pick a corpus of target pages, instrument
for undefined property access, and let measured misses drive which APIs come next.
Chasing completeness in the abstract against the modern web is unbounded; chasing a
corpus is not.
