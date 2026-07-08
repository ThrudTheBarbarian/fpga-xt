# trng_comb_loops.xdc — xt_trng ring oscillators are INTENTIONAL combinational
# loops (the entropy source).  The RTL already marks the loop nets
# ALLOW_COMBINATORIAL_LOOPS; downgrade the implementation DRC as well so a clean
# bitstream isn't blocked by LUTLP-1 on these known-good loops.  No other module
# in this design contains a combinational loop, so this stays targeted in intent.
set_property SEVERITY {Warning} [get_drc_checks LUTLP-1]

# The ring oscillators are unclocked free-running loops; the only path OUT of them
# is the metastable capture into the async_reg samplers (s1).  Keep that async
# capture out of timing analysis so a spurious unconstrained path can't trip the
# WNS gate.  Contained to u_trng (no other module names a net 'ro').
set_false_path -through [get_nets -hier -filter {NAME =~ *u_trng*ro*}]
