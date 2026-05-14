# Known issues / deferred bugs

Bugs in our HDL that we know about but haven't fixed yet, usually because
the prerequisite architecture (cycle-accurate bus, SALLY-on-FPGA, etc.)
isn't in place yet. Listed here so they don't get lost between milestones.

Format per entry: a short description, where it lives in the code, why
it's deferred, and what would unblock the fix.

---

## ANTIC

### `wsync-cycle-105` — RESOLVED 2026-05-08

(Originally: `wsync_gen` released /RDY at the next line's `line_start`
instead of bus cycle 105 of the current line — ~9 cycles late vs.
real ANTIC.)

**Fixed in M-wsync-105** (commit pending). antic_top instantiates
`wsync_gen` and feeds it a synthesised `cycle_105_pulse` derived from
an 8-bit phi2-tick counter that resets on the synced `line_start`
pulse and fires when the count hits 105. wsync_gen's "line_start"
input is now driven by this pulse instead of the raw line boundary.
wsync_overdue diag counter wired up too. /RDY (sally_clock's
wsync_rdy_n input + the antic_top.rdy_n external pin) is now the
real wsync_gen output.

### `dl-1k-wrap` — RESOLVED 2026-05-09

(Originally: `dl_parser.sv` flat 16-bit `dl_pos` increment didn't
wrap on 1K boundaries — so a DL crossing a 1 KB boundary by accident
ran past the boundary instead of wrapping back to the start of the
1 KB block, mismatching real ANTIC behaviour.)

**Fixed in M-dl1k-wrap.** Replaced the four `dl_pos <= dl_pos + 16'd1`
sites with `dl_pos <= {dl_pos[15:10], dl_pos[9:0] + 10'd1}` so only
the low 10 bits advance during normal fetches. The two non-increment
loads — initial DLIST load (`{dlisth, dlistl}`) and JMP/JVB target
load (`{mem_rdata, target_addr[7:0]}`) — still cover the full 16
bits, so jump instructions remain unrestricted. 37/37 sim suite
still passing.

---

## Bank cache (M24-3)

### `bank-cache-eviction-async-read` — RESOLVED 2026-05-08

(Originally: M24-int-cache v2 replaced the FA cache with a 4-way SA
design but kept two async reads of `data[victim_way][...]` in the
eviction FSM. Synplify flagged "read port is not synchronous" and
fell back to LUT memory.)

**Fixed in M24-int-cache v3** by:

1. Reworking the eviction FSM into a streaming pipeline (EVICT_PREP /
   EVICT_STREAM / EVICT_DRAIN). All eviction reads now go through
   `data_rd_q[victim_way_q]` via the speculative-read pipeline; no
   async data[] reads remain.
2. Splitting the per-way data arrays into a `generate` block, so each
   way's `g_data[w].mem` is an independent 1-D memory.
3. Consolidating the three writers (CPU hit, refill, install) into a
   single muxed write port per way (Synplify rejected >2 write ports).

Result: each way's data array maps to a dedicated EFX_DPRAM10 BRAM
(1R + 1W). bank_cache went 8501 FF / 18535 LUT / 0 RAMs →
**286 FF / 440 LUT / 4 RAMs**. antic_top went 15833 FF / 26816 LUT
→ **7614 FF / 9131 LUT** (net -52 % FFs, -66 % LUTs).

### `bank-cache-async-read` — RESOLVED 2026-05-08

(Originally: M24-7 standalone synth showed `bank_cache.sv`'s
fully-associative `data` array spilled into distributed-LUT memory
because the read pattern `cache_cpu_rdata = data[hit_idx][offset]`
went through a combinational tag-compare. Cost: 8418 FF / 38928 LUT
for the 16-line × 64-byte cache — 4× the rest of the SALLY stack.)

**Fixed in M24-int-cache v3** (commit `9ee9270`). The fix took two
steps:

1. **v2 (4-way set-associative architecture).** Rewrote `bank_cache.sv`
   from 16-way fully-associative to 4 sets × 4 ways. Address
   decomposition (`cpu_offset` widened to 12-bit sub-block; split
   into byte_off / set_idx / addr_tag) makes hit detection a
   parallel 4-tag-compare per set instead of a 16-way priority
   encoder. Recovered ~6500 LUTs but still LUT-resident.

2. **v3 (BRAM mapping).** Per-way data arrays split via `generate`
   into independent 1-D memories; the three writers (CPU hit,
   refill, install) consolidated into a single muxed write port per
   way; eviction FSM rewritten as `EVICT_PREP` → `EVICT_STREAM` →
   `EVICT_DRAIN` streaming pipeline through the speculative-read
   register; `post_install_q` bypass register holds the just-installed
   byte for one cycle. Each way maps to one `EFX_DPRAM10` BRAM block.

Result: bank_cache **286 FF / 442 LUT / 4 RAMs** (was 8401 FF /
24897 LUT / 0). 1-cycle hit latency preserved; eviction ~2× faster
(~65 cycles vs ~128 in the FA design).

(The earlier v2 HIT_WAIT pipeline attempt that failed tb_sally_mem
 was abandoned in favour of the parallel-tag-compare architecture
 above — no test refactor needed.)

### `bank-cache-line-size` — bump LINE_BYTES from 64 → 4096 (proposal)

- **Source**: M24-int-cache v3 default = 4 sets × 4 ways × **64 B**
  lines = **1 KB total cache**. Far smaller than is useful given
  Ti60's BRAM budget.
- **Background**: the bank_cache "line" is the granularity of all
  HyperRAM transactions. A miss reads `LINE_BYTES` from HR; a dirty
  eviction writes `LINE_BYTES` back. Even if SALLY only wants one
  byte, the FSM moves a full line. The cache then holds those bytes
  locally so subsequent accesses to the same line hit.
- **Original reasoning** for small lines was "small misses can hide
  inside HBLANK at 1× speed (cycle-accurate Atari)." That concern
  evaporates because at 1× the CPU runs at original Atari rate
  (1.79 MHz), HyperRAM (245 MHz / 400 MB/s) is way faster than CPU
  demand, and 1× compatibility software (games / demos) typically
  has fixed code-and-data layouts that don't thrash the bank
  window. **At 1× you essentially never miss after warm-up.**
- **Real trade-off** is at turbo speeds (12×..72× per
  `clock-mult-range`), where a fast SALLY can outrun HR if the
  cache geometry is wrong. Even there, the numbers favour large
  lines:

      LINE_BYTES   total cache   clean miss @ turbo (128.7 MHz clk_bus)
      ----------   -----------   --------------------------------------
      64           1 KB          0.5 µs   (≈ 0.9 Atari cycles)
      256          4 KB          2.0 µs   (≈ 3.6 Atari cycles)
      4096         64 KB         32 µs    (≈ 57 Atari cycles, ≈ ¼ scan-line)

  At 1× (21.5 MHz clk_bus, 46.5 ns/cycle):

      LINE_BYTES   clean miss
      ----------   ------------------
      64           3.1 µs   (≈ 5.4 Atari cycles)
      256          12 µs    (≈ 22 Atari cycles)
      4096         191 µs   (≈ 1.5 scan-lines — but 1× barely misses anyway)

- **Why 4 KB wins**:
  - Fits the entire bank-window (16 KB) of any single 130XE bank
    inside the cache (16 lines × 4 KB = 64 KB total cache),
    eliminating most cross-bank thrash. After a 130XE bank
    switch, the first refs warm the new bank's lines; switching
    back to the previous bank → all its lines still resident → all
    hits.
  - 6502 software has strong spatial locality: subroutines are
    typically 50-200 bytes, hot loops < 100 bytes, data tables
    rarely exceed 256 bytes. Pulling 4 KB on a miss usually warms
    multiple subroutines worth of code in one transaction.
  - **Same tag-compare cost** as today (NUM_SETS × NUM_WAYS still
    16, parallel comparators per set unchanged).
  - **Implementation: literally one parameter override** in
    `sally_mem`'s bank_cache instantiation: `LINE_BYTES(4096)`.
    The bank_cache module is fully parametric on this; no FSM
    surgery needed.
  - BRAM usage scales linearly: from 4 EFX_DPRAM10 today →
    ~64 EFX_DPRAM10 (4 sets × 4 KB = 16 KB per way × 4 ways = 64 KB
    @ ~1 KB byte-wide per RAM10). Ti60 has 224 EFX_RAM10s → ~30 %
    usage just for the cache. Comfortable, but combined with the
    rest of antic_top this is the upper end of what fits.
- **Cost worth knowing**: a dirty 4 KB eviction at 1× speed (uncommon
  case) takes ~382 µs ≈ 3 scan-lines. Real-Atari software almost
  never makes the bank window dirty (banked memory is usually
  read-only ROM-like data); the dirty path mostly applies to
  130XE-bank-as-RAM use which is rare and forgiving. At turbo:
  ~64 µs ≈ ½ scan-line. Acceptable.
- **Adjacent issue worth its own writeup**: the bank_cache ↔
  hyperram_shim handshake is byte-at-a-time (1 byte per `clk_bus`
  cycle), so we waste most of HyperRAM's 400 MB/s bandwidth. A
  multi-byte-burst hr-port API would let a 4 KB miss finish in
  ~10 µs (HR-limited) instead of ~32 µs at turbo (clk_bus-limited).
  Doesn't block the line-size bump but compounds the win when both
  land. Logged separately as
  `bank-cache-byte-handshake-bandwidth`.
- **Fix shape**: in `hdl/sally_mem.sv`, change
  `LINE_BYTES(CACHE_LINE_BYTES)` instantiation to use 4096 (or
  override the `CACHE_LINE_BYTES` parameter at the antic_top
  instantiation). Update `tb_bank_cache.sv` HR-mock layout to
  match (the test currently uses 64 B lines for sim speed; can
  stay there since the cache is parametric).
- **Don't ship yet**: holding for the user's "something else to
  consider" review before we flip the parameter.
- **Superseded by `M-cache-rework`**: kept as-recorded for the
  history of the per-line-size analysis; the actual landed plan is
  the consolidated cache-rework proposal further down in this
  section.

### `bank-cache-byte-handshake-bandwidth` — 1 byte / clk_bus cycle limit on HR transfers

- **Source**: bank_cache.sv's `hr_req`/`hr_done` pair shapes a
  byte-at-a-time handshake; on each transfer hyperram_shim is
  asked for / handed one byte at clk_bus rate.
- **What's at stake**: HyperRAM's intrinsic bandwidth is ~400 MB/s
  (200 MHz DDR × 1 byte/edge × x8 = 400 MB/s, or ~2.5 ns/byte).
  Our cache is bottlenecked at clk_bus rate (46.5 ns/byte at 1×
  deployment, 7.8 ns/byte at proposed turbo). So we're using 5 %
  (1×) to 32 % (turbo) of HR's actual bandwidth.
- **Software impact**: cache misses are slower than they need to
  be. A 4 KB miss at turbo costs ~32 µs vs ~10 µs if we were
  HR-limited.
- **Why deferred**: not blocking — a 32 µs miss at turbo is
  already well below 1 scan-line; the 3× speedup would be nice
  but not gating any specific use-case.
- **Fix shape**: extend `bank_cache`'s HR port from a 1-byte
  handshake to a multi-byte burst (e.g., a `start_burst_addr` +
  `burst_len` request → hyperram_shim issues a single multi-byte
  HR transaction → bytes stream back at HR rate, optionally
  buffered in a small FIFO inside the cache so the cache write
  pipeline isn't tied to ram_clk). bank_cache's data-array write
  port can then take multiple bytes per cycle if the FIFO has them
  ready.
- **Effort**: a couple of days. Touches bank_cache's FSM
  (EVICT_STREAM / FETCH_WAIT) and adds a small CDC FIFO between
  ram_clk and clk_bus. Independent of the line-size proposal but
  amplifies its win.
- **Folded into `M-cache-rework`**: the multi-byte burst handshake
  is one of the four pillars of the consolidated rework (alongside
  partition + streaming bypass + attribute table). Kept here for
  the standalone analysis; the implementation lives under the
  rework milestone below.

### `M-cache-rework` — partitioned cache aligned with xtc large-allocations design

**Status**: proposal locked, implementation pending. Supersedes
`bank-cache-line-size` and `bank-cache-byte-handshake-bandwidth`
(both kept as-recorded for the historical analysis). Cross-references
`xtc/doc/large-allocations.md` for the source design and
`clock-mult-range` for the orthogonal CPU-clock work.

#### Goal

Replace today's tiny unified bank_cache (4 sets × 4 ways × 64 B =
1 KB total) with a **64 KB partitioned cache** that protects hot
working sets from streaming sweeps, exposes per-bank cache hints
to xtc-compiled software via a memory-mapped attribute table, and
lifts the HyperRAM transfer rate from clk_bus-bound to ram_clk-bound.

#### Constraints

- **Ti60F256 BRAM budget**: 224 EFX_RAM10 blocks (10 kbit each;
  ~1 KB usable byte-wide → ~224 KB on-chip practical, ~280 KB raw).
  After existing consumers (sally_mem 64, cpu_shadow / HR IP 13,
  line_buffer 2, palette_lut 2, current bank_cache 4 → 85 booked),
  ~60 KB margin must remain for M25 peripherals + future expansion
  → cache budget ≈ **64 KB**.
- **Ti90J361** would unlock ~860 KB on-chip (688 BRAMs) and adds
  DDR4 hard-IP, but at $64 / 0.65 mm pitch / 110 HS + 20 HV I/O
  it's a different SKU conversation — captured here as a future
  option, not the M-cache-rework target.

#### Decisions locked

- **Total cache**: 64 KB.
- **Block size**: 1 KB. Single block size across the whole cache
  (no per-partition variation — keeps the FSM simple). 4-way
  set-associative × 16 sets = 64 lines. xtc large-allocations doc's
  recommendation, validated for our access-pattern mix.
- **Code/data partition**: split by which bank-register routed the
  access (`$82` → code partition; `$83` / `$84` / `$85` → data
  partition). LRU per-partition. Configurable split via
  `$D381 CACHE_CODE_LINES`. Default 24 / 40 (37 % code / 63 % data).
- **Streaming bypass**: per-bank attribute bit (`BANK_ATTR_STREAM`).
  Marked banks miss-fill into a single transient slot per
  partition, never promoted to MRU. Framebuffer / DMA-buffer
  pattern.
- **Per-bank attribute SRAM**: 4 bits × 3840 banks (16 MB HR) =
  ~1.92 KB → 1 EFX_RAM10. Single-cycle lookup on miss path.
  Bit assignments per `xtc/doc/large-allocations.md` `$D385`:
  reserved (0) / code-affinity (1) / streaming (2) / spare (3).
- **Multi-byte HR burst handshake**: bank_cache's `hr_req`/`hr_done`
  becomes `start_addr + burst_len` → hyperram_shim issues one
  multi-byte HR transaction → bytes stream through a small
  `ram_clk` → `clk_bus` CDC FIFO inside the cache. Lifts effective
  fill rate from 1 byte/clk_bus cycle (~128 MB/s at fMax) to
  ~2 bytes/clk_bus cycle (~250 MB/s at fMax — close to HR's
  400 MB/s ceiling). At fMax this matters: a 1 KB miss drops
  from ~1024 SALLY cycles wasted to ~512.
- **Register map**: `$D380-$D3FF` (PIA-mirror window). Per xtc
  large-allocations doc:
  ```
  $D380 CACHE_CTL          bit 0 = ENABLE_PARTITION
  $D381 CACHE_CODE_LINES   lines reserved for code partition
  $D382 BANK_ATTR_REGION   $00=A, $01=B, $02=C
  $D383 BANK_ATTR_ID_LO    bank id low byte
  $D384 BANK_ATTR_ID_HI    bank id high byte (region C only)
  $D385 BANK_ATTR_DATA     attribute bits for selected bank
  $D386 CURRENT_TASK_ID    OS writes on context switch (4 bits)
  $D387 CACHE_FLUSH        write-any-value flush
  $D388-$D3FF              reserved
  ```
- **Task-id tagging**: 4 bits per line × 64 lines = 32 B silicon
  for soft eviction preference. Lookups stay tag-agnostic so shared
  pages cost one fill across tasks. **Deferred** — register address
  reserved at `$D386` so the map is stable, but the eviction-bias
  logic only lands when xt actually goes preemptively multitasking.

#### fMax economics (the binding constraint)

At CLOCK_MULT=72 / clk_bus=128.7 MHz / SALLY=128.7 MHz, every miss
costs SALLY cycles **proportional to block size**, not to clk_bus
rate (HyperRAM transfer time is fixed by hardware). Per-miss SALLY-
cycle cost at 1 KB:

| Handshake | µs / 1 KB miss | SALLY cycles |
|-----------|---------------:|-------------:|
| Current 1-byte / clk_bus | 8.0 | 1024 |
| Multi-byte burst (proposal) | ~2.6 | ~336 |

The 3× speedup from the burst handshake is the dominant
performance win in this rework — partition / streaming-bypass
keep the working set hot so misses stay rare; burst handshake
makes each miss as cheap as physically possible. **At 1× speed
(compatibility) none of this matters because the cache rarely
misses anyway.**

#### BRAM cost budget

| Item | RAM10 today | RAM10 after rework |
|------|------------:|-------------------:|
| sally_mem.mem (64 KB) | 64 | 64 |
| cpu_shadow / HR IP | 13 | 13 |
| bank_cache (1 KB → 64 KB) | 4 | ~80 |
| line_buffer | 2 | 2 |
| palette_lut | 2 | 2 |
| attribute SRAM (4 bits × 4096) | 0 | 2 |
| streaming bypass slots (2 × 1 KB) | 0 | 2 |
| HR-burst CDC FIFO (~256 B) | 0 | 1 |
| **total** | **85 / 224** (38 %) | **~166 / 224** (74 %) |

Leaves ~58 RAM10 (~58 KB byte-wide) for M25 peripherals and future
expansion. Tight but workable.

> Step 1 actuals (synth confirmed): cache_regs adds 2 EFX_RAM10
> (the attribute SRAM, 4 bits × 4096 = 16 kbit), bringing antic_top
> from 85 → 87 RAM10. clk_bus headroom unchanged (+0.398 ns vs
> +0.375 baseline); 100× / BASE_DIV=100 viability preserved.
>
> Step 2 actuals: 64 KB cache adds 60 RAM10 (sally_mem 64 → 128;
> includes the 64-RAM10 cache backing store), antic_top → 147
> RAM10. clk_bus 180.1 → 169.9 MHz / +0.063 ns slack. **Lost 100×
> and 96× viability**; SALLY now in the BASE_DIV=84 grade (94.9×
> original Atari). Free pool: 77 RAM10 (~77 KB) — Steps 3-5 need
> ~3 RAM10 (streaming bypass + HR-burst CDC), leaving ~74 RAM10
> for M25 peripherals.
>
> Step 3 actuals: code/data partition split unified cache evenly
> (32 KB code + 32 KB data, 64 RAM10 total — same as Step 2).
> +162 FF / +237 LUT for the partition mux + classifier + a
> registered partition selector (latent comb-loop fix). clk_bus
> 169.9 → 159.2 MHz; SDC backed off 168 → 156 MHz to close.
> 88.9× original Atari, fits BASE_DIV=84 with 8.8 MHz margin
> (down from 19.5 MHz). RAM10 unchanged at 147; free pool still
> 77 RAM10.
>
> Step 4 actuals: streaming-bypass slot landed (Option 1 — 1-cycle
> attribute-lookup skew accepted). 4-quadrant routing in sally_mem
> ({code,data}×{partition,bypass}) with 2 bank_cache instances added
> at 2 sets × 2 ways × 1 KB each (4 KB per partition / 8 KB total).
> attr_lookup_idx (12 bits, combinational from bank_id_w) +
> attr_lookup_data (4 bits, sync-read) wired through antic_top to
> cache_regs's attribute SRAM. rdata mux uses REGISTERED
> (is_data, is_streaming) selectors — same Step 3 comb-loop fix
> pattern. HR port shared via 4-way priority mux. clk_bus 159.2 →
> **163.854 MHz / +0.297 ns slack** at the 156 MHz SDC target —
> fmax *improved* by ~5 MHz vs Step 3 (the registered selectors
> + new caches gave PnR a cleaner placement to find). 91.55×
> original Atari, fits BASE_DIV=84 with 13.5 MHz margin (up from
> 8.8 MHz at Step 3). Net antic_top delta vs Step 3: **+193 FF /
> +686 LUT / +8 RAM10** (expected +8 RAM10 = 8 EFX_RAM10 for the
> two 4 KB bypass caches). Total: 8682 FF / 11147 LUT / 155 RAM10
> (= 90 EFX_RAM10 + 65 EFX_DPRAM10). Free pool: 69 RAM10. clk_pix
> 137.0 MHz / +17.7 ns; clk_bit 268.7 MHz / +2.79 ns; ram_clk
> 242.3 MHz / +0.87 ns. 39/39 sim passing (tb_cache_partition
> extended with phases F/G/H covering streaming routing,
> partition-pollution resistance, and data-side streaming).
>
> Step 5 actuals: HR multi-byte burst handshake landed. bank_cache's
> per-byte hr_req/hr_done loop replaced with a single burst per
> refill / writeback — `hr_req` pulses once with `hr_addr` +
> `hr_we` + `hr_burst_len` (= LINE_BYTES-1), and the controller
> streams responses via `hr_rdata + hr_rvalid` (read) or consumes
> `hr_wdata` per cycle (write); `hr_done` pulses on the last byte.
> The unused FETCH state was collapsed into FETCH_WAIT (saves the
> 1-cycle pause on the original transition). Sim impact: 1 KB miss
> drops from **2050 → 1027 cycles** (2× — exactly the per-byte
> handshake overhead removed); 64-byte sim miss drops from
> 131 → 68 cycles. Synth (Ti60-C4, 156 MHz target): clk_bus
> **165.8 MHz / +0.369 ns slack** (up ~2 MHz vs Step 4 — Synplify
> found a cleaner placement with the simpler FSM). 92.64× original
> Atari, BASE_DIV=84 with 15.4 MHz margin (up from 13.5 MHz at
> Step 4). Net antic_top delta vs Step 4: **+40 FF / +6 LUT /
> 0 RAM10** — pure protocol logic, no new BRAM. Total: 8722 FF /
> 11153 LUT / 155 RAM10. ram_clk 249.2 MHz / +0.99 ns; clk_pix
> 164.9 MHz / +18.9 ns; clk_bit 350.0 MHz / +2.14 ns. The CDC FIFO
> mentioned in the original spec is **deferred** — a true
> ram_clk → clk_bus FIFO would lift the rate from 1 byte/clk_bus
> cycle to ~2 bytes/clk_bus cycle (≈336 cycles/1 KB miss, the spec's
> headline target), but it only matters once bank_cache is wired to
> a real ram_clk-domain HR controller. The hyperram_shim
> integration that exposes that path is M24-int-3-equivalent
> follow-on work — captured here as future scope. 39/39 sim
> passing.
>
> Step 5b (post-rework SDC tighten): the 156 MHz SDC target was
> originally backed off in Step 3 to give the partition critical
> path room; with Step 5 closing comfortably we permanently tighten
> back to **162 MHz** (period 6.17 ns) — the BASE_DIV=90 floor
> (161.08 MHz) plus ~1 MHz margin. PnR responds by finding a better
> placement: clk_bus reaches **170.88 MHz / +0.318 ns slack**, up
> ~5 MHz vs the 156 MHz run. **95.47× original Atari**;
> **BASE_DIV=90 viable with 9.8 MHz margin** (12 clean speed grades:
> 1, 2, 3, 5, 6, 9, 10, 15, 18, 30, 45, 90). HDL unchanged — pure
> SDC change. ram_clk eased slightly to 238.0 MHz / +0.798 ns
> (still well above the 200 MHz target as PnR rebalanced effort
> toward clk_bus). The sally_clock case-statement still only
> enumerates CLOCK_MULT ∈ {1,2,3,4,6,12} — extending it to span
> 1..90 is the deferred `clock-mult-range` software work, not part
> of M-cache-rework. The hardware ceiling is now BASE_DIV=90.
>
> Step 7 actuals: wide-data path landed (CACHE_WORD_BYTES=2). Each
> per-way `bank_cache` memory replaced by a `cache_line_ram`
> instance — a portable wrapper around an EFX_RAM10 configured for
> byte-wide read + 2-byte-wide write. Refill commits 2 bytes per
> hr_rvalid pulse via byte-WE inference (Synplify maps the
> per-lane `if (we_mask[b]) mem[…][b*8 +: 8] <= …` idiom onto
> the BRAM's native byte-WE pins). EVICT_STREAM ships 2 bytes per
> cycle. CPU hit-writes update one byte lane via we_mask = 1<<byte_off.
> hr_rdata / hr_wdata widened from 8 → 16 bits all the way through
> bank_cache → sally_mem → antic_top stub; hr_burst_len now counts
> WORDS (= LINE_BYTES/WORD_BYTES − 1). Sim impact: **1 KB miss
> 1027 → 515 cycles** (clean 2×). Synth (Ti60-C4, 162 MHz target):
> clk_bus **170.2 MHz / +0.295 ns slack** — *better* than Step 5d
> (167.8 / +0.212), because the cache_line_ram module gives PnR
> a cleaner hierarchy to place. **95.10× original Atari**, fits
> BASE_DIV=90 with 9.1 MHz margin (up from 6.8 at Step 5d). Net
> delta: **+22 FF / +383 LUT / 0 RAM10** — the wider EFX_RAM10
> aspect holds the same 8 Kbit data per memory, so BRAM count is
> unchanged. ram_clk 245.4 MHz / +0.925 ns; clk_pix 164.6 MHz /
> +18.93 ns; clk_bit 304.8 MHz / +1.72 ns. 39/39 sim passing —
> tb_cache_partition exercises CACHE_WORD_BYTES=2 with a 16-bit
> mock; the other testbenches stay on WORD_BYTES=1 (default) and
> validate the legacy byte-wide path simultaneously.
>
> The original "~336 cycles" target from the spec would need
> CACHE_WORD_BYTES=4 (2 EFX_RAM10 per memory). That's feasible
> (~+64 BRAM, fits under the 256 budget) but a separate decision —
> Step 7 at WORD_BYTES=2 is the conservative landing.

#### LUT / FF cost

Estimated delta vs today's bank_cache:
- Partition logic (classifier + dual-cache + bypass mux): ~400 FF / ~700 LUT.
- cache_regs.sv: ~80 FF / ~200 LUT.
- HR burst FSM + CDC FIFO: ~150 FF / ~400 LUT.
- bus_snoop $D380+ peel-off + attribute lookup: ~70 LUT.

Total: ~**630 FF / ~1370 LUT** added. From 8009 / 10152 →
~8640 / ~11520. ~19 % of Ti60's 60K LUTs.

#### Critical-path timing

Hit-side adds:
- Partition classifier (combinational from bank_id high bits +
  attribute SRAM read): ~0.5 ns.
- 2:1 mux on cpu_rdata (code partition vs data partition): ~0.3 ns.

Today's clk_bus has +2.52 ns slack — easily absorbs ~1 ns. fMax
expected to drop from 133 MHz to ~120 MHz. Still well above 100 MHz
constraint; CLOCK_MULT=72 still hits 128.7 MHz target.

#### Implementation order

1. **`cache_regs.sv` + `bus_snoop` decode + attribute SRAM**
   ~~(~½ day)~~ **DONE 2026-05-09 (commit `9fd187e`)**. Self-
   contained register file at `$D380-$D387`, 4-bit × 4096-entry
   attribute table (2 EFX_RAM10). Software can read/write the
   table; cache ignores it for now. Closes the API shape so xtc
   can build against `bankAttrSet` / `bankAttrGet` builtins
   immediately. Synth: +2 RAM10, +45 FF, **-232 LUT** (placement
   reshuffle bonus); clk_bus 179.4 → 180.1 MHz / +0.398 ns slack
   — BASE_DIV=100 / 100× headroom preserved.
2. **Bump cache to 64 KB / 1 KB lines** ~~(~½ day)~~ **DONE
   2026-05-09 (commit `a455e91`)**. NUM_SETS=16 / NUM_WAYS=4 /
   LINE_BYTES=1024 = 64 KB. bank_cache refactored to a unified
   `block_addr` formulation so set_idx can draw from cpu_bank_id
   LSBs (the geometry needs 4 set bits but cpu_offset only has 2
   spare after a 10-bit byte_off). Synth cost: +60 RAM10 (= 64 KB
   cache backing store), +273 FF, +304 LUT. clk_bus dropped 180.1
   → 169.9 MHz / +0.063 ns slack. 94.9× original Atari — BASE_DIV
   ladder slips to 84 (was 100 baseline). Steps 3-5 will compete
   for the remaining +0.063 ns slack; if any pushes through it,
   the SDC backs off to 156 MHz target (BASE_DIV=84 still fits).
3. **Code/data partition** ~~(~2-3 days)~~ **DONE 2026-05-09
   (commit `6452d7d` + comb-loop fix)**. Two physically separate
   bank_cache instances (8 sets × 4 ways × 1 KB = 32 KB each).
   Classifier on `bank_id[15]` (region MSB from bank_xlat). HR
   port shared via OR-mux (only one cache ever non-IDLE because
   CPU stalls during any miss). $D380 / $D381 plumbing reserved
   — informational at Step 3, no dynamic geometry. Synth: +162 FF
   / +237 LUT / 0 RAM10. **Latent comb-loop discovered**: the
   live partition selector for `cache_cpu_rdata` closed a path
   through SALLY's u_cpu data→addr decode; registered the
   selector. Pipeline alignment side-benefit (rdata at N+1
   matches partition at N). SDC backed off 168 → 156 MHz; clk_bus
   159.2 MHz / +0.118 ns slack / **88.9× original Atari**, fits
   BASE_DIV=84 with 8.8 MHz margin (was 19.5 MHz post-Step 2).
4. **Streaming-bypass slot** (~1-1.5 days). Bypass caches
   addressed by `BANK_ATTR_STREAM` on the miss path. **Design
   decision (2026-05-09)**: take Option 1 — accept 1-cycle stale
   routing on the first access after a bank switch.

   The attribute SRAM in cache_regs is sync-read (1-cycle
   latency); the cache routing decision happens immediately on
   the access cycle, so the live attribute is one cycle behind.
   Three options were considered:
     1. Accept stale routing on first access after bank switch
        (functional impact: none; perf impact: <1 % pessimism
        on streaming workloads; software contract: ≥3-cycle
        gap between attribute write and first access).
     2. Add a lookahead pipeline stage (every memory access
        pays +1 clk_bus cycle — at full CLOCK_MULT this halves
        throughput; rejected).
     3. Encode attributes inline in the bank-register / bank_id
        (delete cache_regs SRAM, rework xtc API; rejected
        because it walks back Step 1 and limits future
        per-bank metadata flexibility).

   Geometry: 2 sets × 2 ways × 1 KB = 4 KB bypass per partition
   (8 KB total, 8 EFX_RAM10). bank_cache reused at the smaller
   shape — its existing block_addr decomposition handles
   NUM_SETS≥2 / NUM_WAYS≥2 cleanly.

   Routing in sally_mem: 4 quadrants — {code, data} × {partition,
   bypass}. cpu_req fires to one of four cache instances per
   access. rdata mux uses REGISTERED (is_code, is_streaming)
   selectors to align with the cache pipeline (same 1-cycle
   register pattern that fixed Step 3's comb loop). HR port
   shared via 4-way OR-mux (only one cache non-IDLE at a time
   because CPU stalls during any miss).

   Implementation steps:
     a. Wire attr_lookup_idx (sally_mem out) and attr_lookup_data
        (sally_mem in) through antic_top to cache_regs.
     b. Drive attr_lookup_idx combinationally from
        `{bank_id_w[15:14], bank_id_w[9:8], bank_id_w[7:0]}`.
     c. Add 2 new bank_cache instances (code_stream, data_stream).
     d. Compute is_streaming = attr_lookup_data[2].
     e. Route by (is_code, is_streaming) — 4 cpu_req sources.
     f. Mux outputs (registered selectors for rdata).
     g. Mux HR (4-way OR).
     h. Extend tb_cache_partition with streaming-bypass scenarios
        including the bank-switch first-access skew test.

   Expected synth cost: +8 RAM10 (155 total), +small FF/LUT for
   the additional cache instances + 4-way mux.
5. **HR multi-byte burst handshake** (~2-3 days). Extend
   bank_cache's HR port from byte-at-a-time to
   `start_addr + burst_len`. Adds CDC FIFO between ram_clk and
   clk_bus inside the cache. Independent of partition / attribute
   work but compounds the fMax win.
6. **Task-id tagging + `$D386 CURRENT_TASK_ID`** (~1 day,
   deferred). Lands when multitasking lands.

Total ~1 week of focused work for steps 1-5. Step 6 lives behind a
multitasking-OS milestone.

#### What this depends on / unblocks

- **xtc compiler work**: `bankAttrSet` / `bankAttrGet` builtins and
  the `Bank@` ARC class. xtc + xt are in lockstep so this is
  coordinated, not blocking either side.
- **Unblocks**: large allocations (Bank@-backed framebuffers,
  `LargeArray`, etc.); useful turbo-speed compute on miss-heavy
  code (3× speedup); preemptive multitasking when that lands
  (task tagging slot is already there).

### `line-buffer-distributed-lut` — RESOLVED 2026-05-08

(Originally: M-video-int's line_buffer kept 6162 FF / 5530 LUT in
distributed memory instead of BRAM-mapping. Same `bank_a` /
`bank_b` conditional read pattern that bit `bank-cache-async-read`.)

**Fixed by** rewriting `line_buffer.sv` with a `generate`-per-bank
block (same pattern as `bank_cache.sv:g_data` after M24-int-cache
v3): each bank's `mem` is its own independent 1-D memory with a
clean 1R+1W always_ff, and a combinational mux on `bank_select`
picks between the two per-bank read registers — no extra
latency.

Result: line_buffer **2 FF / 2 LUT / 2 RAMs** (was 6162 / 5530 / 0).
antic_top total **7743 FF / 9759 LUT / 85 RAMs** (-44 % FFs,
-36 % LUTs vs M-video-int's first synth).

---

## SALLY (Arlet 6502 core)

### `clock-mult-range` — RESOLVED 2026-05-09 (BASE_DIV=90 ladder)

- **Original problem**: `sally_clock` only enumerated CLOCK_MULT
  ∈ {1, 2, 3, 4, 6, 12}, capping the SALLY "turbo" at 12× original
  Atari (= 21.5 MHz) even though clk_bus closed at 100×+ in fabric.
- **Resolution path**: M-cache-rework Step 5b pinned the SDC at
  162 MHz (period 6.17 ns) and PnR achieved 170.9 MHz / +0.318 ns
  slack — clearing BASE_DIV=90's 161.08 MHz floor with ~9.8 MHz
  margin. The original target was BASE_DIV=100 (179 MHz floor)
  but the cache-rework critical-path additions ate enough slack
  that 100 fell out of reach; BASE_DIV=90 lands as the
  fmax-after-rework sweet spot with the same 12-clean-grade count
  as 96 / 84 alternatives.
- **What landed**:
  1. `sally_clock` BASE_DIV default bumped 12 → 90; sub_counter /
     sub_threshold widened to `$clog2(BASE_DIV)` bits. The case
     statement now enumerates the union of legacy {1,2,3,4,6,12}
     and the BASE_DIV=90 ladder {1,2,3,5,6,9,10,15,18,30,45,90}
     so older sim BASE_DIVs and the new production BASE_DIV both
     map cleanly. Software is responsible for picking a clock_mult
     that divides cleanly into the active BASE_DIV; non-clean
     values still produce a step pulse (rounded by integer divide)
     but the effective frequency drifts.
  2. `antic_top` phi2_tick generator generalised: BASE_DIV is a
     localparam, the counter widens to `$clog2(BASE_DIV)` bits,
     and the toggle threshold is `BASE_DIV/2 - 1` (= 44 at
     BASE_DIV=90). sally_clock instance gets the BASE_DIV
     override.
  3. SDC permanently locked at 162 MHz target (the
     `M-cache-rework Step 5b` row).
- **Speed grades exposed at BASE_DIV=90** (12 clean grades):

      CLOCK_MULT  sub_threshold   SALLY rate     × Atari
      ----------  -------------   -----------    -------
      1           89              1.79 MHz       1×  (cycle-accurate, /HALT honoured)
      2           44              3.58 MHz       2×
      3           29              5.37 MHz       3×
      5           17              8.95 MHz       5×
      6           14              10.74 MHz      6×
      9           9               16.11 MHz      9×
      10          8               17.90 MHz      10×
      15          5               26.85 MHz      15×
      18          4               32.22 MHz      18×
      30          2               53.69 MHz      30×
      45          1               80.54 MHz      45×
      90          0               161.08 MHz     90×  (= clk_bus, ceiling)

- **Constraint that doesn't relax**: ANTIC's video timing
  (clk_pix domain) is independent of CLOCK_MULT and stays correct
  regardless of SALLY rate. WSYNC release at cycle 105 also stays
  in Atari time because the cycle-105 counter ticks on `phi2_tick`
  (= 1.79 MHz) — cycle-accurate raster effects continue to work
  whatever CLOCK_MULT is.
- **Software impact**: chiplet-ext register at `$D480` already
  accepts an 8-bit CLOCK_MULT value — no software-visible address-
  map change. Existing software writing `1` keeps cycle-accurate
  behaviour. Software writing `12` (a legacy value not in the
  BASE_DIV=90 ladder) gets the rounded threshold (90/12 → 7,
  giving ~22.4 MHz / ~12.5×) — close to the original 12× behaviour
  but not exact. xtc should pick from the 12 clean grades for
  predictable rates.
- **Future BASE_DIV=100** (= 178.98 MHz floor, 100× headline) is
  out of reach until clk_bus closure recovers above 179 MHz; that's
  gated on either an HR-burst CDC FIFO landing (eases the cache
  critical path) or further fmax-pushing PnR work.

### `sally-jmp-indirect-bug` — RESOLVED 2026-05-10

- **Source**: `sim/tb_sally.sv` Phase H.1 (M24-1 verification).
- **What was wrong**: real NMOS 6502 has a famous bug where `JMP
  ($xxFF)` reads the target low byte from $xxFF and the target high
  byte from $xx00 — the high-byte fetch wraps within the same page
  instead of carrying into the next. 65C02 fixed this. Arlet's core
  defaulted to 65C02-style.
- **Resolution**: 1-line patch in Arlet's `cpu.v` PC_temp mux. JMPI1
  now computes `PC_temp = { DIMUX, ADD + 8'd1 }` — the operand-low
  byte gets `+1` with explicit 8-bit wrap, dropping the carry into
  the high byte. JMPI1 also removed from the `PC_inc = 1` list
  (the `+1` is now baked into `PC_temp`, doubling it via PC_inc
  would re-introduce the carry we're suppressing).
- **Test**: tb_sally Phase H.1 (`JMP ($02FF)` with high target byte
  at `$0200` vs red-herring at `$0300`). Now actively FAILS on
  regression instead of logging DIVERGENCE silently. Klaus 6502
  documented-instruction suite (`make klaus`) re-validated to
  confirm no other regressions.
- **Why Klaus doesn't catch this**: Klaus's only `JMP ()` test
  (`ptr_tst_ind` at $371E) places the indirect pointer mid-page —
  no $xxFF boundary, so NMOS-bug and 65C02-correct cores both pass.
  The Klaus header (line 49) explicitly states *"Tests documented
  behavior of the original NMOS 6502 only"*; the page-wrap quirk is
  undocumented hardware behaviour, deliberately out of Klaus's
  scope. tb_sally H.1 fills this gap.

### `sally-rmw-dummy-write` — RMW double-write not modelled

- **Source**: `sim/tb_sally.sv` Phase H.2 (M24-1 verification).
- **What's wrong**: real NMOS 6502 read-modify-write instructions
  (INC/DEC/ASL/LSR/ROL/ROR) do three bus phases — read original
  value, **write original value back unchanged** ("dummy write"),
  write modified value. Arlet's core does only the read + modified
  write; the dummy write is missing.
- **Software impact**: the dummy write is a side-effect-free
  rewrite of the *current* value, so for normal RAM it's harmless.
  It matters when an RMW targets a register whose write-side has
  side effects:
  - POKEY strobes (STIMER $D209, SKRES $D20A, POTGO $D20B): an
    INC at one of these triggers the strobe twice on real
    hardware, once on Arlet's core.
  - GTIA HITCLR ($D01E): same — INC HITCLR fires the collision
    clear twice on real hardware.
  - Memory-mapped I/O on cartridge slot: write-on-any-access
    bank-switching (Megacart-class) sees one fewer write event.
  Cycle counts also differ — real NMOS RMW is 6 cycles; Arlet's
  is 5.
- **Why deferred**: the fix needs an extra microcode state
  (RMW1.5 between READ and WRITE) to issue the dummy write. Not
  trivial — touches Arlet's state machine in `cpu.v`.
- **Fix shape**: add a new state between READ and the modified
  write that re-presents the same address with WE=1 and
  DO=DI (the original value just read). Then transition to the
  existing modified-write state.
- **Unblocked by**: nothing structural. Bundle with the cycle-quirk
  milestone alongside `sally-jmp-indirect-bug`.

---

## How to use this file

When you find a bug that you can't fix immediately:

1. Add an entry above following the format. Give it a short slug
   (kebab-case) so other docs can link with `Issues.md#slug`.
2. Reference it from the audit doc / commit message that found it.
3. When the prerequisite lands, fix the bug and **delete the entry**
   here. Closed issues live in git history, not this file.

This is a "stuff we know is broken" list, not a wishlist. New
features go in `future-work.md` instead.
