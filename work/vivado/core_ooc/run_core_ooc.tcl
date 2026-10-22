# -----------------------------------------------------------------------------
# sm3_core OOC synthesis + implementation
# Vivado 2021.2, XCKU060-FFVA1156-2-E, 250 MHz
# -----------------------------------------------------------------------------
set root  /home/wx/Documents/AI/SM3/sm3_fpga/latest/milestone6
set out   /home/wx/Documents/AI/SM3/work/vivado/core_ooc
set part  xcku060-ffva1156-2-e

file mkdir $out
set_param general.maxThreads 6

read_verilog -sv $root/rtl/core/sm3_core.sv
read_xdc $out/core_ooc.xdc

synth_design -top sm3_core -part $part -mode out_of_context \
             -flatten_hierarchy none -directive default

write_checkpoint -force $out/core_ooc_post_synth.dcp
report_utilization      -file $out/core_ooc_utilization_synth.rpt
report_timing_summary   -delay_type min_max -report_unconstrained \
                        -check_timing_verbose -max_paths 20 \
                        -file $out/core_ooc_timing_summary_synth.rpt
report_timing -delay_type max -max_paths 20 -nworst 5 -path_type full_clock_expanded \
              -file $out/core_ooc_timing_max_synth.rpt
report_timing -delay_type min -max_paths 10 -nworst 3 -path_type full_clock_expanded \
              -file $out/core_ooc_timing_min_synth.rpt

# Out-of-context implementation: the clock port is marked as an already-buffered
# clock root so place/route do not require an IBUF/BUFG pair in the OOC netlist.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $out/core_ooc_routed.dcp
report_utilization      -file $out/core_ooc_utilization_routed.rpt
report_timing_summary   -delay_type min_max -report_unconstrained \
                        -check_timing_verbose -max_paths 20 \
                        -file $out/core_ooc_timing_summary_routed.rpt
report_timing -delay_type max -max_paths 20 -nworst 5 -path_type full_clock_expanded \
              -file $out/core_ooc_timing_max_routed.rpt
report_timing -delay_type min -max_paths 10 -nworst 3 -path_type full_clock_expanded \
              -file $out/core_ooc_timing_min_routed.rpt
report_design_analysis -congestion -file $out/core_ooc_congestion.rpt
puts "CORE_OOC_DONE"
