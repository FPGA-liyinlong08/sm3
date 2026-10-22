SIM ?= verilator
TOPLEVEL_LANG ?= verilog
TOPLEVEL := sm3_core
COCOTB_TEST_MODULES := test_sm3_core
export PYTHONPATH := $(CURDIR)/tb:$(PYTHONPATH)
VERILOG_SOURCES := $(CURDIR)/rtl/core/sm3_core.sv
COMPILE_ARGS += --timing -Wall -Wno-fatal

include $(shell cocotb-config --makefiles)/Makefile.sim
