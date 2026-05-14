# GEM implementation plan

Recommendations for porting GEM to the fpga-antic platform. Assumes the
hardware design described in [n6-migration.md](./n6-migration.md) and the
xtc language documented at <http://atari-xt.com/language/>.

This is a recommendations document, not a spec. It captures *what to
build, in what order, and why* — the wire formats, opcode lists, and
class designs are downstream of these decisions.

## Framing

"Porting GEM" here does not mean binary compatibility with Atari ST GEM
(which is 68000 code, and 6502 GEM apps essentially don't exist). It
means **bringing up a GEM-style desktop environment on this hardware**,
using GEM's design as the template.

The key architectural insight: **GEM's three-layer split — AES, VDI,
GEMDOS — maps almost exactly onto this hardware's seams.**

| GEM layer | Hardware substrate | What lives there |
|-----------|--------------------|------------------|
| AES (logic) | 6502 @ 165 MHz in FPGA | Window list, event dispatch, menus, dialogs, file selector |
| VDI (drawing) | N6 via PSSI DRAW stream | NeoChrom / DMA2D primitives, font rendering, palette expansion |
| GEMDOS (services) | N6 via FMC RPC mailboxes + SD | Filesystem, process services, time |

GEM's boundaries predate this hardware, but they line up with the chips
unusually well. The 6502 handles control logic; the N6 handles pixels
and storage; PSSI / FMC mailboxes are the bus between them.

## Language: xtc

xtc is the right primary language for this work, and on this hardware
the gap between "xtc" and "llvm-mos for 6502" is large.

xtc provides:

- **Classes** (heap and stack allocation), **single inheritance**,
  **protocols** (interfaces), **automatic reference counting** with weak
  references — closer in spirit to Objective-C / Swift than to C
- **Foundation-style standard library**: `String`, `Data`, `Array`,
  `Number`, plus `Vbi` (vertical-blank IRQ hooks) and `System`
- **Memory models** that handle PORTB-style bank switching and zero-page
  layout at compile time — the 16 MB-through-64 KB-window problem is a
  *compiler* concern, not a runtime one
- **Byte-extract operators** (`<x`, `>x`, `>>x`, `>>>x`) for splitting
  multi-byte values across 8-bit registers — directly applicable to the
  PSSI DRAW opcode encoding
- **`:unroll`** loop hint for tight emit loops
- Inline `asm { ... clobbers ... }` blocks that can read and write xtc
  variables — a proper escape hatch for mailbox pokes, IRQ vectors, and
  MMU bank swaps

This maps onto GEM concepts directly:

| GEM concept | xtc realization |
|-------------|-----------------|
| Window | `Window` class with `init` / `dealloc` / `draw` / `hitTest` methods |
| Window list | `Array<Window@>` (Foundation collection, not an intrusive linked list) |
| Dialog form | Class hierarchy: `Dialog : Window`, `Form : Dialog`, etc. |
| Event delegate | A protocol (`MouseEventHandler`, `KeyEventHandler`) |
| Menu bar / items | `MenuBar` class owning `Array<MenuItem@>` |
| Resource (.RSC) file | `Data` loaded from SD, parsed into typed object tree |
| Filenames, strings | `String` from Foundation, not `char[]` |
| AES idle tick | Hook the stdlib `Vbi` module |
| VDI command emit | Method on a `DrawContext` class, `:unroll` for tight loops |
| 16-bit coord → two byte writes | Byte-extract operators (`<x`, `>x`) |
| Mailbox poke / IRQ vector / bank swap | Inline `asm` blocks with `clobbers` |
| Object lifetime | ARC; no manual `gem_free` discipline |

### Posture toward FreeGEM and EmuTOS

Use them as **behavioral references**, not source to port.

FreeGEM and EmuTOS are mature, well-commented C codebases that document
the correct behavior of every AES call and VDI primitive. They are
*not*, however, idiomatic xtc. The class system, ARC, and Foundation
collections make a fresh implementation substantially smaller and
clearer than a literal port. A literal port also preserves decades of
68000-isms (alignment assumptions, big-endian pointer arithmetic, manual
allocator discipline) that have no business in this codebase.

Read FreeGEM / EmuTOS for "what does `wind_create` actually do?" and
"what fields does `evnt_multi` expect?". Write the implementation
native to xtc.

## Phased plan

### Phase 0 — substrate

Prerequisite, mostly on the n6-migration roadmap:

- FMC mailboxes, PSSI DRAW stream, SPI event channel, USB HID input,
  SD mount from N6 firmware
- xtc toolchain set up, memory model chosen
- One-page hardware bring-up note mapping xtc identifiers to hardware
  resources (mailbox addresses, IRQ vector numbers, MMU bank scheme)

### Phase 1 — VDI dispatch layer (keystone)

The architectural keystone — everything else depends on the wire format
being right.

- **VDI opcode spec** for DRAW commands over PSSI: line, polyline, rect,
  filled rect, circle, filled polygon, blit, text, scroll, clip rect,
  palette load. Parameter encoding is a software contract; PSSI RTL
  doesn't care.
- **6502-side VDI library** as an xtc module: each VDI call emits the
  corresponding opcode into the PSSI ring buffer.
- **N6-side DRAW dispatcher**: parses opcodes, hands off to LVGL draw
  API (which is already wired through NeoChrom + DMA2D — see
  [n6-migration.md](./n6-migration.md)).
- **Indexed → RGB888 palette expansion** happens on the N6 side (LVGL
  configured as `LV_COLOR_DEPTH 24`).
- **Inquiry calls** (`vqt_extent`, font metrics) become FMC RPCs using
  the 0x01 W/R mailbox pair.

Deliverable: a 6502 test program draws lines and rectangles on screen.
Proves the whole chain end-to-end.

### Phase 2 — AES

- `Window` class with virtual `draw` / `hitTest` / `eventReceived`,
  managed in `Array<Window@>`
- Event queue: USB HID → N6 IRQ → 6502 IRQ → AES queue. Events as small
  classes; protocol-based dispatch to handlers
- Dialog forms: class hierarchy on top of `Window`, automatic ARC
  cleanup of widget trees
- Menu bar / items: classes, click delegates as protocols
- File selector: standard form, uses GEMDOS path (Phase 3)
- Resource (`.RSC`) loader: reads via GEMDOS, parses into typed objects
  using Foundation classes

Deliverable: a window with title bar appears, mouse cursor tracks,
clicks deliver to a test app.

### Phase 3 — GEMDOS via FMC RPC

- Map GEMDOS syscall set (`open`, `read`, `write`, `close`, `seek`,
  `stat`, `mkdir`, `Dgetdrv`, …) onto FMC RPC commands using the 01 W/R
  mailbox pair for control and 0x00 W/R for bulk data.
- N6 side: handler reads request from RPC mailbox, performs filesystem
  op against SD (FatFS or littlefs initially), writes response.
- Bulk file content uses the 0x00 W mailbox — N6 streams file bytes into
  6502 HyperRAM at the buffer address named by the syscall.

Deliverable: `fopen` / `fread` / `fwrite` from xtc; files visible on the
SD card.

### Phase 4 — desktop and apps

- Port the FreeGEM desktop concept — written fresh in xtc, using
  FreeGEM as design reference. Exercises most of AES and VDI in one
  app.
- A few sample apps: text editor, calculator, simple paint
- Proves the platform is usable

### Phase 5 — polish

- Clipboard, drag-and-drop, file associations
- Performance tuning: VBI batching of DRAW commands, font cache
  strategy
- Multi-tasking model (see open question 1 below)

## Key technical decisions

| Decision | Recommendation | Reasoning |
|----------|----------------|-----------|
| Primary language | xtc | Designed for this hardware; class / protocol / ARC system fits GEM |
| Memory model | Bank-window via PORTB MMU, handled by xtc memory model | Compile-time, not runtime, banking discipline |
| Source posture | EmuTOS / FreeGEM as behavioral reference, not source to port | Idiomatic xtc differs too much from K&R C for literal port to pay off |
| Wire color model | 8-bit indexed | Matches GEM heritage; palette LUT on N6 expands to RGB888 (LVGL `LV_COLOR_DEPTH 24`) |
| Event channel | IRQ + SPI event payload pull | Already in [n6-migration.md](./n6-migration.md) |
| Initial tasking | Single-task | Don't pay the multi-tasking cost before AES works |
| ARC strategy | ARC by default; `-farc=off` or `weak:` for hot paths | Default-safe, opt out where profiling demands |

## SALLY CPU extensions for multi-tasking

Several small additions to the FPGA SALLY core would substantially ease
multi-tasking and improve xtc codegen. SALLY is project-owned RTL, so
the question is RTL cost and fmax impact, not vendor support.

### Cooperative tasking package (cheapest)

For GEM-style cooperative tasking (`evnt_multi`-style yield), the floor
is per-task state with no preemption hardware:

- **SP_BANK register** — selects which page the hardware stack actually
  lives in. Real 6502 fixes it at $0100; making it programmable lets
  each task have its own 256-byte stack. ~20 LUTs, data-path-only,
  fmax-neutral.
- **ZP_BANK register** — same trick for zero-page. Each task gets its
  own $00–$FF fast scratch. ~30 LUTs, data-path-only.

Yielding becomes ~30 cycles of software: save A/X/Y/P, write
SP/SP_BANK/ZP_BANK to the saved context block, load the next task's,
RTS. No new opcodes required.

### Preemptive tasking additions

If preemptive scheduling is wanted later:

- **Tick IRQ** — free-running counter + comparator + IRQ enable. The
  ANTIC VBI mechanism may already serve as one; otherwise ~20 LUTs.
- **Atomic compare-and-swap opcode** — one new opcode for atomic RMW
  against memory. Without it, every mutex needs disable-IRQ guards
  which break composability. ~30 LUTs in the decoder.
- **Optional: hardware context-switch instruction** — atomic save/load
  of {A, X, Y, P, SP, SP_BANK, ZP_BANK, PC} between context blocks.
  Software equivalent is 50–80 cycles plus a window where IRQ could
  corrupt a half-saved state. ~100 LUTs. The correctness win
  (race-free swap) matters more than the speed win.

### Wider hardware SP (kills xtc's software stack)

This is bigger than the bank-register additions and changes xtc
codegen, not just kernel behaviour.

xtc — like every 6502 C-family compiler — currently runs a **software
stack** in parallel to the hardware stack: a 16-bit ZP pointer growing
through main memory, used for function arguments, locals, and ARC
references. Every software-stack access is 3–5 instructions vs 1
instruction for a true hardware stack with stack-relative addressing.
AES code will be dominated by local-variable access — class methods,
ARC retain/release, nested event dispatch — so this is the single
biggest codegen win available.

Widening SP to 11 bits gives a 2 KB stack per task — generous enough
for typical xtc call depth (~20+ class-method frames at average ~100
bytes each) without burning excessive BRAM. 10-bit (1 KB) is too tight
for ARC-heavy code; 12-bit (4 KB) is more comfortable but doubles
BRAM cost per task; 14/16-bit are overkill for GEM-style workloads.

The current FPGA design uses 155/256 EBRs (~60% of 160 KB), leaving
~101 EBRs (~63 KB) free. Of that, ~30 EBRs are pre-budgeted for
not-yet-built items (FMC mailbox FIFOs, PSSI TX FIFO, VDI command
ring), leaving ~70 EBRs of real headroom for stack work. **An
8-slot × 2 KB design needs 32 EBRs — comfortable inside that
budget.**

Storage options for the stack:

| Option | Pros | Cons |
|--------|------|------|
| **A: BRAM per task, no copy on switch** | Native FPGA-SRAM speed (~6 ns); switch is one register write | BRAM caps task count (8 tasks × 2 KB = 16 KB BRAM = 32 EBRs, comfortable on Ti60 with current usage) |
| B: HyperRAM with MMU window, no copy | Unlimited tasks; no BRAM cost | Push/pop hits HyperRAM (~50–100 ns); evaporates most of the codegen win |
| C: BRAM working set + HyperRAM backing, copy on switch | Many tasks possible at near-native speed | Adds ~10–40 µs per switch for 2 KB (still <0.1% at 60 Hz preemption) |

**Recommendation: Option A as primary with 8 slots × 2 KB, Option C as
overflow if task count ever exceeds 8.** Avoid Option B — it
eliminates the reason for widening SP in the first place.

**X register width tracks SP** — TSX / TXS must round-trip the full
SP width or any classic stack-frame-access idiom (`TSX; LDA n,X; TXS`)
silently truncates and corrupts SP on the TXS. The fix: X is
internally widened to match SP, but architectural visibility stays at
8 bits except for TSX/TXS:

| Operation | Behavior |
|-----------|----------|
| `TSX` / `TXS` | Full-width transfer between X and SP |
| `LDX` (imm / abs / zp), `TAX`, `TYX` | Zero-extend 8-bit value into X |
| `STX`, `TXA`, `TXY`, `LDA $n,X` | See only low 8 bits |
| `INX` / `DEX` | Operate on low 8 bits with wrap; upper bits preserved by the existing rule that only LDX-class writes touch them |

Note: TSX → save X to ZP → load X from ZP → TXS *does not* round-trip
SP correctly (ZP store truncates). Code wanting to save SP across a
call needs a stack-relative push of SP itself, or a dedicated new
instruction. Worth flagging in the porting notes for any existing 6502
software.

Y can stay 8-bit unless symmetry feels important — the only patterns
that demand the trick are TSX/TXS, which uses X exclusively.

Cost summary for wider-SP package:
- 11-bit SP + SP_BASE register: ~20 LUTs
- X register width extension (3 extra bits + TSX/TXS data path): ~10 LUTs
- 16 KB BRAM allocation = 32 EBRs (8 task slots × 2 KB)
- Stack address mux: ~20 LUTs
- **Stack-relative addressing modes** in decoder: ~50 LUTs (fmax-sensitive)
- Context switch SP_BASE swap: trivial

**Total: ~110 LUTs + 32 EBRs (16 KB BRAM)**, with the caveat that stack-relative
addressing touches the decode/fetch path that previously gave fmax
trouble. If that closes, the codegen payoff is large; if it doesn't,
the wider SP still helps somewhat (denser PHA/PLA-based code) but
gives up the biggest single optimization.

Critically, **the wider SP only pays off if xtc generates stack-relative
loads/stores**, which requires a compiler-side change. Worth checking
whether xtc already has hooks for this target option before committing
to the hardware work.

### Decision matrix

| Goal | Package | LUTs | fmax risk | Compiler work |
|------|---------|-----:|-----------|---------------|
| Cooperative tasking | SP_BANK + ZP_BANK | ~50 | none | none |
| Preemptive tasking | + Tick IRQ + atomic CAS | ~100 | none | minor |
| Race-free preemption | + HW context-switch insn | ~200 | none | none |
| Fast xtc codegen | Wider SP + stack-relative addr modes | ~100 + 32 KB BRAM | yes (decode path) | substantial (xtc target option) |
| Cheap IRQ entry | Auto-push A/X/Y on IRQ, auto-pull on RTI | ~40 | low | none |

### What to skip

- **Privilege bit / kernel-mode flag** — useful for OS isolation but
  the cost is in every privileged register elsewhere in the design,
  not in the CPU core. Premature.
- **Per-task MMU context / TLB** — depends on rp-MMU specifics.
  Probably fine to start without; revisit if address-space sharing
  between tasks becomes painful.

## Open design questions

1. **Multi-tasking model** — Classic GEM was cooperative single-task via
   `evnt_multi`. MagiC added preemptive multitasking on Atari ST. The
   choice interacts with:
   - xtc runtime support (task / fiber primitives — not visible in the
     language reference TOC; needs investigation)
   - SALLY hardware extensions chosen (see [SALLY CPU extensions for
     multi-tasking](#sally-cpu-extensions-for-multi-tasking) above)
   - ARC under preemption — atomic refcount needed for shared objects
   - 6502 stack model — each task needs its own stack page; cheap with
     hardware support, more expensive without
   - GEMDOS reentrancy — filesystem syscalls hitting the N6 must
     serialize cleanly
   - Whether legacy 1.79 MHz apps coexist with modern 165 MHz tasks
     under the same scheduler
   
   **Deferred to Phase 5**, but worth thinking about early enough that
   AES doesn't accidentally assume single-task semantics in places that
   would be expensive to undo. The SALLY extensions are also worth
   deciding early — they're cheap individually but affect the whole
   tasking design.

2. **Font rendering boundary**
   - (A) 6502 sends Unicode + style, N6 rasterizes using LVGL fonts
   - (B) 6502 manages a bitmap font cache, sends pre-rasterized glyphs
   
   LVGL's font system is mature; (A) is probably right, but the 6502
   still needs glyph metrics for layout. Metric inquiry is a small FMC
   RPC.

3. **Resource (.RSC) file format**
   - Reuse Atari ST `.RSC` (compatibility with existing GEM resource
     editors / converters)
   - Design a native format better suited to xtc's class system
   
   Reusing buys tooling; designing fresh buys clarity. Probably reuse
   for v0.1 and revisit.

4. **VBI tick rate** — Atari ST GEM expected 50 Hz; HDMI on this
   hardware runs at 60 Hz. Some legacy apps may have hardcoded delays.
   Mostly cosmetic, but flag it: cursor blink rate, animation timing.

5. **Per-frame DRAW batching** — should the 6502 buffer DRAW commands
   and emit per-VBI, or stream live? Streaming is simpler; buffering is
   faster under sustained high command rates. Defer until profiling
   shows it matters.

## Risks

1. **AES code volume**: even a clean xtc reimplementation will be
   several thousand lines. Bank-window addressing for the AES image
   needs to be planned, not discovered late.
2. **VDI primitive coverage**: GEM apps assume a specific (and large)
   set of VDI ops. A missing primitive breaks an app silently. Inventory
   FreeGEM's `vdi/` source for the complete list *before* fixing the
   wire format.
3. **ARC overhead in hot paths**: event loop, VDI emit, mouse tracking.
   Profile; opt out with `-farc=off` or `weak:` where shown to matter.
4. **xtc stdlib gaps**: ten short pages of language reference is
   encouraging (small, well-defined), but the standard library may have
   gaps. Specifically worth verifying: does Foundation `Array<T>` work
   cleanly with class types like `Array<Window@>`? Do `weak:` refs play
   well with collection membership?

## Where to start

Before writing any AES code:

1. **Lock the VDI opcode wire format.** Even a 50-opcode v0.1 spec is
   worth more than any code. Inventory FreeGEM's VDI source for the
   complete primitive set.
2. **Wire one full vertical slice.** xtc program emits `v_pline` → PSSI
   → N6 → LVGL → screen. Once that path is live, AES is just code.
3. **Profile early.** Instrument PSSI fill rate and FMC RPC roundtrip
   with a synthetic AES-like workload (event tick + ~20 DRAW calls /
   frame). Tells you whether batching matters before you build a
   batching layer.
4. **Write a 100-line `Window` class.** Sanity-check that xtc's class
   model handles GEM's window concept comfortably. If something fights,
   find out now, not at month four.

## References

- [n6-migration.md](./n6-migration.md) — hardware architecture, PSSI /
  FMC / SPI channels, mailbox map, latency budgets
- [GEM.md](./GEM.md) — full POR architecture document
- <http://atari-xt.com/language/> — xtc language reference
- FreeGEM (GPL) — AES and VDI source, used as behavioral reference
- EmuTOS — cleaner AES reimplementation, also used as reference
