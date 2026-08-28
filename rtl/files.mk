# Canonical ordered RTL source lists. Keep package files first and describe
# target-specific dependency closures here rather than duplicating paths in the
# top-level Makefile. Do not replace these lists with wildcards: SystemVerilog
# package compile order and the deliberately small unit-test closures matter.

RTL_PKG := rtl/pkg/simd_pkg.sv
RTL_VSP_PKG := rtl/pkg/vsp_pkg.sv

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
RTL_BENES_EXCHANGE_ENGINE := rtl/interconnect/vsp_benes_exchange_engine.sv
RTL_ISSUE_DISPATCH := rtl/cluster/simd_issue_dispatch.sv
RTL_ISSUE_QUEUE := rtl/cluster/simd_issue_queue.sv
RTL_CLUSTER_ISSUE_FRONTEND := rtl/cluster/simd_cluster_issue_frontend.sv
RTL_GROUP_COMPLETION_TRACKER := rtl/cluster/simd_group_completion_tracker.sv
RTL_ISSUE_DECODE_SHELL := rtl/cluster/simd_issue_decode_shell.sv
RTL_CLUSTER_RESULT_COLLECTOR := rtl/cluster/simd_cluster_result_collector.sv
RTL_CLUSTER_EXEC_SHELL := rtl/cluster/simd_cluster_exec_shell.sv
RTL_CLUSTER_VRF_SERVICE := rtl/cluster/vsp_cluster_vrf_service.sv
RTL_CLUSTER_MEMORY_SHELL := rtl/cluster/vsp_cluster_memory_shell.sv
RTL_CLUSTER_ACTOR_SHELL := rtl/cluster/vsp_cluster_actor_shell.sv
RTL_UOP_LEGAL := rtl/cluster/simd_uop_legal.sv
RTL_VRF_SPAN_ENGINE := rtl/memory/vsp_vrf_span_engine.sv

ELEMENT_RTL := $(RTL_PARTITIONED_ADDSUB) $(RTL_PARTITIONED_SHIFTER) \
		$(RTL_PARTITIONED_COMPARE) $(RTL_DYNAMIC_ALU)

SIMD_EXEC_RTL := $(RTL_PKG) $(RTL_LANE) $(ELEMENT_RTL) $(RTL_EXEC)
BENES_RTL := $(RTL_BENES)
BENES_EXCHANGE_ENGINE_RTL := $(RTL_VSP_PKG) $(RTL_BENES) \
		$(RTL_BENES_EXCHANGE_ENGINE)
ISSUE_DISPATCH_RTL := $(RTL_ISSUE_DISPATCH)
ISSUE_QUEUE_RTL := $(RTL_ISSUE_QUEUE)
CLUSTER_ISSUE_FRONTEND_RTL := $(RTL_ISSUE_QUEUE) $(RTL_ISSUE_DISPATCH) \
		$(RTL_CLUSTER_ISSUE_FRONTEND)
GROUP_COMPLETION_TRACKER_RTL := $(RTL_GROUP_COMPLETION_TRACKER)
ISSUE_DECODE_SHELL_RTL := $(RTL_ISSUE_DECODE_SHELL)
CLUSTER_RESULT_COLLECTOR_RTL := $(RTL_CLUSTER_RESULT_COLLECTOR)
CLUSTER_VRF_SERVICE_RTL := $(RTL_CLUSTER_VRF_SERVICE)
UOP_LEGAL_RTL := $(RTL_PKG) $(RTL_UOP_LEGAL)
VRF_SPAN_ENGINE_RTL := $(RTL_VSP_PKG) $(RTL_VRF_SPAN_ENGINE)
ROUTE_RTL := $(RTL_PKG) $(RTL_CROSSBAR) $(RTL_ROUTE)
COMPACT_RTL := $(RTL_COMPACT)
MASK_RTL := $(RTL_PKG) $(RTL_MASK_ALU)
DYNAMIC_RTL := $(RTL_PKG) $(ELEMENT_RTL)
REDUCE_RTL := $(RTL_PKG) $(RTL_REDUCE)
SAD_RTL := $(SIMD_EXEC_RTL) $(RTL_REDUCE) sim/sad_kernel.sv
DATAPATH_RTL := $(RTL_PKG) $(RTL_UOP_LEGAL) $(RTL_REGFILE) $(RTL_LANE) $(ELEMENT_RTL) \
		$(RTL_EXEC) $(RTL_REDUCE) $(RTL_CROSSBAR) $(RTL_ROUTE) \
		$(RTL_COMPACT) $(RTL_MASK_ALU) $(RTL_DATAPATH)
GROUP_WRAPPER_RTL := $(DATAPATH_RTL) $(RTL_GROUP_WRAPPER)
CLUSTER_EXEC_SHELL_RTL := $(GROUP_WRAPPER_RTL) $(RTL_ISSUE_QUEUE) \
		$(RTL_ISSUE_DISPATCH) $(RTL_CLUSTER_ISSUE_FRONTEND) \
		$(RTL_GROUP_COMPLETION_TRACKER) $(RTL_CLUSTER_RESULT_COLLECTOR) \
		$(RTL_CLUSTER_EXEC_SHELL)
CLUSTER_MEMORY_SHELL_RTL := $(CLUSTER_EXEC_SHELL_RTL) $(RTL_VSP_PKG) \
		$(RTL_CLUSTER_VRF_SERVICE) $(RTL_VRF_SPAN_ENGINE) \
		$(RTL_CLUSTER_MEMORY_SHELL)
# Both non-EXEC actors online at once. This closure adds the Benes network and
# row-exchange engine on top of the MEMORY closure.
CLUSTER_ACTOR_SHELL_RTL := $(CLUSTER_EXEC_SHELL_RTL) $(RTL_VSP_PKG) \
		$(RTL_CLUSTER_VRF_SERVICE) $(RTL_VRF_SPAN_ENGINE) \
		$(RTL_BENES) $(RTL_BENES_EXCHANGE_ENGINE) \
		$(RTL_CLUSTER_ACTOR_SHELL)
