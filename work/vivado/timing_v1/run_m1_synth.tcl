# -----------------------------------------------------------------------------
# M1 cluster synthesis - 16 cores total, 250 MHz
#
# Usage:
#   vivado -mode batch -source run_m1_synth.tcl -tclargs <CLUSTER_NUM>
#
# CLUSTER_NUM=4 -> 4 clusters x 4 cores  (4x4)
# CLUSTER_NUM=2 -> 2 clusters x 8 cores  (2x8)
#
# The synthesis checkpoint keeps the original XDC only.  The internal
# (register-to-register) timing report is produced after applying the same
# data/I/O false paths used by the frozen v42 sign-off flow.
# -----------------------------------------------------------------------------
if {[llength $argv] != 1} {
    error "usage: vivado -mode batch -source run_m1_synth.tcl -tclargs <CLUSTER_NUM>"
}
set cluster_num [lindex $argv 0]
if {$cluster_num != 2 && $cluster_num != 4} {
    error "CLUSTER_NUM must be 2 or 4, got $cluster_num"
}

set repo    /home/wx/Documents/AI/SM3
set root    $repo/sm3_fpga/latest/milestone6
set work    $repo/work/vivado/timing_v1
set cores   16
set core_per [expr {$cores / $cluster_num}]
set run     m1_cluster_${cluster_num}x${core_per}
set out     $work/$run/synth
set part    xcku060-ffva1156-2-e
set xdc     $repo/work/vivado/top_16c_32ctx/top_16c_32ctx.xdc

set rtl_files [list \
    $root/rtl/core/sm3_core.sv \
    $root/rtl/front_end/sm3_block_builder.sv \
    $root/rtl/context/sm3_block_pool.sv \
    $root/rtl/context/sm3_pool_engine.sv \
    $root/rtl/top/sm3_accel_cluster.sv \
    $root/rtl/top/sm3_accel_cluster_top.sv]

file mkdir $out
set_param general.maxThreads 6

puts "M1_SYNTH_START run=$run cluster_num=$cluster_num core_per=$core_per"
read_verilog -sv {*}$rtl_files
read_xdc $xdc

synth_design -top sm3_accel_cluster_top -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt \
    -generic CORE_NUM=$cores \
    -generic CTX_NUM=32 \
    -generic FAST_DEPTH=32 \
    -generic POOL_DEPTH=512 \
    -generic CLUSTER_NUM=$cluster_num

write_checkpoint -force $out/top_m1_cluster_post_synth.dcp

report_utilization -file $out/post_synth_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 6 \
    -file $out/post_synth_utilization_hier.rpt
report_ram_utilization -file $out/post_synth_ram_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/post_synth_timing_summary.rpt
report_timing -delay_type max -max_paths 30 -nworst 5 \
    -path_type full_clock_expanded \
    -file $out/post_synth_timing_max.rpt
check_timing -verbose -file $out/post_synth_check_timing.rpt
report_high_fanout_nets -fanout_greater_than 100 -max_nets 100 -timing \
    -file $out/post_synth_high_fanout.rpt
if {[catch {report_clock_utilization -file $out/post_synth_clock_utilization.rpt} msg]} {
    puts "M1_SYNTH_NOTE report_clock_utilization: $msg"
}
if {[catch {report_control_sets -verbose -file $out/post_synth_control_sets.rpt} msg]} {
    puts "M1_SYNTH_NOTE report_control_sets: $msg"
}
if {[catch {report_design_analysis -congestion \
        -file $out/post_synth_congestion.rpt} msg]} {
    puts "M1_SYNTH_NOTE report_design_analysis: $msg"
}

# Raw timing (with the OOC port delays) and the internal sign-off view.
set wns_raw "NA"
set raw_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $raw_paths] > 0} {
    set wns_raw [get_property SLACK [lindex $raw_paths 0]]
}

set in_ports  [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set out_ports [get_ports -filter {DIRECTION == OUT}]
set_false_path -from $in_ports  -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] -to $out_ports
set_false_path -from $in_ports -to $out_ports
set_false_path -hold -from $in_ports
set_false_path -hold -to $out_ports
update_timing -full

set wns_internal "NA"
set int_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $int_paths] > 0} {
    set wns_internal [get_property SLACK [lindex $int_paths 0]]
}

report_timing_summary -delay_type min_max -max_paths 30 \
    -file $out/post_synth_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_synth_timing_max100_internal.rpt
report_timing -delay_type max -max_paths 5 -nworst 1 \
    -path_type full_clock_expanded \
    -file $out/post_synth_timing_detail_internal.rpt

set dcp_sha [lindex [split [exec sha256sum $out/top_m1_cluster_post_synth.dcp] " "] 0]
set git_sha [exec git -C $repo rev-parse HEAD]
set git_status [string trim [exec git -C $repo status --porcelain]]
set fh [open $out/manifest.md w]
puts $fh "# M1 cluster ${cluster_num}x${core_per} synthesis manifest"
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
puts $fh "| synthesis | default directive, flatten_hierarchy=rebuilt, mode=out_of_context |"
puts $fh "| maxThreads | 6 |"
puts $fh "| git HEAD | `$git_sha` |"
puts $fh "| git dirty | `[expr {$git_status eq "" ? "clean" : $git_status}]` |"
puts $fh "| XDC | `$xdc` |"
puts $fh "| XDC SHA256 | `[lindex [split [exec sha256sum $xdc] " "] 0]` |"
foreach f $rtl_files {
    puts $fh "| RTL [file tail $f] SHA256 | `[lindex [split [exec sha256sum $f] " "] 0]` |"
}
puts $fh "| post-synth DCP | `$out/top_m1_cluster_post_synth.dcp` |"
puts $fh "| post-synth DCP SHA256 | `$dcp_sha` |"
puts $fh "| raw post-synth WNS | `$wns_raw ns` |"
puts $fh "| internal post-synth WNS | `$wns_internal ns` |"
puts $fh ""
puts $fh "Internal timing applies false paths from data inputs to sequential cells,"
puts $fh "from sequential cells to data outputs, input-to-output, and the hold"
puts $fh "equivalents.  The top-level 1 ns I/O budget is not part of this metric."
close $fh

puts "M1_SYNTH_GATE WNS_RAW=$wns_raw WNS_INTERNAL=$wns_internal"
puts "M1_SYNTH_DONE run=$run dcp=$out/top_m1_cluster_post_synth.dcp"
