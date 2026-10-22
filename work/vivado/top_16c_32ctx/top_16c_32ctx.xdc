# -----------------------------------------------------------------------------
# sm3_accel_top constraints
# Target: XCKU060-FFVA1156-2-E, 250 MHz (4.000 ns)
# Recommended configuration: 16 Core / 32 Context / 512 Block Pool
# -----------------------------------------------------------------------------
create_clock -period 4.000 -name clk -waveform {0.000 2.000} [get_ports clk]

set_clock_uncertainty -setup 0.050 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

# 1 ns board/interface budget in each direction.  Internal datapath timing is
# reported separately after implementation.
set_input_delay  -clock clk 1.000 [get_ports {desc_valid desc_msg_id desc_len_bytes s_valid s_data s_keep result_ready}]
set_output_delay -clock clk 1.000 [get_ports {desc_ready s_ready result_valid digest_out result_msg_id dbg_core_occupied dbg_ctx_allocated dbg_fast_level dbg_pool_free dbg_pool_init_done}]

set_false_path -from [get_ports rst_n]
