VERILATOR ?= verilator
BUILD_DIR ?= build

include rtl/files.mk

BUILD_META := Makefile rtl/files.mk

TOP       := simd_exec
RTL       := $(SIMD_EXEC_RTL)
OBJ_DIR   := $(BUILD_DIR)/obj_dir
SIM_TB    := $(abspath sim/simd_exec_tb.cpp)
BENES_TOP := benes_network
BENES_OBJ := $(BUILD_DIR)/benes_obj_dir
BENES_TB  := $(abspath sim/benes_network_tb.cpp)
BENES_EXCHANGE_ENGINE_TOP := vsp_benes_exchange_engine
BENES_EXCHANGE_ENGINE_OBJ := $(BUILD_DIR)/benes_exchange_engine_obj_dir
BENES_EXCHANGE_ENGINE_TB  := \
	$(abspath sim/vsp_benes_exchange_engine_tb.cpp)
ISSUE_DISPATCH_TOP := simd_issue_dispatch
ISSUE_DISPATCH_OBJ := $(BUILD_DIR)/issue_dispatch_obj_dir
ISSUE_DISPATCH_TB  := $(abspath sim/simd_issue_dispatch_tb.cpp)
ISSUE_DISPATCH_WIDE_OBJ := $(BUILD_DIR)/issue_dispatch_wide_obj_dir
ISSUE_DISPATCH_WIDE_TB  := $(abspath sim/simd_issue_dispatch_wide_tb.cpp)
ISSUE_QUEUE_TOP := simd_issue_queue
ISSUE_QUEUE_OBJ := $(BUILD_DIR)/issue_queue_obj_dir
ISSUE_QUEUE_TB  := $(abspath sim/simd_issue_queue_tb.cpp)
ISSUE_QUEUE_DEPTH1_OBJ := $(BUILD_DIR)/issue_queue_depth1_obj_dir
ISSUE_QUEUE_DEPTH1_TB  := $(abspath sim/simd_issue_queue_depth1_tb.cpp)
CLUSTER_ISSUE_FRONTEND_TOP := simd_cluster_issue_frontend
CLUSTER_ISSUE_FRONTEND_OBJ := $(BUILD_DIR)/cluster_issue_frontend_obj_dir
CLUSTER_ISSUE_FRONTEND_TB  := $(abspath sim/simd_cluster_issue_frontend_tb.cpp)
GROUP_COMPLETION_TRACKER_TOP := simd_group_completion_tracker
GROUP_COMPLETION_TRACKER_OBJ := $(BUILD_DIR)/group_completion_tracker_obj_dir
GROUP_COMPLETION_TRACKER_TB  := $(abspath sim/simd_group_completion_tracker_tb.cpp)
ISSUE_DECODE_SHELL_TOP := simd_issue_decode_shell
ISSUE_DECODE_SHELL_OBJ := $(BUILD_DIR)/issue_decode_shell_obj_dir
ISSUE_DECODE_SHELL_TB  := $(abspath sim/simd_issue_decode_shell_tb.cpp)
CLUSTER_RESULT_COLLECTOR_TOP := simd_cluster_result_collector
CLUSTER_RESULT_COLLECTOR_OBJ := $(BUILD_DIR)/cluster_result_collector_obj_dir
CLUSTER_RESULT_COLLECTOR_TB  := $(abspath sim/simd_cluster_result_collector_tb.cpp)
CLUSTER_EXEC_SHELL_TOP := simd_cluster_exec_shell
CLUSTER_EXEC_SHELL_OBJ := $(BUILD_DIR)/cluster_exec_shell_obj_dir
CLUSTER_EXEC_SHELL_TB  := $(abspath sim/simd_cluster_exec_shell_tb.cpp)
CLUSTER_EXEC_TRACKER_CREDIT_OBJ := \
	$(BUILD_DIR)/cluster_exec_tracker_credit_obj_dir
CLUSTER_EXEC_TRACKER_CREDIT_TB  := \
	$(abspath sim/simd_cluster_exec_shell_tracker_credit_tb.cpp)
VRF_SPAN_ENGINE_TOP := vsp_vrf_span_engine
VRF_SPAN_ENGINE_OBJ := $(BUILD_DIR)/vrf_span_engine_obj_dir
VRF_SPAN_ENGINE_TB  := $(abspath sim/vsp_vrf_span_engine_tb.cpp)
UOP_LEGAL_TOP := simd_uop_legal
UOP_LEGAL_OBJ := $(BUILD_DIR)/uop_legal_obj_dir
UOP_LEGAL_TB  := $(abspath sim/simd_uop_legal_tb.cpp)
ROUTE_TOP := simd_route
ROUTE_OBJ := $(BUILD_DIR)/route_obj_dir
ROUTE_TB  := $(abspath sim/simd_route_tb.cpp)
COMPACT_TOP := simd_compact
COMPACT_OBJ := $(BUILD_DIR)/compact_obj_dir
COMPACT_TB  := $(abspath sim/simd_compact_tb.cpp)
MASK_TOP := simd_mask_alu
MASK_OBJ := $(BUILD_DIR)/mask_obj_dir
MASK_TB  := $(abspath sim/simd_mask_alu_tb.cpp)
DYNAMIC_TOP := simd_dynamic_alu
DYNAMIC_OBJ := $(BUILD_DIR)/dynamic_obj_dir
DYNAMIC_TB  := $(abspath sim/simd_dynamic_alu_tb.cpp)
REDUCE_TOP := simd_reduce
REDUCE_OBJ := $(BUILD_DIR)/reduce_obj_dir
REDUCE_TB  := $(abspath sim/simd_reduce_tb.cpp)
SAD_TOP    := sad_kernel
SAD_OBJ    := $(BUILD_DIR)/sad_obj_dir
SAD_TB     := $(abspath sim/sad_kernel_tb.cpp)
DATAPATH_TOP := simd_datapath
DATAPATH_OBJ := $(BUILD_DIR)/datapath_obj_dir
DATAPATH_TB  := $(abspath sim/simd_datapath_tb.cpp)
GROUP_WRAPPER_TOP := simd_group_wrapper
GROUP_WRAPPER_OBJ := $(BUILD_DIR)/group_wrapper_obj_dir
GROUP_WRAPPER_TB  := $(abspath sim/simd_group_wrapper_tb.cpp)
GAUSSIAN_TOP := simd_datapath
GAUSSIAN_OBJ := $(BUILD_DIR)/gaussian_obj_dir
GAUSSIAN_TB  := $(abspath sim/gaussian3x3_tb.cpp)
MUL32_MICRO_TB := sim/mul32_microcode_tb.cpp
MUL32_MICRO_BIN := $(BUILD_DIR)/mul32_microcode_tb

.PHONY: all lint test test-benes-exchange-engine \
	test-cluster-exec-tracker-credit clean

all: test

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) \
		-GELEM_W=8 -GACC_W=16 $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) \
		-GELEM_W=16 -GACC_W=32 $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(BENES_TOP) $(BENES_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(BENES_EXCHANGE_ENGINE_TOP) \
		$(BENES_EXCHANGE_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(BENES_EXCHANGE_ENGINE_TOP) -GGROUP_COUNT=8 \
		$(BENES_EXCHANGE_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_DISPATCH_TOP) $(ISSUE_DISPATCH_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_DISPATCH_TOP) -GGROUP_COUNT=8 \
		-GISSUE_SLOTS=3 -GCONTEXT_COUNT=3 $(ISSUE_DISPATCH_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_QUEUE_TOP) $(ISSUE_QUEUE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_QUEUE_TOP) -GCONTEXT_COUNT=3 -GDEPTH=3 \
		-GTAG_W=8 -GUWORD_W=8 -GRESOLVED_W=8 -GSCHED_META_W=8 \
		$(ISSUE_QUEUE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_QUEUE_TOP) -GCONTEXT_COUNT=1 -GDEPTH=1 \
		$(ISSUE_QUEUE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_ISSUE_FRONTEND_TOP) \
		$(CLUSTER_ISSUE_FRONTEND_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_ISSUE_FRONTEND_TOP) -GGROUP_COUNT=6 \
		-GQUEUE_COUNT=3 -GISSUE_SLOTS=2 -GQUEUE_DEPTH=3 \
		$(CLUSTER_ISSUE_FRONTEND_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(GROUP_COMPLETION_TRACKER_TOP) \
		$(GROUP_COMPLETION_TRACKER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(GROUP_COMPLETION_TRACKER_TOP) -GGROUP_COUNT=6 \
		-GALLOC_SLOTS=3 -GCONTEXT_COUNT=3 -GENTRY_COUNT=5 \
		$(GROUP_COMPLETION_TRACKER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_DECODE_SHELL_TOP) $(ISSUE_DECODE_SHELL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_DECODE_SHELL_TOP) -GRAW_WORD_W=17 \
		-GRESOLVED_W=9 -GCACHED_META_W=7 -GCONTEXT_W=2 \
		-GGROUP_COUNT=6 -GRESOURCE_W=11 -GCANONICAL_PAYLOAD_W=53 \
		$(ISSUE_DECODE_SHELL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_RESULT_COLLECTOR_TOP) \
		$(CLUSTER_RESULT_COLLECTOR_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_RESULT_COLLECTOR_TOP) -GGROUP_COUNT=6 \
		-GLANES=8 -GCONTEXT_COUNT=3 $(CLUSTER_RESULT_COLLECTOR_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_EXEC_SHELL_TOP) $(CLUSTER_EXEC_SHELL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_EXEC_SHELL_TOP) -GGROUP_COUNT=6 \
		-GISSUE_SLOTS=3 -GQUEUE_DEPTH=3 -GTRACKER_ENTRIES=5 \
		-GLANES=8 -GCONTEXT_COUNT=3 $(CLUSTER_EXEC_SHELL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VRF_SPAN_ENGINE_TOP) $(VRF_SPAN_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VRF_SPAN_ENGINE_TOP) -GGROUP_COUNT=6 \
		-GVRF_ROWS=7 -GEXEC_CONTEXT_COUNT=3 -GMEM_OFFSET_W=12 \
		-GADDR_CONTEXT_W=5 $(VRF_SPAN_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(UOP_LEGAL_TOP) $(UOP_LEGAL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(ROUTE_TOP) $(ROUTE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(ROUTE_TOP) \
		-GLANES=8 $(ROUTE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(ROUTE_TOP) \
		-GLANES=16 $(ROUTE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(COMPACT_TOP) \
		-GLANES=8 $(COMPACT_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(MASK_TOP) \
		-GLANES=8 $(MASK_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(DYNAMIC_TOP) \
		$(DYNAMIC_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(REDUCE_TOP) $(REDUCE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(SAD_TOP) $(SAD_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(DATAPATH_TOP) $(DATAPATH_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(GROUP_WRAPPER_TOP) $(GROUP_WRAPPER_RTL)

$(BUILD_DIR):
	mkdir -p "$@"

$(OBJ_DIR)/V$(TOP): $(RTL) $(SIM_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(TOP) \
		--Mdir $(OBJ_DIR) $(RTL) $(SIM_TB)
	$(MAKE) -C $(OBJ_DIR) -f V$(TOP).mk

$(BENES_OBJ)/V$(BENES_TOP): $(BENES_RTL) $(BENES_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(BENES_TOP) \
		-GPORTS=8 -GDATA_W=4 --Mdir $(BENES_OBJ) $(BENES_RTL) $(BENES_TB)
	$(MAKE) -C $(BENES_OBJ) -f V$(BENES_TOP).mk

$(BENES_EXCHANGE_ENGINE_OBJ)/V$(BENES_EXCHANGE_ENGINE_TOP): \
		$(BENES_EXCHANGE_ENGINE_RTL) $(BENES_EXCHANGE_ENGINE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(BENES_EXCHANGE_ENGINE_TOP) \
		--Mdir $(BENES_EXCHANGE_ENGINE_OBJ) \
		$(BENES_EXCHANGE_ENGINE_RTL) $(BENES_EXCHANGE_ENGINE_TB)
	$(MAKE) -C $(BENES_EXCHANGE_ENGINE_OBJ) \
		-f V$(BENES_EXCHANGE_ENGINE_TOP).mk

test-benes-exchange-engine: \
		$(BENES_EXCHANGE_ENGINE_OBJ)/V$(BENES_EXCHANGE_ENGINE_TOP)
	$(BENES_EXCHANGE_ENGINE_OBJ)/V$(BENES_EXCHANGE_ENGINE_TOP)

$(ISSUE_DISPATCH_OBJ)/V$(ISSUE_DISPATCH_TOP): $(ISSUE_DISPATCH_RTL) \
		$(ISSUE_DISPATCH_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_DISPATCH_TOP) --Mdir $(ISSUE_DISPATCH_OBJ) \
		$(ISSUE_DISPATCH_RTL) $(ISSUE_DISPATCH_TB)
	$(MAKE) -C $(ISSUE_DISPATCH_OBJ) -f V$(ISSUE_DISPATCH_TOP).mk

$(ISSUE_DISPATCH_WIDE_OBJ)/V$(ISSUE_DISPATCH_TOP): $(ISSUE_DISPATCH_RTL) \
		$(ISSUE_DISPATCH_WIDE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_DISPATCH_TOP) -GGROUP_COUNT=8 \
		-GISSUE_SLOTS=3 -GCONTEXT_COUNT=3 \
		--Mdir $(ISSUE_DISPATCH_WIDE_OBJ) $(ISSUE_DISPATCH_RTL) \
		$(ISSUE_DISPATCH_WIDE_TB)
	$(MAKE) -C $(ISSUE_DISPATCH_WIDE_OBJ) -f V$(ISSUE_DISPATCH_TOP).mk

$(ISSUE_QUEUE_OBJ)/V$(ISSUE_QUEUE_TOP): $(ISSUE_QUEUE_RTL) \
		$(ISSUE_QUEUE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_QUEUE_TOP) -GCONTEXT_COUNT=3 -GDEPTH=3 \
		-GTAG_W=8 -GUWORD_W=8 -GRESOLVED_W=8 -GSCHED_META_W=8 \
		--Mdir $(ISSUE_QUEUE_OBJ) $(ISSUE_QUEUE_RTL) $(ISSUE_QUEUE_TB)
	$(MAKE) -C $(ISSUE_QUEUE_OBJ) -f V$(ISSUE_QUEUE_TOP).mk

$(ISSUE_QUEUE_DEPTH1_OBJ)/V$(ISSUE_QUEUE_TOP): $(ISSUE_QUEUE_RTL) \
		$(ISSUE_QUEUE_DEPTH1_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_QUEUE_TOP) -GCONTEXT_COUNT=1 -GDEPTH=1 \
		-GTAG_W=8 -GUWORD_W=8 -GRESOLVED_W=8 -GSCHED_META_W=8 \
		--Mdir $(ISSUE_QUEUE_DEPTH1_OBJ) $(ISSUE_QUEUE_RTL) \
		$(ISSUE_QUEUE_DEPTH1_TB)
	$(MAKE) -C $(ISSUE_QUEUE_DEPTH1_OBJ) -f V$(ISSUE_QUEUE_TOP).mk

$(CLUSTER_ISSUE_FRONTEND_OBJ)/V$(CLUSTER_ISSUE_FRONTEND_TOP): \
		$(CLUSTER_ISSUE_FRONTEND_RTL) $(CLUSTER_ISSUE_FRONTEND_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_ISSUE_FRONTEND_TOP) -GGROUP_COUNT=4 \
		-GQUEUE_COUNT=2 -GISSUE_SLOTS=2 -GQUEUE_DEPTH=3 \
		-GTAG_W=8 -GPAYLOAD_W=8 -GRESOLVED_W=8 -GSCHED_META_W=8 \
		--Mdir $(CLUSTER_ISSUE_FRONTEND_OBJ) \
		$(CLUSTER_ISSUE_FRONTEND_RTL) $(CLUSTER_ISSUE_FRONTEND_TB)
	$(MAKE) -C $(CLUSTER_ISSUE_FRONTEND_OBJ) \
		-f V$(CLUSTER_ISSUE_FRONTEND_TOP).mk

$(GROUP_COMPLETION_TRACKER_OBJ)/V$(GROUP_COMPLETION_TRACKER_TOP): \
		$(GROUP_COMPLETION_TRACKER_RTL) $(GROUP_COMPLETION_TRACKER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(GROUP_COMPLETION_TRACKER_TOP) -GGROUP_COUNT=4 \
		-GALLOC_SLOTS=2 -GCONTEXT_COUNT=2 -GTAG_W=8 -GENTRY_COUNT=4 \
		--Mdir $(GROUP_COMPLETION_TRACKER_OBJ) \
		$(GROUP_COMPLETION_TRACKER_RTL) $(GROUP_COMPLETION_TRACKER_TB)
	$(MAKE) -C $(GROUP_COMPLETION_TRACKER_OBJ) \
		-f V$(GROUP_COMPLETION_TRACKER_TOP).mk

$(ISSUE_DECODE_SHELL_OBJ)/V$(ISSUE_DECODE_SHELL_TOP): \
		$(ISSUE_DECODE_SHELL_RTL) $(ISSUE_DECODE_SHELL_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_DECODE_SHELL_TOP) -GRAW_WORD_W=12 \
		-GRESOLVED_W=7 -GCACHED_META_W=6 -GCONTEXT_W=2 \
		-GGROUP_COUNT=4 -GRESOURCE_W=5 -GCANONICAL_PAYLOAD_W=16 \
		-GDECODE_META_W=7 -GERROR_CAUSE_W=3 \
		--Mdir $(ISSUE_DECODE_SHELL_OBJ) $(ISSUE_DECODE_SHELL_RTL) \
		$(ISSUE_DECODE_SHELL_TB)
	$(MAKE) -C $(ISSUE_DECODE_SHELL_OBJ) \
		-f V$(ISSUE_DECODE_SHELL_TOP).mk

$(CLUSTER_RESULT_COLLECTOR_OBJ)/V$(CLUSTER_RESULT_COLLECTOR_TOP): \
		$(CLUSTER_RESULT_COLLECTOR_RTL) $(CLUSTER_RESULT_COLLECTOR_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_RESULT_COLLECTOR_TOP) -GGROUP_COUNT=4 \
		-GLANES=2 -GELEM_W=8 -GACC_W=16 -GCONTEXT_COUNT=3 -GTAG_W=8 \
		--Mdir $(CLUSTER_RESULT_COLLECTOR_OBJ) \
		$(CLUSTER_RESULT_COLLECTOR_RTL) $(CLUSTER_RESULT_COLLECTOR_TB)
	$(MAKE) -C $(CLUSTER_RESULT_COLLECTOR_OBJ) \
		-f V$(CLUSTER_RESULT_COLLECTOR_TOP).mk

$(CLUSTER_EXEC_SHELL_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP): \
		$(CLUSTER_EXEC_SHELL_RTL) $(CLUSTER_EXEC_SHELL_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_EXEC_SHELL_TOP) \
		--Mdir $(CLUSTER_EXEC_SHELL_OBJ) $(CLUSTER_EXEC_SHELL_RTL) \
		$(CLUSTER_EXEC_SHELL_TB)
	$(MAKE) -C $(CLUSTER_EXEC_SHELL_OBJ) \
		-f V$(CLUSTER_EXEC_SHELL_TOP).mk

$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP): \
		$(CLUSTER_EXEC_SHELL_RTL) $(CLUSTER_EXEC_TRACKER_CREDIT_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_EXEC_SHELL_TOP) -GTRACKER_ENTRIES=1 \
		--Mdir $(CLUSTER_EXEC_TRACKER_CREDIT_OBJ) \
		$(CLUSTER_EXEC_SHELL_RTL) $(CLUSTER_EXEC_TRACKER_CREDIT_TB)
	$(MAKE) -C $(CLUSTER_EXEC_TRACKER_CREDIT_OBJ) \
		-f V$(CLUSTER_EXEC_SHELL_TOP).mk

test-cluster-exec-tracker-credit: \
		$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP)
	$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP)

$(VRF_SPAN_ENGINE_OBJ)/V$(VRF_SPAN_ENGINE_TOP): \
		$(VRF_SPAN_ENGINE_RTL) $(VRF_SPAN_ENGINE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VRF_SPAN_ENGINE_TOP) \
		--Mdir $(VRF_SPAN_ENGINE_OBJ) \
		$(VRF_SPAN_ENGINE_RTL) $(VRF_SPAN_ENGINE_TB)
	$(MAKE) -C $(VRF_SPAN_ENGINE_OBJ) \
		-f V$(VRF_SPAN_ENGINE_TOP).mk

$(UOP_LEGAL_OBJ)/V$(UOP_LEGAL_TOP): $(UOP_LEGAL_RTL) \
		$(UOP_LEGAL_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(UOP_LEGAL_TOP) --Mdir $(UOP_LEGAL_OBJ) \
		$(UOP_LEGAL_RTL) $(UOP_LEGAL_TB)
	$(MAKE) -C $(UOP_LEGAL_OBJ) -f V$(UOP_LEGAL_TOP).mk

$(ROUTE_OBJ)/V$(ROUTE_TOP): $(ROUTE_RTL) $(ROUTE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(ROUTE_TOP) \
		--Mdir $(ROUTE_OBJ) $(ROUTE_RTL) $(ROUTE_TB)
	$(MAKE) -C $(ROUTE_OBJ) -f V$(ROUTE_TOP).mk

$(COMPACT_OBJ)/V$(COMPACT_TOP): $(COMPACT_RTL) $(COMPACT_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(COMPACT_TOP) \
		-GLANES=8 -GDATA_W=8 --Mdir $(COMPACT_OBJ) \
		$(COMPACT_RTL) $(COMPACT_TB)
	$(MAKE) -C $(COMPACT_OBJ) -f V$(COMPACT_TOP).mk

$(MASK_OBJ)/V$(MASK_TOP): $(MASK_RTL) $(MASK_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(MASK_TOP) \
		-GLANES=8 --Mdir $(MASK_OBJ) $(MASK_RTL) $(MASK_TB)
	$(MAKE) -C $(MASK_OBJ) -f V$(MASK_TOP).mk

$(DYNAMIC_OBJ)/V$(DYNAMIC_TOP): $(DYNAMIC_RTL) $(DYNAMIC_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(DYNAMIC_TOP) \
		--Mdir $(DYNAMIC_OBJ) $(DYNAMIC_RTL) $(DYNAMIC_TB)
	$(MAKE) -C $(DYNAMIC_OBJ) -f V$(DYNAMIC_TOP).mk

$(REDUCE_OBJ)/V$(REDUCE_TOP): $(REDUCE_RTL) $(REDUCE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(REDUCE_TOP) \
		-GLANES=8 -GDATA_W=8 -GACC_W=32 --Mdir $(REDUCE_OBJ) \
		$(REDUCE_RTL) $(REDUCE_TB)
	$(MAKE) -C $(REDUCE_OBJ) -f V$(REDUCE_TOP).mk

$(SAD_OBJ)/V$(SAD_TOP): $(SAD_RTL) $(SAD_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(SAD_TOP) \
		--Mdir $(SAD_OBJ) $(SAD_RTL) $(SAD_TB)
	$(MAKE) -C $(SAD_OBJ) -f V$(SAD_TOP).mk

$(DATAPATH_OBJ)/V$(DATAPATH_TOP): $(DATAPATH_RTL) $(DATAPATH_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(DATAPATH_TOP) \
		--Mdir $(DATAPATH_OBJ) $(DATAPATH_RTL) $(DATAPATH_TB)
	$(MAKE) -C $(DATAPATH_OBJ) -f V$(DATAPATH_TOP).mk

$(GROUP_WRAPPER_OBJ)/V$(GROUP_WRAPPER_TOP): $(GROUP_WRAPPER_RTL) \
		$(GROUP_WRAPPER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(GROUP_WRAPPER_TOP) --Mdir $(GROUP_WRAPPER_OBJ) \
		$(GROUP_WRAPPER_RTL) $(GROUP_WRAPPER_TB)
	$(MAKE) -C $(GROUP_WRAPPER_OBJ) -f V$(GROUP_WRAPPER_TOP).mk

$(GAUSSIAN_OBJ)/V$(GAUSSIAN_TOP): $(DATAPATH_RTL) $(GAUSSIAN_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(GAUSSIAN_TOP) \
		--Mdir $(GAUSSIAN_OBJ) $(DATAPATH_RTL) $(GAUSSIAN_TB)
	$(MAKE) -C $(GAUSSIAN_OBJ) -f V$(GAUSSIAN_TOP).mk

$(MUL32_MICRO_BIN): $(MUL32_MICRO_TB) $(BUILD_META) | $(BUILD_DIR)
	$(CXX) -std=c++17 -O2 -Wall -Wextra -pedantic $< -o $@

test: $(OBJ_DIR)/V$(TOP) $(BENES_OBJ)/V$(BENES_TOP) \
		$(BENES_EXCHANGE_ENGINE_OBJ)/V$(BENES_EXCHANGE_ENGINE_TOP) \
		$(ISSUE_DISPATCH_OBJ)/V$(ISSUE_DISPATCH_TOP) \
		$(ISSUE_DISPATCH_WIDE_OBJ)/V$(ISSUE_DISPATCH_TOP) \
		$(ISSUE_QUEUE_OBJ)/V$(ISSUE_QUEUE_TOP) \
		$(ISSUE_QUEUE_DEPTH1_OBJ)/V$(ISSUE_QUEUE_TOP) \
		$(CLUSTER_ISSUE_FRONTEND_OBJ)/V$(CLUSTER_ISSUE_FRONTEND_TOP) \
		$(GROUP_COMPLETION_TRACKER_OBJ)/V$(GROUP_COMPLETION_TRACKER_TOP) \
		$(ISSUE_DECODE_SHELL_OBJ)/V$(ISSUE_DECODE_SHELL_TOP) \
		$(CLUSTER_RESULT_COLLECTOR_OBJ)/V$(CLUSTER_RESULT_COLLECTOR_TOP) \
		$(CLUSTER_EXEC_SHELL_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP) \
		$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP) \
		$(VRF_SPAN_ENGINE_OBJ)/V$(VRF_SPAN_ENGINE_TOP) \
		$(UOP_LEGAL_OBJ)/V$(UOP_LEGAL_TOP) \
		$(ROUTE_OBJ)/V$(ROUTE_TOP) \
		$(COMPACT_OBJ)/V$(COMPACT_TOP) \
		$(MASK_OBJ)/V$(MASK_TOP) \
		$(DYNAMIC_OBJ)/V$(DYNAMIC_TOP) \
		$(REDUCE_OBJ)/V$(REDUCE_TOP) $(SAD_OBJ)/V$(SAD_TOP) \
		$(DATAPATH_OBJ)/V$(DATAPATH_TOP) \
		$(GROUP_WRAPPER_OBJ)/V$(GROUP_WRAPPER_TOP) \
		$(GAUSSIAN_OBJ)/V$(GAUSSIAN_TOP) $(MUL32_MICRO_BIN)
	$(OBJ_DIR)/V$(TOP)
	$(BENES_OBJ)/V$(BENES_TOP)
	$(BENES_EXCHANGE_ENGINE_OBJ)/V$(BENES_EXCHANGE_ENGINE_TOP)
	$(ISSUE_DISPATCH_OBJ)/V$(ISSUE_DISPATCH_TOP)
	$(ISSUE_DISPATCH_WIDE_OBJ)/V$(ISSUE_DISPATCH_TOP)
	$(ISSUE_QUEUE_OBJ)/V$(ISSUE_QUEUE_TOP)
	$(ISSUE_QUEUE_DEPTH1_OBJ)/V$(ISSUE_QUEUE_TOP)
	$(CLUSTER_ISSUE_FRONTEND_OBJ)/V$(CLUSTER_ISSUE_FRONTEND_TOP)
	$(GROUP_COMPLETION_TRACKER_OBJ)/V$(GROUP_COMPLETION_TRACKER_TOP)
	$(ISSUE_DECODE_SHELL_OBJ)/V$(ISSUE_DECODE_SHELL_TOP)
	$(CLUSTER_RESULT_COLLECTOR_OBJ)/V$(CLUSTER_RESULT_COLLECTOR_TOP)
	$(CLUSTER_EXEC_SHELL_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP)
	$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_SHELL_TOP)
	$(VRF_SPAN_ENGINE_OBJ)/V$(VRF_SPAN_ENGINE_TOP)
	$(UOP_LEGAL_OBJ)/V$(UOP_LEGAL_TOP)
	$(ROUTE_OBJ)/V$(ROUTE_TOP)
	$(COMPACT_OBJ)/V$(COMPACT_TOP)
	$(MASK_OBJ)/V$(MASK_TOP)
	$(DYNAMIC_OBJ)/V$(DYNAMIC_TOP)
	$(REDUCE_OBJ)/V$(REDUCE_TOP)
	$(SAD_OBJ)/V$(SAD_TOP)
	$(DATAPATH_OBJ)/V$(DATAPATH_TOP)
	$(GROUP_WRAPPER_OBJ)/V$(GROUP_WRAPPER_TOP)
	$(GAUSSIAN_OBJ)/V$(GAUSSIAN_TOP)
	$(MUL32_MICRO_BIN)

clean:
	@build_dir="$(abspath $(BUILD_DIR))"; \
	case "$$build_dir" in \
		""|"/"|"$(abspath .)"|"$(abspath ..)") \
			echo "Refusing to remove unsafe BUILD_DIR=$$build_dir" >&2; exit 1 ;; \
		*) rm -rf -- "$$build_dir" ;; \
	esac
