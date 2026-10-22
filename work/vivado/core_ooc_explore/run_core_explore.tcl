# -----------------------------------------------------------------------------
# sm3_core OOC re-implementation with timing-focused directives
# Vivado 2021.2, XCKU060-FFVA1156-2-E, 250 MHz
# -----------------------------------------------------------------------------
set out /home/wx/Documents/AI/SM3/work/vivado/core_ooc_explore
file mkdir $out
set_param general.maxThreads 6

open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc_post_synth.dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

write_checkpoint -force $out/core_ooc_explore_routed.dcp
report_utilization -file $out/core_ooc_explore_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file $out/core_ooc_explore_timing_summary.rpt

set_false_path -from [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}] \
               -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
               -to [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file $out/core_ooc_explore_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 20 -nworst 5 -path_type full_clock_expanded \
    -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -to   [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -file $out/core_ooc_explore_timing_internal_max.rpt
puts "CORE_EXPLORE_DONE"
