#!/usr/bin/env python3
"""cdc_lint.py — guard against the recurring multi-bit CDC bug class.

We shipped the SAME bug twice: a free-running multi-bit value pushed through a
plain 2-FF *bus* synchroniser, which on a multi-bit carry (e.g. 127->128) latches
a value that never existed.  See docs/Design/cdc-guidelines.md.

A plain 2-FF sync (cdc_sync_bit) is only safe for a single bit, for several
genuinely-independent 1-bit signals, or for a Gray-coded counter.  This linter
therefore flags every `cdc_sync_bit` instantiated with WIDTH > 1 UNLESS it
carries an inline justification pragma documenting why the multi-bit crossing is
safe:

    cdc_sync_bit #(.WIDTH(2)) u_x (   // cdc-lint: independent-bits — irq_n, nmi_n
    cdc_sync_bit #(.WIDTH(16)) u_y (  // cdc-lint: gray-coded
    cdc_sync_bit #(.WIDTH(8)) u_z (   // cdc-lint: flag-qualified (sampled on synced req)

Anything multi-bit that is NOT one of those should use cdc_flag_data (data+toggle)
or cdc_fifo_1w1r (async FIFO) instead.

The vetted primitive files are exempt (they ARE the reviewed building blocks).
This is the cheap pre-commit gate; `report_cdc` in the Vivado build is the
authoritative cross-check (see vivado/build.tcl).

Exit non-zero if any unannotated multi-bit crossing is found.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HDL = os.path.join(ROOT, "hdl")

# The reviewed CDC building blocks — exempt from the WIDTH>1 rule.
EXEMPT = {"cdc_sync_bit.sv", "cdc_flag_data.sv", "cdc_fifo_1w1r.sv", "hwreg_rd_cdc.sv"}

PRAGMA = "cdc-lint:"
INST_RE = re.compile(r"\bcdc_sync_bit\s*#\s*\(\s*\.WIDTH\s*\(\s*([0-9]+)\s*\)")


def sv_files():
    for dirpath, _, names in os.walk(HDL):
        for n in sorted(names):
            if n.endswith(".sv"):
                yield os.path.join(dirpath, n)


def main():
    violations = []
    n_inst = n_multibit = n_files = 0
    for path in sv_files():
        rel = os.path.relpath(path, ROOT)
        base = os.path.basename(path)
        with open(path) as f:
            lines = f.readlines()
        exempt = base in EXEMPT
        for i, line in enumerate(lines):
            if "cdc_sync_bit" in line and "#" in line:
                m = INST_RE.search(line)
                if not m:
                    continue
                n_inst += 1
                width = int(m.group(1))
                if width <= 1:
                    continue
                n_multibit += 1
                if exempt:
                    continue
                # justification may sit on this line or the 2 preceding lines
                window = "".join(lines[max(0, i - 2): i + 1])
                if PRAGMA not in window:
                    violations.append((rel, i + 1, width, line.strip()))
        n_files += 1

    print(f"cdc-lint: scanned {n_files} .sv files; "
          f"{n_inst} cdc_sync_bit instances ({n_multibit} multi-bit).")
    if violations:
        sys.stderr.write("\ncdc-lint: UNANNOTATED multi-bit 2-FF crossings:\n")
        for rel, ln, w, txt in violations:
            sys.stderr.write(f"  {rel}:{ln}  WIDTH={w}  {txt}\n")
        sys.stderr.write(
            "\nEach must use cdc_flag_data / cdc_fifo_1w1r, OR carry a\n"
            "  // cdc-lint: <gray-coded|independent-bits|flag-qualified — reason>\n"
            "justification.  See docs/Design/cdc-guidelines.md.\n")
        return 1
    print("cdc-lint: OK — every multi-bit 2-FF crossing is justified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
