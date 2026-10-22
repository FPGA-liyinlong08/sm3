set out /home/wx/Documents/AI/SM3/work/vivado/core_bufg_opt2v_routed
open_checkpoint $out/core_bufg_opt2v_routed_routed.dcp

report_high_fanout_nets -fanout_greater_than 64 -max_nets 30 \
    -file $out/high_fanout.rpt

report_timing -delay_type max -max_paths 10 -nworst 3 -path_type full_clock_expanded \
    -from [get_cells u_core/round_idx_reg*] \
    -to   [get_cells u_core/hash_out_reg*] \
    -file $out/round_path.rpt

report_timing -delay_type max -max_paths 10 -nworst 3 -path_type full_clock_expanded \
    -from [get_cells u_core/round_idx_reg*] \
    -to   [get_cells u_core/a_reg*] \
    -file $out/round_path_a.rpt

puts "ROUND_REPORT_DONE"
