set out /home/wx/Documents/AI/SM3/work/vivado/timing_v1/route_v42_eco1
file mkdir $out
set_param general.maxThreads 6
open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/timing_v1/route_v42_physopt/top_timing_v1_physopt.dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
set in_ports  [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set out_ports [get_ports -filter {DIRECTION == OUT}]
set_false_path -from $in_ports  -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] -to $out_ports
set_false_path -from $in_ports -to $out_ports
set_false_path -hold -from $in_ports
set_false_path -hold -to $out_ports
set c [get_cells u_engine/g_core[9].u_core/tj_rot_q_reg[9]]
puts "BEFORE: [get_property LOC $c] [get_property BEL $c]"
place_cell $c [get_sites SLICE_X4Y152]
puts "AFTER: [get_property LOC $c] [get_property BEL $c]"
route_design -directive Explore
write_checkpoint -force $out/top_timing_v1_eco.dcp
report_timing_summary -delay_type min_max -max_paths 30 -file $out/top_timing_v1_internal_summary_eco.rpt
report_timing -delay_type max -max_paths 5 -nworst 1 -path_type full_clock_expanded -file $out/top_timing_v1_internal_max_eco.rpt
report_timing -delay_type min -max_paths 5 -nworst 1 -path_type full_clock_expanded -file $out/top_timing_v1_internal_min_eco.rpt
puts "ECO_V42_1_DONE"
