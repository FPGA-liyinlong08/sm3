# -----------------------------------------------------------------------------
# M1 cluster place & route - 16 cores total, 250 MHz
#
# Usage:
#   vivado -mode batch -source run_m1_place_route.tcl \
#          -tclargs <CLUSTER_NUM> <none|pblock>
#
# CLUSTER_NUM=2 -> 2 clusters x 8 cores (2x8)
# CLUSTER_NUM=4 -> 4 clusters x 4 cores (4x4)
#
# Both layouts use the same OOC constraints, directives and seeds.  The pblock
# layout keeps the local block builders near the left-edge BRAM columns, as in
# the frozen v42 flow.  Internal timing is measured after the data/I/O false
# paths; the post-place raw report is kept for reference.
# -----------------------------------------------------------------------------
if {[llength $argv] != 2} {
    error "usage: vivado -mode batch -source run_m1_place_route.tcl -tclargs <CLUSTER_NUM> <none|pblock>"
}
set cluster_num [lindex $argv 0]
set layout      [lindex $argv 1]
if {$cluster_num != 2 && $cluster_num != 4} {
    error "CLUSTER_NUM must be 2 or 4, got $cluster_num"
}
if {$layout ne "none" && $layout ne "pblock"} {
    error "layout must be none or pblock, got $layout"
}

set repo    /home/wx/Documents/AI/SM3
set work    $repo/work/vivado/timing_v1
set cores   16
set core_per [expr {$cores / $cluster_num}]
set run     m1_cluster_${cluster_num}x${core_per}
set synth   $work/$run/synth
set out     $work/$run/place_route_$layout
set part    xcku060-ffva1156-2-e
set synth_dcp $synth/top_m1_cluster_post_synth.dcp
set placed_dcp $out/top_m1_cluster_placed.dcp
set routed_dcp $out/top_m1_cluster_routed.dcp

file mkdir $out
set_param general.maxThreads 6

puts "M1_PNR_START run=$run layout=$layout"
open_checkpoint $synth_dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

if {$layout eq "pblock"} {
    create_pblock pb_cluster_builders
    add_cells_to_pblock [get_pblocks pb_cluster_builders] \
        [get_cells -hier -filter {NAME =~ "*u_block_builder"}]
    resize_pblock [get_pblocks pb_cluster_builders] -add {SLICE_X18Y30:SLICE_X38Y90}
    set_property CONTAIN_ROUTING 0 [get_pblocks pb_cluster_builders]
}

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveFanoutOpt
write_checkpoint -force $placed_dcp

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/post_place_timing_summary.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_place_timing_max100.rpt
report_utilization -file $out/post_place_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 6 \
    -file $out/post_place_utilization_hier.rpt
report_high_fanout_nets -fanout_greater_than 100 -max_nets 100 -timing \
    -file $out/post_place_high_fanout.rpt
if {[catch {report_design_analysis -congestion \
        -file $out/post_place_congestion.rpt} msg]} {
    puts "M1_PNR_NOTE post-place congestion: $msg"
}

set wns_place_raw "NA"
set p [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $p] > 0} {
    set wns_place_raw [get_property SLACK [lindex $p 0]]
}

# OOC I/O paths are not part of the sign-off metric; apply the same data/I/O
# false paths as the frozen v42 flow before measuring internal timing and
# before routing.  The placed checkpoint above keeps the raw XDC only.
set in_ports  [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set out_ports [get_ports -filter {DIRECTION == OUT}]
set_false_path -from $in_ports  -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] -to $out_ports
set_false_path -from $in_ports -to $out_ports
set_false_path -hold -from $in_ports
set_false_path -hold -to $out_ports
update_timing -full

set wns_place "NA"
set p [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $p] > 0} {
    set wns_place [get_property SLACK [lindex $p 0]]
}

report_timing_summary -delay_type min_max -max_paths 30 \
    -file $out/post_place_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_place_timing_max100_internal.rpt

route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $routed_dcp

set wns_route "NA"
set p [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $p] > 0} {
    set wns_route [get_property SLACK [lindex $p 0]]
}

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/post_route_timing_summary.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_route_timing_max100.rpt
report_timing -delay_type max -max_paths 5 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_route_timing_detail.rpt
report_timing -delay_type min -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_route_timing_min100.rpt
report_utilization -file $out/post_route_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 6 \
    -file $out/post_route_utilization_hier.rpt
report_ram_utilization -file $out/post_route_ram_utilization.rpt
report_high_fanout_nets -fanout_greater_than 100 -max_nets 100 -timing \
    -file $out/post_route_high_fanout.rpt
if {[catch {report_clock_utilization \
        -file $out/post_route_clock_utilization.rpt} msg]} {
    puts "M1_PNR_NOTE clock utilization: $msg"
}
if {[catch {report_control_sets -verbose \
        -file $out/post_route_control_sets.rpt} msg]} {
    puts "M1_PNR_NOTE control sets: $msg"
}
if {[catch {report_design_analysis -congestion \
        -file $out/post_route_congestion.rpt} msg]} {
    puts "M1_PNR_NOTE post-route congestion: $msg"
}
if {[catch {report_route_status \
        -file $out/post_route_route_status.rpt} msg]} {
    puts "M1_PNR_NOTE route status: $msg"
}
if {[catch {check_timing -verbose \
        -file $out/post_route_check_timing.rpt} msg]} {
    puts "M1_PNR_NOTE check timing: $msg"
}
if {[catch {report_drc -file $out/post_route_drc.rpt} msg]} {
    puts "M1_PNR_NOTE DRC: $msg"
}
if {[catch {report_methodology -file $out/post_route_methodology.rpt} msg]} {
    puts "M1_PNR_NOTE methodology: $msg"
}

set synth_sha [lindex [split [exec sha256sum $synth_dcp] " "] 0]
set placed_sha [lindex [split [exec sha256sum $placed_dcp] " "] 0]
set routed_sha [lindex [split [exec sha256sum $routed_dcp] " "] 0]
set git_sha [exec git -C $repo rev-parse HEAD]
set git_status [string trim [exec git -C $repo status --porcelain]]
set fh [open $out/manifest.md w]
puts $fh "# M1 cluster ${cluster_num}x${core_per} place & route manifest"
puts $fh ""
puts $fh "| item | value |"
puts $fh "|---|---|"
puts $fh "| date | [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] |"
puts $fh "| Vivado | [version -short] |"
puts $fh "| part | `$part` |"
puts $fh "| top | `sm3_accel_cluster_top` |"
puts $fh "| CORE_NUM | $cores |"
puts $fh "| CTX_NUM | 32 |"
puts $fh "| FAST_DEPTH | 32 |"
puts $fh "| POOL_DEPTH | 512 |"
puts $fh "| CLUSTER_NUM | $cluster_num |"
puts $fh "| CORE_PER_CLUSTER | $core_per |"
puts $fh "| layout | `$layout` |"
if {$layout eq "pblock"} {
    puts $fh "| pblock | `pb_cluster_builders` = SLICE_X18Y30:SLICE_X38Y90, CONTAIN_ROUTING=0 |"
}
puts $fh "| opt | Explore |"
puts $fh "| place | Explore (default seed) |"
puts $fh "| pre-route phys_opt | AggressiveFanoutOpt |"
puts $fh "| route | Explore (default seed) |"
puts $fh "| post-route phys_opt | AggressiveExplore |"
puts $fh "| maxThreads | 6 |"
puts $fh "| git HEAD | `$git_sha` |"
puts $fh "| git dirty | `[expr {$git_status eq "" ? "clean" : $git_status}]` |"
puts $fh "| synth DCP | `$synth_dcp` |"
puts $fh "| synth DCP SHA256 | `$synth_sha` |"
puts $fh "| placed DCP SHA256 | `$placed_sha` |"
puts $fh "| routed DCP | `$routed_dcp` |"
puts $fh "| routed DCP SHA256 | `$routed_sha` |"
puts $fh "| raw post-place WNS | `$wns_place_raw ns` |"
puts $fh "| internal post-place WNS | `$wns_place ns` |"
puts $fh "| internal post-route WNS | `$wns_route ns` |"
puts $fh ""
puts $fh "Internal timing applies false paths from data inputs to sequential cells,"
puts $fh "from sequential cells to data outputs, input-to-output, and the hold"
puts $fh "equivalents.  The top-level 1 ns I/O budget is not part of this metric."
close $fh

puts "M1_PNR_GATE LAYOUT=$layout WNS_PLACE_RAW=$wns_place_raw WNS_PLACE=$wns_place WNS_ROUTE=$wns_route"
puts "M1_PNR_DONE run=$run layout=$layout dcp=$routed_dcp"
