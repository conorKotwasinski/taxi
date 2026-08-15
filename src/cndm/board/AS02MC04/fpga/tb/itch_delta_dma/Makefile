# SPDX-License-Identifier: MIT
TOPLEVEL_LANG = verilog
SIM ?= verilator
WAVES ?= 0

COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

RTL_DIR = ../../rtl
LIB_DIR = ../../lib
TAXI_SRC_DIR = $(LIB_DIR)/taxi/src

DUT      = itch_delta_dma
COCOTB_TEST_MODULES = test_$(DUT)
COCOTB_TOPLEVEL     = test_$(DUT)
MODULE   = $(COCOTB_TEST_MODULES)
TOPLEVEL = $(COCOTB_TOPLEVEL)
VERILOG_SOURCES += $(COCOTB_TOPLEVEL).sv
VERILOG_SOURCES += ../../../../../rtl/cndm_axis_rec_dma.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/axis/rtl/taxi_axis_if.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/dma/rtl/taxi_dma_desc_if.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/dma/rtl/taxi_dma_ram_if.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/dma/rtl/taxi_dma_psdpram.sv
VERILOG_SOURCES += $(TAXI_SRC_DIR)/dma/rtl/taxi_dma_client_axis_sink.sv

process_f_file = $(call process_f_files,$(addprefix $(dir $1),$(shell cat $1)))
process_f_files = $(foreach f,$1,$(if $(filter %.f,$f),$(call process_f_file,$f),$f))
uniq_base = $(if $1,$(call uniq_base,$(foreach f,$1,$(if $(filter-out $(notdir $(lastword $1)),$(notdir $f)),$f,))) $(lastword $1))
VERILOG_SOURCES := $(call uniq_base,$(call process_f_files,$(VERILOG_SOURCES)))

export PARAM_REC_BYTES := 32
export PARAM_RING_ENTRIES := 8
export PARAM_ADDR_W := 64
export PARAM_LEN_W := 20
export PARAM_TAG_W := 8
export PARAM_RAM_SEGS := 2
export PARAM_RAM_SEG_ADDR_W := 12
export PARAM_RAM_SEG_DATA_W := 128
export PARAM_RAM_SEG_BE_W := 16
export PARAM_RAM_SEL_W := 2

ifeq ($(SIM), verilator)
	COMPILE_ARGS += $(foreach v,$(filter PARAM_%,$(.VARIABLES)),-G$(subst PARAM_,,$(v))=$($(v)))
	ifeq ($(WAVES), 1)
		COMPILE_ARGS += --trace-fst
		VERILATOR_TRACE = 1
	endif
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
