# -----------------------------------------------------------------------------
# sm3_core out-of-context constraints
# Target: XCKU060-FFVA1156-2-E, 250 MHz (4.000 ns)
# -----------------------------------------------------------------------------
create_clock -period 4.000 -name clk -waveform {0.000 2.000} [get_ports clk]

set_clock_uncertainty -setup 0.050 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

# Board/interface budget: 1 ns each direction.  Internal reg-to-reg paths are
# unaffected by these values and are the primary 250 MHz check.
set_input_delay  -clock clk 1.000 [get_ports {in_valid block_data hash_in msg_id_in block_last_in out_ready}]
set_output_delay -clock clk 1.000 [get_ports {in_ready out_valid hash_out msg_id_out block_last_out}]

# Asynchronous reset is not a timed data path.
set_false_path -from [get_ports rst_n]
