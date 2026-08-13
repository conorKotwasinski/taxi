# SPDX-License-Identifier: MIT
TOPLEVEL_LANG = verilog
SIM ?= verilator
WAVES ?= 0

COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

RTL_DIR = ../../rtl
LIB_DIR = ../../lib
TAXI_SRC_DIR = $(LIB_DIR)/taxi/src

DUT      = itch_frame_gen
COCOTB_TEST_MODULES = test_$(DUT)
COCOTB_TOPLEVEL     = test_$(DUT)
MODULE   = $(COCOTB_TEST_MODULES)
TOPLEVEL = $(COCOTB_TOPLEVEL)
VERILOG_SOURCES += $(COCOTB_TOPLEVEL).sv
VERILOG_SOURCES += $(RTL_DIR)/itch_frame_gen.sv
VERILOG_SOURCES += $(RTL_DIR)/itch_tap.sv
VERILOG_SOURCES += $(RTL_DIR)/itch_decode.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_if.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_adapter.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_async_fifo.f

process_f_file = $(call process_f_files,$(addprefix $(dir $1),$(shell cat $1)))
process_f_files = $(foreach f,$1,$(if $(filter %.f,$f),$(call process_f_file,$f),$f))
uniq_base = $(if $1,$(call uniq_base,$(foreach f,$1,$(if $(filter-out $(notdir $(lastword $1)),$(notdir $f)),$f,))) $(lastword $1))
VERILOG_SOURCES := $(call uniq_base,$(call process_f_files,$(VERILOG_SOURCES)))

export PARAM_DATA_W := 64
export PARAM_INTERVAL := 6000
export PARAM_SYM_COUNT := 4
export PARAM_LEVELS := 16
export PARAM_ORDER_COUNT := 1024
export PARAM_PRICE_W := 32
export PARAM_QTY_W := 32
export PARAM_ORDER_REF_W := 64
export PARAM_TS_W := 48
export PARAM_HDR_SKIP_BYTES := 14

ifeq ($(SIM), verilator)
	COMPILE_ARGS += $(foreach v,$(filter PARAM_%,$(.VARIABLES)),-G$(subst PARAM_,,$(v))=$($(v)))
	ifeq ($(WAVES), 1)
		COMPILE_ARGS += --trace-fst
		VERILATOR_TRACE = 1
	endif
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
