# cpu_insn — CPU: Basic instructions

**Pins down:** the documented instruction set — results, addressing modes,
register effects.

Source: [`src/cpu_insn.s`](src/cpu_insn.s). At 1,592 lines the largest test
source in the suite; asserts by control flow.

Like [`cpu_flags`](cpu_flags.md), this is breadth that **Tom Harte subsumes**.
`emu/test/harte.c` checks final registers, final RAM *and* the exact
cycle-by-cycle bus trace for all 256 opcodes across 277,600 cases — a strictly
stronger check than "did the documented instructions produce the right answers".

Kept in the index for completeness. The interesting `cpu_*` tests for us are the
ones Harte **cannot** cover because it ties the interrupt lines inactive and runs
no system around the CPU:

* [`cpu_clisei`](cpu_clisei.md) — interrupt poll timing *(reimplemented as
  `emu/test/irq.c`, passing)*
* [`cpu_bugs`](cpu_bugs.md) — NMI/BRK interaction in a system context
* [`cpu_timing`](cpu_timing.md) — cycle counts measured with DMA present
