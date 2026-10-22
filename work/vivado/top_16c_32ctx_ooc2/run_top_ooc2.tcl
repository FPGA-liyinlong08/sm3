# -----------------------------------------------------------------------------
# sm3_accel_top 16C/32ctx/512pool re-implementation with fanout/timing directives
# Starts from the existing post-synthesis checkpoint.
# -----------------------------------------------------------------------------
set out /home/wx/Documents/AI/SM3/work/vivado/top_16c_32ctx_ooc2
file mkdir $out
set_param general.maxThreads 6

open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/top_16c_32ctx_ooc/top_16c_32ctx_ooc_post_synth.dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveFanoutOpt
route_design -directive Explore

write_checkpoint -force $out/top_ooc2_routed.dcp
report_utilization -hierarchical -file $out/top_ooc2_utilization_routed.rpt
report_utilization -file $out/top_ooc2_utilization_flat_routed.rpt
report_ram_utilization -file $out/top_ooc2_ram_utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/top_ooc2_timing_summary_routed.rpt
report_timing -delay_type max -max_paths 30 -nworst 5 -path_type full_clock_expanded \
    -file $out/top_ooc2_timing_max_routed.rpt
report_design_analysis -congestion -file $out/top_ooc2_congestion.rpt
puts "TOP_OOC2_DONE"
