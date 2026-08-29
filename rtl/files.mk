# Canonical ordered RTL source lists. Keep package files first and describe
# target-specific dependency closures here rather than duplicating paths in the
# top-level Makefile. Do not replace these lists with wildcards: SystemVerilog
# package compile order and the deliberately small unit-test closures matter.

RTL_PKG := rtl/pkg/simd_pkg.sv
RTL_VSP_PKG := rtl/pkg/vsp_pkg.sv
RTL_VSP_ACTION_PKG := rtl/pkg/vsp_action_pkg.sv
RTL_VSP_EXEC_UWORD_PKG := rtl/pkg/vsp_exec_uword_pkg.sv
RTL_VSP_UWORD_PKG := rtl/pkg/vsp_uword_pkg.sv

RTL_LANE := rtl/units/simd_lane.sv
RTL_PARTITIONED_ADDSUB := rtl/units/simd_partitioned_addsub.sv
RTL_PARTITIONED_SHIFTER := rtl/units/simd_partitioned_shifter.sv
RTL_PARTITIONED_COMPARE := rtl/units/simd_partitioned_compare.sv
RTL_DYNAMIC_ALU := rtl/units/simd_dynamic_alu.sv
RTL_MASK_ALU := rtl/units/simd_mask_alu.sv
RTL_REDUCE := rtl/units/simd_reduce.sv

RTL_EXEC := rtl/group/simd_exec.sv
RTL_REGFILE := rtl/group/simd_regfile.sv
RTL_DATAPATH := rtl/group/simd_datapath.sv
RTL_GROUP_WRAPPER := rtl/group/simd_group_wrapper.sv

RTL_CROSSBAR := rtl/permute/simd_crossbar.sv
RTL_ROUTE := rtl/permute/simd_route.sv
RTL_COMPACT := rtl/permute/simd_compact.sv
RTL_BENES := rtl/interconnect/benes_network.sv
RTL_LANE_GATHER := rtl/interconnect/vsp_lane_gather.sv
RTL_ISSUE_DISPATCH := rtl/cluster/simd_issue_dispatch.sv
RTL_ISSUE_QUEUE := rtl/cluster/simd_issue_queue.sv
RTL_CLUSTER_ISSUE_FRONTEND := rtl/cluster/simd_cluster_issue_frontend.sv
RTL_GROUP_COMPLETION_TRACKER := rtl/cluster/simd_group_completion_tracker.sv
RTL_ISSUE_DECODE_STAGE := rtl/cluster/simd_issue_decode_stage.sv
RTL_VSP_EXEC_UWORD_EXPANDER := rtl/cluster/vsp_exec_uword_expander.sv
RTL_VSP_UWORD_PREDECODER := rtl/cluster/vsp_uword_predecoder.sv
RTL_VSP_UWORD_CONTROL_STORE := rtl/control/vsp_uword_control_store.sv
RTL_VSP_UWORD_PROGRAM_SOURCE := rtl/control/vsp_uword_program_source.sv
RTL_VSP_UWORD_BUNDLE_ASSEMBLER := rtl/control/vsp_uword_bundle_assembler.sv
RTL_VSP_UWORD_MULTI_FRAMER := rtl/control/vsp_uword_multi_framer.sv
RTL_VSP_UWORD_PROGRAM_FRONTEND := rtl/control/vsp_uword_program_frontend.sv
RTL_VSP_UWORD_ACTION_ADAPTER := rtl/control/vsp_uword_action_adapter.sv
RTL_VSP_UWORD_CLUSTER_PROGRAM_WRAPPER := \
		rtl/control/vsp_uword_cluster_program_wrapper.sv
RTL_VSP_ORDERED_ACTION_WINDOW := rtl/control/vsp_ordered_action_window.sv
RTL_VSP_DECODED_ACTION_CONTROLLER := \
		rtl/cluster/vsp_decoded_action_controller.sv
RTL_CLUSTER_RESULT_COLLECTOR := rtl/cluster/simd_cluster_result_collector.sv
RTL_CLUSTER_EXEC := rtl/cluster/simd_cluster_exec.sv
RTL_CLUSTER_VRF_ARBITER := rtl/cluster/vsp_cluster_vrf_arbiter.sv
RTL_CLUSTER_MEMORY_WRAPPER := rtl/cluster/vsp_cluster_memory_wrapper.sv
RTL_CLUSTER_CONTROLLER_WRAPPER := \
		rtl/cluster/vsp_cluster_controller_wrapper.sv
RTL_UOP_LEGAL := rtl/cluster/simd_uop_legal.sv
RTL_VECTOR_MEMORY_ENGINE := rtl/memory/vsp_vector_memory_engine.sv

ELEMENT_RTL := $(RTL_PARTITIONED_ADDSUB) $(RTL_PARTITIONED_SHIFTER) \
		$(RTL_PARTITIONED_COMPARE) $(RTL_DYNAMIC_ALU)

SIMD_EXEC_RTL := $(RTL_PKG) $(RTL_LANE) $(ELEMENT_RTL) $(RTL_EXEC)
BENES_RTL := $(RTL_BENES)
ISSUE_DISPATCH_RTL := $(RTL_ISSUE_DISPATCH)
ISSUE_QUEUE_RTL := $(RTL_ISSUE_QUEUE)
CLUSTER_ISSUE_FRONTEND_RTL := $(RTL_ISSUE_QUEUE) $(RTL_ISSUE_DISPATCH) \
		$(RTL_CLUSTER_ISSUE_FRONTEND)
GROUP_COMPLETION_TRACKER_RTL := $(RTL_GROUP_COMPLETION_TRACKER)
ISSUE_DECODE_STAGE_RTL := $(RTL_ISSUE_DECODE_STAGE)
VSP_EXEC_UWORD_EXPANDER_RTL := $(RTL_PKG) $(RTL_VSP_EXEC_UWORD_PKG) \
		$(RTL_UOP_LEGAL) $(RTL_VSP_EXEC_UWORD_EXPANDER)
VSP_UWORD_PREDECODER_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_EXEC_UWORD_PKG) $(RTL_VSP_UWORD_PKG) \
		$(RTL_VSP_UWORD_PREDECODER)
VSP_UWORD_BUNDLE_ASSEMBLER_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_EXEC_UWORD_PKG) $(RTL_VSP_UWORD_PKG) \
		$(RTL_VSP_UWORD_BUNDLE_ASSEMBLER)
VSP_UWORD_MULTI_FRAMER_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_EXEC_UWORD_PKG) $(RTL_VSP_UWORD_PKG) \
		$(RTL_VSP_UWORD_MULTI_FRAMER)
VSP_UWORD_PROGRAM_FRONTEND_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_EXEC_UWORD_PKG) $(RTL_VSP_UWORD_PKG) \
		$(RTL_VSP_UWORD_CONTROL_STORE) $(RTL_VSP_UWORD_PROGRAM_SOURCE) \
		$(RTL_VSP_UWORD_BUNDLE_ASSEMBLER) \
		$(RTL_VSP_UWORD_PROGRAM_FRONTEND)
VSP_ORDERED_ACTION_WINDOW_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_ORDERED_ACTION_WINDOW)
VSP_DECODED_ACTION_CONTROLLER_RTL := $(RTL_VSP_ACTION_PKG) \
		$(RTL_VSP_DECODED_ACTION_CONTROLLER)
CLUSTER_RESULT_COLLECTOR_RTL := $(RTL_CLUSTER_RESULT_COLLECTOR)
CLUSTER_VRF_ARBITER_RTL := $(RTL_CLUSTER_VRF_ARBITER)
UOP_LEGAL_RTL := $(RTL_PKG) $(RTL_UOP_LEGAL)
VECTOR_MEMORY_ENGINE_RTL := $(RTL_VSP_PKG) $(RTL_VECTOR_MEMORY_ENGINE)
ROUTE_RTL := $(RTL_PKG) $(RTL_CROSSBAR) $(RTL_ROUTE)
# The wide gather stage reuses the existing crossbar fabric and deliberately
# does not pull in simd_pkg: it defines its own mode encodings and is not a
# datapath operation.
LANE_GATHER_RTL := $(RTL_CROSSBAR) $(RTL_LANE_GATHER)
COMPACT_RTL := $(RTL_COMPACT)
MASK_RTL := $(RTL_PKG) $(RTL_MASK_ALU)
DYNAMIC_RTL := $(RTL_PKG) $(ELEMENT_RTL)
REDUCE_RTL := $(RTL_PKG) $(RTL_REDUCE)
SAD_RTL := $(SIMD_EXEC_RTL) $(RTL_REDUCE) sim/sad_kernel.sv
DATAPATH_RTL := $(RTL_PKG) $(RTL_UOP_LEGAL) $(RTL_REGFILE) $(RTL_LANE) $(ELEMENT_RTL) \
		$(RTL_EXEC) $(RTL_REDUCE) $(RTL_CROSSBAR) $(RTL_ROUTE) \
		$(RTL_COMPACT) $(RTL_MASK_ALU) $(RTL_DATAPATH)
GROUP_WRAPPER_RTL := $(DATAPATH_RTL) $(RTL_GROUP_WRAPPER)
CLUSTER_EXEC_RTL := $(GROUP_WRAPPER_RTL) $(RTL_ISSUE_QUEUE) \
		$(RTL_ISSUE_DISPATCH) $(RTL_CLUSTER_ISSUE_FRONTEND) \
		$(RTL_GROUP_COMPLETION_TRACKER) $(RTL_CLUSTER_RESULT_COLLECTOR) \
		$(RTL_CLUSTER_EXEC)
CLUSTER_MEMORY_WRAPPER_RTL := $(CLUSTER_EXEC_RTL) $(RTL_VSP_PKG) \
		$(RTL_CLUSTER_VRF_ARBITER) $(RTL_VECTOR_MEMORY_ENGINE) \
		$(RTL_CLUSTER_MEMORY_WRAPPER)
CLUSTER_CONTROLLER_WRAPPER_RTL := $(CLUSTER_MEMORY_WRAPPER_RTL) \
		$(RTL_VSP_ACTION_PKG) $(RTL_VSP_EXEC_UWORD_PKG) \
		$(RTL_VSP_EXEC_UWORD_EXPANDER) \
		$(RTL_VSP_DECODED_ACTION_CONTROLLER) \
		$(RTL_CLUSTER_CONTROLLER_WRAPPER)
VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL := \
		$(CLUSTER_CONTROLLER_WRAPPER_RTL) $(RTL_VSP_UWORD_PKG) \
		$(RTL_VSP_UWORD_CONTROL_STORE) $(RTL_VSP_UWORD_PROGRAM_SOURCE) \
		$(RTL_VSP_UWORD_MULTI_FRAMER) $(RTL_VSP_UWORD_ACTION_ADAPTER) \
		$(RTL_VSP_UWORD_CLUSTER_PROGRAM_WRAPPER)
