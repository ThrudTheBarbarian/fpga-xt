# Banked-stack context switching

## Motivation

The 6502 SALLY's hardware stack is now 4 KB of internal BRAM (see
[6502-embellishments.md](6502-embellishments.md)).  A multitasking kernel
that preempts or yields across tasks needs to **save and restore the entire
stack on every context switch**.  At 4 KB per task, copying the full stack
to/from DDR3 takes ~3.4 μs at 1.2 GB/s HP-port bandwidth.

For a system running 2–8 tasks, the cost is wasteful when we have enough
BRAM to keep most stacks resident and switch between them by changing a
**bank-select** register.

## Architecture

### Stack banks

The 4 KB per-task stack RAM is replaced by an array of **8 banks**, each
4 KB (32 KB total = 8 × RAMB36E1s, well within the 280 RAMB36E1-equivalent
blocks on the Zynq-7020).

At any moment a bank is in one of three states:

| State     | Meaning |
|-----------|---------|
| **Active** | Mapped into the CPU's stack space — the currently running task. |
| **Resident** | Holds a task's stack in BRAM, ready to be switched to in 1 cycle. |
| **Free** | Unallocated scratch. If it previously held a task, that task's stack has been evicted to DDR3. |

### One sacrificed slot

With 8 banks we keep **exactly 1 Free** at all times.  This sacrifices one
potential task slot so loading a cold task from DDR3 never requires an
eviction first — the Free bank is the landing pad.

```
┌─────┬──────────┬──────────┐
│ Bank│ Role     │ State    │
├─────┼──────────┼──────────┤
│ 0   │ Task A   │ Active   │
│ 1   │ Task B   │ Resident │
│ 2   │ Task C   │ Resident │
│ 3   │ Task D   │ Resident │
│ 4   │ Task E   │ Resident │
│ 5   │ Task F   │ Resident │
│ 6   │ Task G   │ Resident │
│ 7   │ —        │ Free     │  ← landing pad, always available
└─────┴──────────┴──────────┘
```

Up to **7 tasks** can be in BRAM simultaneously (1 Active + 6 Resident).
A task whose stack is in DDR3 must be loaded into the Free slot before it
can run.

### Context switch: Resident task (fast path)

```
1.  Save SP[11:0] → Active bank's SP save register
2.  Write bank_select ← Resident bank ID
3.  Write SP[11:0] ← saved SP of new task
4.  Reset new Active bank's age to 0
5.  Increment ages of all other Resident banks
```

Cost: **1–4 cycles** (register writes, no DDR3 traffic).

### Context switch: Cold task from DDR3 (slow path)

```
1.  Save SP[11:0] → Active bank's SP save register
2.  Mark previously Active bank → Resident
3.  DMA: DDR3_addr[task] → bank[Free]   (4 KB, 64 × 64-bit HP beats)
4.  Write bank_select ← Free bank ID
5.  Write SP[11:0] ← saved SP of loaded task
6.  Mark bank as Active
7.  Reset new Active bank's age to 0
8.  Increment ages of all Resident banks
9.  Pick a Resident to evict → mark its bank as new Free
10. DMA: bank[evicted] → DDR3_addr[evicted_task]   (background, non-blocking)
```

Step 9–10 run in the background after the switched-in task is already
executing.  The eviction DMA uses spare HP-port bandwidth and sets a
"busy evicting" flag that blocks the next cold load until complete.

Cost to switch-in latency: **~3.4 μs** (DMA load only).  The eviction
hides behind subsequent execution.

### LRU eviction policy

Each bank has a 3-bit age counter.  On every context switch:

1. The new Active bank's age is reset to 0.
2. All other Resident banks' ages are incremented (saturating at 7).

When the kernel needs to pick a Resident for eviction (step 9 above), it
selects the bank with the highest age — the least-recently touched.

### Idle-task pre-eviction

A system call or idle-thread hint can trigger a background DMA that writes
a Resident bank to DDR3, converting it to Free early.  This hides the
eviction latency entirely — by the time a cold task wants that bank, it's
already Free.

### DDR3 backing store layout

```
0x3300_0000 ┬─────────────────────────────────────┐
            │ Stack page 0  (4 KB)                │
0x3300_1000 ├─────────────────────────────────────┤
            │ Stack page 1  (4 KB)                │
0x3300_2000 ├─────────────────────────────────────┤
            │ ...                                 │
0x3300_F000 ├─────────────────────────────────────┤
            │ Stack page 15 (4 KB)                │
0x3301_0000 └─────────────────────────────────────┘
```

64 pages × 4 KB = 256 KB supports up to 64 tasks with DDR3-backed stacks.
A 12-bit task ID indexes into this table.

## Hardware cost

### BRAM

- 8 × RAMB36E1 (or 16 × RAMB18E1 in pairs) = 32 KB total.
  Zynq-7020 has 140 RAMB36E1-equivalent blocks → ~6% of total BRAM.

- The alias window mux (addr $0100–$01FF → bank_base + $F00–$FFF)
  is just a mux on the read-data path, gated by bank_select.

### Registers

- **bank_select** (3 bits): current Active bank.
- **age[0..7]** (8 × 3 bits): LRU age counters.
- **SP_save[0..7]** (8 × 12 bits): saved SP value per bank.

Total: ~120 flip-flops.

### DMA

Reuse the existing AXI HP master with a small state machine counting 64
× 8-byte beats.  Two channel contexts (load and evict) so eviction can
run in the background while the CPU executes.

## Integration with FreeRTOS

### Task-control-block additions

Each TCB gains:

```
uint8_t stack_bank;    /* 0–7 bank ID, or 0xFF if in DDR3 */
uint16_t stack_sp;     /* saved SP[11:0] */
```

### Context-switch hook

FreeRTOS's `vPortSVCHandler` or `xPortPendSVHandler` (or equivalent
PendSV_IRQHandler) calls a short assembly sequence:

```
PendSV_Handler:
    ; Save current task context (standard ARMv7-M registers) — already done
    ;  by FreeRTOS port.  Then:
    LDR   r0, =SALLY_STACK_SWITCH    ; memory-mapped register
    LDRB  r1, [r2, #TCB_OFFSET_BANK] ; new task's bank ID
    STRB  r1, [r0]                    ; triggers hardware bank switch
    ; Switch SP within SALLY to the saved value (handled by hardware)
    ; Restore new task context (standard FreeRTOS register restore)
    BX    lr
```

The hardware handles the fast/slow path transparently — the ARM side only
writes the bank ID.  If the bank is DDR3-backed, the SALLY core stalls
for ~3.4 μs while the DMA loads it into the Free slot.

### Coexistence

The SALLY CPU is a coprocessor from FreeRTOS's perspective.  The ARM
Cortex-A9s run the FreeRTOS scheduler and dispatch work to the SALLY via
a command ring.  The SALLY's banked-stack hardware is independent of the
ARM's MMU — no cache coherency issues since the DMA is between the AXI HP
port and the PL BRAM, never touching the ARM's L1/L2.

## Comparison

| Metric                         | Copy-every-time | Banked (8 slots) |
|--------------------------------|----------------:|-----------------:|
| Fast switch (resident→resident)| 3.4 μs          | **~0 μs** (≈4 cycles) |
| Cold load (DDR3→Free slot)     | 3.4 μs          | 3.4 μs           |
| Eviction                       | —               | 3.4 μs (background) |
| Max resident tasks             | 0               | 7                |
| BRAM used                      | 4 KB            | 32 KB            |

The banked approach turns the common case (switching between actively
running tasks) into a register write rather than a 4 KB DMA.  Cold loads
are unavoidable but run at full HP-port bandwidth, and the eviction step
hides behind normal task execution.
