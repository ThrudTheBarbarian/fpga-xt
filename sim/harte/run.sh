#!/bin/sh
# Run the Harte harness on cached .vec files (all, or the listed opcodes). Summarize.
#   iverilog -g2012 -o /tmp/h.vvp -s tb_xt6502f_harte sim/tb_xt6502f_harte.sv hdl/xt6502f/xt6502f.sv
#   sim/harte/run.sh [op op ...]
D=$(dirname "$0"); VVP=${VVP:-/tmp/h.vvp}
ops="$*"; [ -z "$ops" ] && ops=$(ls "$D"/vec/*.vec 2>/dev/null | sed 's#.*/##;s#\.vec##')
pass=0; fail=0
for op in $ops; do
    r=$(vvp "$VVP" +VEC="$D/vec/$op.vec" 2>&1 | grep -oE '(OK — [0-9]+/[0-9]+ cases pass|[0-9]+/[0-9]+ FAIL)')
    case "$r" in *pass) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "  FAIL $op: $r" ;; esac
done
echo "harte: $pass opcode(s) pass, $fail fail"
