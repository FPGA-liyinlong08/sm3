open_checkpoint /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc_routed.dcp

# Isolate the internal register-to-register datapath.  The raw OOC clock port is
# not buffered by an IBUF/BUFG, so its 3.1 ns insertion delay makes port-level
# input/output timing meaningless without a board-level clock model.
set_false_path -from [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}] \
               -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
               -to [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]

report_timing_summary -delay_type min_max -max_paths 30 \
    -file /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 30 -nworst 5 -path_type full_clock_expanded \
    -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -to   [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -file /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc_timing_internal_max.rpt
report_timing -delay_type min -max_paths 10 -nworst 3 -path_type full_clock_expanded \
    -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -to   [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -file /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc_timing_internal_min.rpt
puts "INTERNAL_TIMING_DONE"
