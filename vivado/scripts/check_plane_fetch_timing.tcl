# Open the post-route checkpoint and report any timing violations that
# involve plane_fetch (the read-path FSM lives on clk_sys). Settles whether
# the AR=1/R=0 read hang is a clk_sys setup miss on plane_fetch or structural.
open_checkpoint C:/Users/user/fpga/build/post_route.dcp

puts "==== ALL setup-violated paths involving u_plane_fetch* ===="
set pf [get_cells -hier -filter {NAME =~ *u_plane_fetch*}]
if {[llength $pf] == 0} {
    puts ">> NO plane_fetch cells found (name mismatch)"
} else {
    report_timing -setup -nworst 20 -slack_lesser_than 0 \
        -through $pf -file C:/Users/user/fpga/build/pf_violated.rpt
    puts ">> wrote pf_violated.rpt"
}

puts "==== worst 10 setup paths anywhere through plane_fetch (any slack) ===="
report_timing -setup -nworst 10 -through $pf \
    -file C:/Users/user/fpga/build/pf_worst.rpt
puts ">> wrote pf_worst.rpt"
