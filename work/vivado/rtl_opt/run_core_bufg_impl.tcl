# Implement an existing sm3_core_bufg post-synth checkpoint.
# Usage: vivado -mode batch -source run_core_bufg_impl.tcl -tclargs <dcp> <outdir> <tag>
set dcp [lindex $argv 0]
set out [lindex $argv 1]
set tag [lindex $argv 2]
file mkdir $out
set_param general.maxThreads 6

open_checkpoint $dcp
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $out/${tag}_routed.dcp
report_utilization    -file $out/${tag}_utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 20 \
                      -file $out/${tag}_timing_summary_routed.rpt

set_false_path -from [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}] \
               -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
               -to [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file $out/${tag}_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 20 -nworst 5 -path_type full_clock_expanded \
    -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -to   [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -file $out/${tag}_timing_internal_max.rpt
puts "CORE_BUFG_IMPL_DONE $tag"
