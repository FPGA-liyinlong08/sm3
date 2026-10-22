# Synthesize sm3_core + BUFG wrapper only.
# Usage: vivado -mode batch -source run_core_bufg_synth.tcl -tclargs <core_sv> <outdir> <tag>
set core_sv [lindex $argv 0]
set out     [lindex $argv 1]
set tag     [lindex $argv 2]
file mkdir $out
set_param general.maxThreads 6

read_verilog -sv $core_sv
read_verilog -sv /home/wx/Documents/AI/SM3/work/vivado/rtl_opt/sm3_core_bufg.sv
read_xdc /home/wx/Documents/AI/SM3/work/vivado/rtl_opt/core_bufg.xdc

synth_design -top sm3_core_bufg -part xcku060-ffva1156-2-e -mode out_of_context \
             -flatten_hierarchy none -directive default

write_checkpoint -force $out/${tag}_post_synth.dcp
report_utilization    -file $out/${tag}_utilization_synth.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
                      -check_timing_verbose -max_paths 20 \
                      -file $out/${tag}_timing_summary_synth.rpt
puts "CORE_BUFG_SYNTH_DONE $tag"
