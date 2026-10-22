set out /home/wx/Documents/AI/SM3/work/vivado/timing_v1/route_v42_internal
file mkdir $out
set_param general.maxThreads 6
open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/timing_v1/place_v42/top_timing_v1_placed.dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

# OOC I/O paths have unmodeled clock-tree/IO delay; sign off on internal
# register-to-register paths and keep the router from spending hold-fix
# effort (and adding detour delays) on the unmodeled port paths.
set in_ports  [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set out_ports [get_ports -filter {DIRECTION == OUT}]
set_false_path -from $in_ports  -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] -to $out_ports
set_false_path -from $in_ports -to $out_ports
set_false_path -hold -from $in_ports
set_false_path -hold -to $out_ports

route_design -directive Explore
write_checkpoint -force $out/top_timing_v1_routed.dcp
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 30 -file $out/top_timing_v1_timing_summary_routed.rpt
report_timing_summary -delay_type min_max -max_paths 30 -file $out/top_timing_v1_internal_summary_routed.rpt
report_timing -delay_type max -max_paths 5 -nworst 1 -path_type full_clock_expanded -file $out/top_timing_v1_internal_max_routed.rpt
report_timing -delay_type min -max_paths 5 -nworst 1 -path_type full_clock_expanded -file $out/top_timing_v1_internal_min_routed.rpt
puts "ROUTE_INTERNAL_DONE"
