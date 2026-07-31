# cpu_flags — CPU: Flags

**Pins down:** flag behaviour across the instruction set.

Source: [`src/cpu_flags.s`](src/cpu_flags.s). Asserts by control flow — no
`_ASSERT` macros, so a failure is a `_FAIL` from inside the checking code.

This is breadth coverage of N/V/Z/C across operations, and it is the part of the
suite most thoroughly subsumed by **Tom Harte**: `emu/test/harte.c` checks the
full `P` register against the expected value on all 277,600 cases, so every flag
result for every opcode and addressing mode is already gated.

Listed here for completeness rather than because it needs separate
implementation attention. If Harte passes and this fails, suspect the harness or
a system-level interaction rather than the flag logic.
