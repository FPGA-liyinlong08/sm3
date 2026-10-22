# -----------------------------------------------------------------------------
# sm3_accel_top OOC implementation
# Vivado 2021.2, XCKU060-FFVA1156-2-E, 250 MHz
# 16 Core / 32 Context / FAST_DEPTH=32 / POOL_DEPTH=512
#
# OOC is used because the debug-expanded top has 553 bonded I/O, more than the
# 520 available on the FFVA1156 package.  The debug ports are for simulation /
# observability only and will be removed or time-multiplexed in a board wrapper.
# -----------------------------------------------------------------------------
set root  /home/wx/Documents/AI/SM3/sm3_fpga/latest/milestone6
set out   /home/wx/Documents/AI/SM3/work/vivado/top_16c_32ctx_ooc
set part  xcku060-ffva1156-2-e

file mkdir $out
set_param general.maxThreads 6

read_verilog -sv \
    $root/rtl/core/sm3_core.sv \
    $root/rtl/front_end/sm3_block_builder.sv \
    $root/rtl/context/sm3_block_pool.sv \
    $root/rtl/context/sm3_pool_engine.sv \
    $root/rtl/top/sm3_accel_top.sv
read_xdc /home/wx/Documents/AI/SM3/work/vivado/top_16c_32ctx/top_16c_32ctx.xdc

synth_design -top sm3_accel_top -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt \
    -generic CORE_NUM=16 \
    -generic CTX_NUM=32 \
    -generic FAST_DEPTH=32 \
    -generic POOL_DEPTH=512

write_checkpoint -force $out/top_16c_32ctx_ooc_post_synth.dcp
report_utilization -hierarchical -file $out/top_16c_32ctx_ooc_utilization_synth.rpt
report_utilization -file $out/top_16c_32ctx_ooc_utilization_flat_synth.rpt
report_ram_utilization -file $out/top_16c_32ctx_ooc_ram_utilization_synth.rpt

set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force $out/top_16c_32ctx_ooc_routed.dcp
report_utilization -hierarchical -file $out/top_16c_32ctx_ooc_utilization_routed.rpt
report_utilization -file $out/top_16c_32ctx_ooc_utilization_flat_routed.rpt
report_ram_utilization -file $out/top_16c_32ctx_ooc_ram_utilization_routed.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 30 \
    -file $out/top_16c_32ctx_ooc_timing_summary_routed.rpt
report_timing -delay_type max -max_paths 30 -nworst 5 -path_type full_clock_expanded \
    -file $out/top_16c_32ctx_ooc_timing_max_routed.rpt
report_design_analysis -congestion -file $out/top_16c_32ctx_ooc_congestion.rpt
puts "TOP_OOC_DONE"
