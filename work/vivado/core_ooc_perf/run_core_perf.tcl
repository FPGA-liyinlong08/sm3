# -----------------------------------------------------------------------------
# sm3_core OOC, PerformanceOptimized synthesis variant
# Vivado 2021.2, XCKU060-FFVA1156-2-E, 250 MHz
# -----------------------------------------------------------------------------
set root  /home/wx/Documents/AI/SM3/sm3_fpga/latest/milestone6
set out   /home/wx/Documents/AI/SM3/work/vivado/core_ooc_perf
set part  xcku060-ffva1156-2-e

file mkdir $out
set_param general.maxThreads 6

read_verilog -sv $root/rtl/core/sm3_core.sv
read_xdc /home/wx/Documents/AI/SM3/work/vivado/core_ooc/core_ooc.xdc

synth_design -top sm3_core -part $part -mode out_of_context \
             -flatten_hierarchy none -directive PerformanceOptimized

write_checkpoint -force $out/core_ooc_perf_post_synth.dcp
report_utilization -file $out/core_ooc_perf_utilization_synth.rpt

set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $out/core_ooc_perf_routed.dcp
report_utilization -file $out/core_ooc_perf_utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file $out/core_ooc_perf_timing_summary_routed.rpt

# Internal register-to-register timing (I/O paths are unbuffered OOC artifacts).
set_false_path -from [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}] \
               -to [get_cells -hier -filter {IS_SEQUENTIAL}]
set_false_path -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
               -to [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file $out/core_ooc_perf_timing_summary_internal.rpt
report_timing -delay_type max -max_paths 20 -nworst 5 -path_type full_clock_expanded \
    -from [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -to   [get_cells -hier -filter {IS_SEQUENTIAL}] \
    -file $out/core_ooc_perf_timing_internal_max.rpt
puts "CORE_PERF_DONE"
