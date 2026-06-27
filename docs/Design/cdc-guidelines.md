# CDC guidelines — never free-run a multi-bit value across clocks

We shipped the **same** clock-domain-crossing bug twice, each costing most of a
session and a wrong-fix detour:

- **row-128 "rainbow line"** — `fetch_row` (12-bit) free-running 2-FF bus-synced
  `clk_pix → clk_sys`. On the 127→128 carry, some destination flops latched the
  old bits and some the new → a row number that never existed → wrong DDR address
  → a garbage scanline. Worst at 0x7F→0x80.
- **sprite-cursor flicker** — `pix_next_vcount` (12-bit) the same way
  `clk_pix → clk_fetch`. A torn carry → wrong arena row → a foreign row splatted
  into the line cache (the cursor "blob").

Both are one failure class: **a multi-bit value sampled into another clock by a
plain 2-FF synchroniser.** A 2-FF sync resolves metastability for *one* bit; it
does nothing to keep *N* bits mutually consistent across a transition.

## The rule

A plain 2-FF synchroniser (`cdc_sync_bit`) is safe **only** for:

1. a **single bit**, or
2. several **genuinely independent** 1-bit level signals (e.g. `{irq_n, nmi_n}`),
   where no consumer compares them as a group, or
3. a **Gray-coded** counter (exactly one bit changes per increment).

For **anything else multi-bit**, use one of:

| Transfer | Primitive | When |
|----------|-----------|------|
| One word per event, data stable around an event flag | **`cdc_flag_data`** (data + toggle) | line-rate / frame-rate / register snapshots — the fix both bugs needed |
| Streaming / decoupled producer-consumer | **`cdc_fifo_1w1r`** (gray-pointer async FIFO) | bursts, rate mismatch |
| Counter readback | Gray encode at source, `cdc_sync_bit`, decode at dest | monotonic counters (e.g. `bl_seq`) |
| Req/ack with payload | flag-qualified capture (`hwreg_rd_cdc` pattern) | bidirectional register access |

`cdc_flag_data` is the canonical answer: latch the data and flip a 1-bit toggle on
the source event; only the toggle crosses asynchronously; the destination samples
the (now-settled) data on the synced toggle edge. The data never crosses while
changing, so it can never tear. See `hdl/cdc_flag_data.sv` and
`sim/tb_cdc_flag_data.sv`.

## Convention

- Name CDC nets and instances `*_sync` / `*_cdc` so review can spot crossings.
- Every `cdc_sync_bit` with `WIDTH > 1` **must** carry an inline justification on
  (or just above) the instantiation:

  ```systemverilog
  // cdc-lint: independent-bits — irq_n, nmi_n sampled separately
  cdc_sync_bit #(.WIDTH(2)) u_sync_irq_nmi ( ... );

  // cdc-lint: gray-coded — one bit changes per increment
  cdc_sync_bit #(.WIDTH(16)) u_sync_bl_seq ( ... );
  ```

  Recognised tags: `independent-bits`, `gray-coded`, `flag-qualified`. Anything
  else that is genuinely multi-bit-changing should not be on a 2-FF sync at all.
- Pair an event-qualified transfer with a `set_false_path -from` on the source
  holding register (see `vivado/constraints/cdc_fetch_row.xdc`,
  `cdc_sprite_vcount.xdc`). The RTL closes timing without it; the constraint is
  hygiene + future-proofing against a long route.

## Gates

- **Pre-commit (cheap):** `tools/cdc_lint.py` (`make -C tools cdc-lint`) — fails on
  any unannotated multi-bit 2-FF crossing. Runs in CI.
- **Build (authoritative):** `report_cdc` in `vivado/build.tcl` — Vivado's own
  structural CDC analysis over the placed netlist, written to the report dir.
