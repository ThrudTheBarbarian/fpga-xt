---
title: "Resident page cache"
description: "Design of the resident page cache for the SALLY banked windows — now the default banked-window cache (BANKED_CACHE = PAGE)."
---

:::tip[Implemented — now the default]
This began as a design brief and has since been **built**: `banked_page_cache.sv`, selected by
`BANKED_CACHE = "PAGE"` in `sally_mem.sv` — the default. (The older single-line, write-through
`banked_axi_reader` is the `"LINE"` alternative.) Landed in commit `d97f39c` (2026-05-23). The text
below is the original brief and may lead the final RTL in some details.
:::


> Status: original design brief, written 2026-05-22 — since implemented as the default `"PAGE"`
> cache mode (see the note above).

## Why

Banked-window accesses (`$6000-$9FFF` code, `$A000-$CFFF` data) are backed by
DDR3 over the Zynq AXI-HP port. Today `hdl/banked_axi_reader.sv` is a **single
64-byte line** demand cache with **write-through**:

- A read miss stalls SALLY for a full AXI burst round-trip (tens of `clk_sally`
  cycles), then the next ≤63 bytes of that line hit.
- Every banked **write** stalls for an AW+W+B round-trip (no write buffer).

So random-ish reads and all writes do **not** keep up with the 100 MHz CPU.

The xtc usage pattern is "map a page (`$D5C0` code / `$D5C1` data), then hammer
it before swapping" (the heap reserves data pages on demand). That pattern wants
a **resident page cache**: once a page's lines are in BRAM, *every* access to that
page — random reads **and** writes — hits BRAM at single-cycle latency. The only
DDR3 traffic becomes (a) demand-fills of not-yet-touched lines, and (b) a
write-back of dirty lines when the page is swapped out.

## Goal

Replace/extend the line cache with **two resident page caches** (selectable by a
parameter so we can A/B against the current line cache):

| Cache | CPU window | Size | Lines (64 B) | R/W | Backing |
|-------|-----------|------|-------------|-----|---------|
| code-page | `$6000-$9FFF` | 16 KB | 256 | **read-only** | DDR3 `DDR3_BANKED_BASE` |
| data-page | `$A000-$CFFF` | 12 KB | 192 | **read-write** | DDR3 `DDR3_DATA_BASE` |

Each cache holds **exactly one page** (the active `$D5C0` / `$D5C1` selection),
demand-filled per 64-byte line, resident until the page is swapped.

## Behaviour

- **Read hit** (line valid): serve from the cache BRAM, 1 cycle (registered
  output, like main mem). No stall.
- **Read miss** (line invalid): issue the existing 8-beat / 64 B INCR burst,
  fill the line into the cache BRAM, set its valid bit, deliver the byte. The
  line **stays resident** (unlike today, which overwrites the single line).
- **Write** (data cache only): write the byte into the cache BRAM and set the
  line's **dirty** bit. On a write to a not-yet-resident line, **read-allocate**
  first (fill the line, then apply the write) so the rest of the line is correct
  for later read-back / flush. No write-through.
- **Page swap** — detect when an incoming `req_addr`'s page tag differs from the
  cache's resident tag (no explicit snoop event needed; the composed DDR3 address
  already encodes the page):
  - **code cache**: clear all 256 valid bits (1 cycle) — read-only, nothing to
    flush — set the new tag, then demand-refill.
  - **data cache**: **flush** every dirty line back to the *old* page's DDR3
    location (8-beat write bursts — write the whole dirty line, not byte-by-byte),
    then clear valid+dirty, set the new tag, demand-refill. SALLY stalls (via
    `busy`) until the flush completes.

## What's already there (anchors)

- `hdl/banked_axi_reader.sv` — current single-line cache + write-through. The
  AXI burst read (`arlen=7`, `arsize=3`, INCR, `line_q[0:7]`, `line_addr_q`,
  `line_valid_q`, `beat_q`) and the FSM (`IDLE/AR/R/AW/W/B`) are the reusable
  core. The `req_*` handshake (`req_addr`/`req_valid`/`req_we`/`req_wdata`/
  `req_rdata`/`req_ready`) is the SALLY-side contract — **keep it** so
  `sally_mem` barely changes.
- `hdl/sally_mem.sv`:
  - `req_addr = (is_code_w ? DDR3_BANKED_BASE : DDR3_DATA_BASE) + {bank_id_w[15:0], offset_in_block_w[13:0]}`
  - `req_valid = rdy && is_in_window_w`, `req_we = !rw`, `busy = req_valid && !req_ready`.
  - Read mux routes `was_bank_q → axi_rdata_q` (registered).
  - Snoops `$D5C0`/`$D5C1` (XTC_CTL_BASE) into `cpu_code_bank` / `cpu_data_bank`
    (both 8-bit, readable); relocated off zero page (`$82/$83` = BASIC VNTP).
- `hdl/bank_xlat.sv` — outputs `is_in_window` (`$6000-$CFFF`), `is_code`
  (code vs data), `offset_in_block[13:0]`, `bank_id[15:0]` (code `{8'h0,$D5C0}`,
  data `{8'h0,$D5C1}`). The **page tag** is just `bank_id` (per window).
- DDR3 layout: code pages at `0x2000_0000` (256 × 16 KB), data pages at
  `0x2040_0000` (16 KB stride, low 12 KB used). Both via AXI-HP at `clk_sally`
  (100 MHz).

## Budget & constraints

- **BRAM**: 41 / 140 RAMB36 used (29 %). Code cache 16 KB ≈ 4-5 RAMB36, data
  cache 12 KB ≈ 3-4 RAMB36 → ~50 total (~36 %). Comfortable. Per-line valid
  (256+192 bits) and dirty (192 bits) fit in flops/LUTRAM (tiny).
- **Timing**: `clk_sally` setup margin is **tight (+0.036 ns)**. The cache BRAM
  read sits in the CPU read path → **register the cache output** (mirror the main
  `mem`/`bram_dout_q` pipeline) and keep the hit/mux logic shallow. Re-run impl
  and watch `clk_sally` after wiring it in. If it regresses, the cache BRAM read
  may need its own pipeline stage (the CPU already tolerates `busy` stalls).
- **Flush cost** (data swap, worst case all-dirty): 192 lines × 8-beat write
  burst ≈ 1.5 k beats ≈ ~15 µs. Typically far fewer dirty lines. This is the
  price of the page model and is only paid on a swap — fine if swaps are rare
  vs accesses, bad under thrashing (see A/B below).

## Integration

- Cleanest: a **new module** `banked_page_cache.sv` with the *same* `req_*` +
  AXI master interface as `banked_axi_reader.sv`, instantiated by `sally_mem`
  behind a parameter:
  ```
  parameter BANKED_CACHE = "PAGE"   // "LINE" = current banked_axi_reader
  ```
  `generate`-select between the two so we can A/B without ripping out the line
  cache. Two instances (code RO, data RW) or one parameterised instance ×2.
- Swap detection lives **inside** the cache: hold `resident_tag_q`; compare to
  the incoming page tag (`bank_id`, passed alongside `req_addr` or derived from
  it). Mismatch → run the invalidate (code) / flush+invalidate (data) sequence
  before serving. No new `sally_mem` snoop wiring needed beyond optionally
  forwarding `bank_id_w` / `is_code_w` to the cache.
- `busy`/`req_ready` semantics unchanged — the cache just holds `req_ready` low
  longer during a fill or a flush, and SALLY stalls as it already does.

## Open decisions (pick during implementation)

1. **Write miss policy**: read-allocate (recommended — keeps lines coherent for
   flush) vs write-no-allocate (write straight to DDR3, don't cache). Recommend
   read-allocate.
2. **Eager vs demand fill on swap**: pure demand (recommended — no upfront
   ~20 µs stall, no wasted fill of untouched lines) vs eager whole-page DMA.
3. **Dirty granularity**: per-line dirty (recommended) vs whole-page-dirty
   (simpler, flushes everything).
4. **Two caches vs one**: two (recommended — code RO needs no dirty/flush logic;
   data RW does).
5. **clk_sally**: if the page-cache read can't meet +0 with the registered
   output, add a pipeline stage and let `busy` cover the extra latency.

## Verification

- Extend `sim/tb_sally_mem.sv` (it already has an `axi_slave_mem` 1 MiB backing
  store and exercises the bank windows):
  - read miss → fill → **hit** (2nd read of same line is single-cycle, no AXI).
  - write → **read-back within the page with no AXI round-trip** (the headline
    win) — assert no AR/AW activity on the 2nd access.
  - **dirty flush on data swap**: write data into page A, swap to page B, swap
    back to A, read — verify the writes persisted (went to DDR3 via flush).
  - **code swap**: invalidate-only (assert no write bursts on a code swap).
  - cycle-count assertions for hit (≈1) vs miss (burst) vs flush.
- Keep `tb_os_rom_load` / the full `sally` suite green.
- impl run: confirm `clk_sally` still closes and BRAM util is sane.

## Net

Converts the banked tier from "stall per miss + stall per write" to "stall once
per line touched, then everything (reads **and** writes) is BRAM-fast until the
page swaps." Strict win for the dense-access-per-page heap pattern; the only loss
case is page thrashing, which the `BANKED_CACHE` parameter lets us measure
against the current line cache before committing.
