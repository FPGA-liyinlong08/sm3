# -----------------------------------------------------------------------------
# sm3_accel_top synthesis
# Vivado 2021.2, XCKU060-FFVA1156-2-E, 250 MHz
# Configuration: 16 Core / 32 Context / FAST_DEPTH 32 / POOL_DEPTH 512
# -----------------------------------------------------------------------------
set root  /home/wx/Documents/AI/SM3/sm3_fpga/latest/milestone6
set out   /home/wx/Documents/AI/SM3/work/vivado/top_16c_32ctx
set part  xcku060-ffva1156-2-e

file mkdir $out
set_param general.maxThreads 6

read_verilog -sv \
    $root/rtl/core/sm3_core.sv \
    $root/rtl/front_end/sm3_block_builder.sv \
    $root/rtl/context/sm3_block_pool.sv \
    $root/rtl/context/sm3_pool_engine.sv \
    $root/rtl/top/sm3_accel_top.sv
read_xdc $out/top_16c_32ctx.xdc

synth_design -top sm3_accel_top -part $part -flatten_hierarchy rebuilt \
    -generic CORE_NUM=16 \
    -generic CTX_NUM=32 \
    -generic FAST_DEPTH=32 \
    -generic POOL_DEPTH=512

write_checkpoint -force $out/top_16c_32ctx_post_synth.dcp
report_utilization -hierarchical -file $out/top_16c_32ctx_utilization_synth.rpt
report_utilization -file $out/top_16c_32ctx_utilization_flat_synth.rpt
if {[llength [info commands report_ram_utilization]] > 0} {
    report_ram_utilization -file $out/top_16c_32ctx_ram_utilization_synth.rpt
}
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file $out/top_16c_32ctx_timing_summary_synth.rpt

# Enumerate inferred memory primitives and their hierarchy.
proc dump_mem_cells {outfile} {
    set fh [open $outfile w]
    puts $fh "REF_NAME count"
    foreach ref {RAMB36E2 RAMB18E2 RAM32M RAM32M16 RAM64M RAM64M8 RAM128X1D RAM256X1S RAM64X1D RAM32X1D} {
        set cells [get_cells -hier -quiet -filter "REF_NAME == $ref"]
        puts $fh "$ref [llength $cells]"
        foreach c $cells {
            puts $fh "  $c"
        }
    }
    close $fh
}
dump_mem_cells $out/top_16c_32ctx_memory_cells_synth.rpt
puts "TOP_SYNTH_DONE"
