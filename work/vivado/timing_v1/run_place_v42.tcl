# Placement exploration: put the block builder next to the left-edge BRAM columns.
set out /home/wx/Documents/AI/SM3/work/vivado/timing_v1/place_v42
file mkdir $out
set_param general.maxThreads 6
open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/timing_v1/synth_v42/top_timing_v1_post_synth.dcp
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

create_pblock pb_block_builder
add_cells_to_pblock [get_pblocks pb_block_builder] [get_cells u_block_builder]
resize_pblock [get_pblocks pb_block_builder] -add {SLICE_X18Y30:SLICE_X38Y90}
set_property CONTAIN_ROUTING 0 [get_pblocks pb_block_builder]

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveFanoutOpt
write_checkpoint -force $out/top_timing_v1_placed.dcp
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/top_timing_v1_timing_summary_placed.rpt

set in_ports  [get_ports -filter {DIRECTION == IN && NAME != "clk" && NAME != "rst_n"}]
set out_ports [get_ports -filter {DIRECTION == OUT}]
set_false_path -from $in_ports  -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] -to $out_ports
set_false_path -from $in_ports -to $out_ports
update_timing -full
report_timing_summary -delay_type min_max -max_paths 30 \
    -file $out/top_timing_v1_internal_summary_placed.rpt
report_timing -delay_type max -max_paths 5 -nworst 1 -path_type full_clock_expanded \
    -file $out/top_timing_v1_internal_max_placed.rpt
puts "PLACE_V42_DONE"
