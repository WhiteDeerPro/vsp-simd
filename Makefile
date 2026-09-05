VERILATOR ?= verilator
VCS ?= vcs
VCS_LDFLAGS ?= -Wl,--no-as-needed
VPD2VCD ?= vpd2vcd
VFAST ?= vfast
VERDI ?= verdi
GRAPHVIZ_NEATO ?= neato
PYTHON ?= python3
BUILD_DIR ?= build

VCS_FFT64_TB := sim/fft64_vcs_tb.sv
VCS_FFT64_DIR := $(BUILD_DIR)/vcs_fft64
VCS_FFT64_SIM := $(VCS_FFT64_DIR)/simv
VCS_FFT64_FIXTURES := \
	test_data/signals/fft_test_64_bin8.hex \
	test_data/fft/fft64_twiddle_cos.hex \
	test_data/fft/fft64_twiddle_sin.hex \
	test_data/fft/fft64_bitreverse.hex

FFT64_VSP_GENERATOR := tools/generate_fft64_vsp.py
FFT64_SPECTRUM_VERIFIER := tools/verify_fft64_spectrum.py
FFT64_FIXTURE_TB := sim/fft64_fixture_tb.py
FFT64_SPECTRUM_TB := sim/fft64_spectrum_tb.py
VSP_BFP_TB := sim/vsp_bfp_tb.py
VSP_M8E8_TB := sim/vsp_m8e8_tb.py
FFT64_VSP_ARTIFACT_DIR := $(BUILD_DIR)/fft64_vsp
FFT64_VSP_PROGRAM := $(FFT64_VSP_ARTIFACT_DIR)/dsp_fft64_q7.hex
FFT64_VSP_DATA := $(FFT64_VSP_ARTIFACT_DIR)/fft64_q7_data.hex
FFT64_VSP_GOLDEN := $(FFT64_VSP_ARTIFACT_DIR)/fft64_q7_golden.hex
FFT64_VSP_OUTPUT := $(FFT64_VSP_ARTIFACT_DIR)/fft64_q7_rtl_output.hex
FFT64_VSP_VCD := $(FFT64_VSP_ARTIFACT_DIR)/fft64_vsp.vcd
FFT64_VSP_CSV := $(FFT64_VSP_ARTIFACT_DIR)/fft64_spectrum.csv
FFT64_VSP_PLOT_PREFIX := $(FFT64_VSP_ARTIFACT_DIR)/fft64_spectrum
FFT64_VSP_PLOTTER := tools/plot_fft64_graphviz.py
FFT64_INPUT_PLOTTER := tools/plot_fft64_input_graphviz.py
FFT64_VSP_OBJ := $(BUILD_DIR)/fft64_vsp_obj_dir
FFT64_VSP_TB := $(abspath sim/integration/fft64_vsp_memory_system_tb.cpp)
VCS_FFT64_VSP_TB := $(abspath sim/fft64_vsp_vcs_tb.sv)
VCS_FFT64_VSP_DIR := $(BUILD_DIR)/vcs_fft64_vsp
VCS_FFT64_VSP_SIM := $(VCS_FFT64_VSP_DIR)/simv
VCS_FFT64_VSP_VPD := $(abspath $(VCS_FFT64_VSP_DIR)/fft64_vsp.vpd)
VCS_FFT64_VSP_VCD := $(abspath $(VCS_FFT64_VSP_DIR)/fft64_vsp_vcs.vcd)
VCS_FFT64_VSP_FSDB := $(abspath $(VCS_FFT64_VSP_DIR)/fft64_vsp_vcs.fsdb)
VCS_FFT64_VSP_CSV := $(abspath $(VCS_FFT64_VSP_DIR)/fft64_spectrum.csv)
VCS_FFT64_VSP_PLOT_PREFIX := $(VCS_FFT64_VSP_DIR)/fft64_spectrum
VCS_FFT64_VSP_VERDI_SCRIPT := $(abspath sim/verdi_fft64_vsp.tcl)

FFT64_MIXED_ARTIFACT_DIR := $(BUILD_DIR)/fft64_mixed_vsp
FFT64_MIXED_PROGRAM := $(FFT64_MIXED_ARTIFACT_DIR)/dsp_fft64_q7.hex
FFT64_MIXED_DATA := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_q7_data.hex
FFT64_MIXED_GOLDEN := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_q7_golden.hex
FFT64_MIXED_MANIFEST := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_q7_manifest.json
FFT64_MIXED_INPUT_CSV := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_input.csv
FFT64_MIXED_OUTPUT := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_mixed_rtl_output.hex
FFT64_MIXED_VCD := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_mixed_vsp.vcd
FFT64_MIXED_CSV := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_mixed_spectrum.csv
FFT64_MIXED_PLOT_PREFIX := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_mixed_spectrum
FFT64_MIXED_TIME_PLOT_PREFIX := \
	$(FFT64_MIXED_ARTIFACT_DIR)/fft64_input_time_domain
FFT64_MIXED_DFT_CSV := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_dft_reference.csv
FFT64_MIXED_COMPARE_CSV := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_spectrum_comparison.csv
FFT64_MIXED_METRICS := $(FFT64_MIXED_ARTIFACT_DIR)/fft64_spectrum_metrics.json

VCS_FFT64_MIXED_DIR := $(BUILD_DIR)/vcs_fft64_mixed_vsp
VCS_FFT64_MIXED_SIM := $(VCS_FFT64_MIXED_DIR)/simv
VCS_FFT64_MIXED_VPD := $(abspath $(VCS_FFT64_MIXED_DIR)/fft64_mixed_vsp.vpd)
VCS_FFT64_MIXED_VCD := $(abspath $(VCS_FFT64_MIXED_DIR)/fft64_mixed_vsp_vcs.vcd)
VCS_FFT64_MIXED_FSDB := $(abspath $(VCS_FFT64_MIXED_DIR)/fft64_mixed_vsp_vcs.fsdb)
VCS_FFT64_MIXED_CSV := $(abspath $(VCS_FFT64_MIXED_DIR)/fft64_mixed_spectrum.csv)
VCS_FFT64_MIXED_PLOT_PREFIX := $(VCS_FFT64_MIXED_DIR)/fft64_mixed_spectrum
VCS_FFT64_MIXED_DFT_CSV := $(VCS_FFT64_MIXED_DIR)/fft64_dft_reference.csv
VCS_FFT64_MIXED_COMPARE_CSV := $(VCS_FFT64_MIXED_DIR)/fft64_spectrum_comparison.csv
VCS_FFT64_MIXED_METRICS := $(VCS_FFT64_MIXED_DIR)/fft64_spectrum_metrics.json

include rtl/files.mk
include rtl/integration/memory_ip_files.mk

BUILD_META := Makefile rtl/files.mk rtl/integration/memory_ip_files.mk

TOP       := simd_exec
RTL       := $(SIMD_EXEC_RTL)
OBJ_DIR   := $(BUILD_DIR)/obj_dir
SIM_TB    := $(abspath sim/simd_exec_tb.cpp)
BENES_TOP := benes_network
BENES_OBJ := $(BUILD_DIR)/benes_obj_dir
BENES_TB  := $(abspath sim/benes_network_tb.cpp)
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
ISSUE_DECODE_STAGE_TOP := simd_issue_decode_stage
ISSUE_DECODE_STAGE_OBJ := $(BUILD_DIR)/issue_decode_stage_obj_dir
ISSUE_DECODE_STAGE_TB  := $(abspath sim/simd_issue_decode_stage_tb.cpp)
VSP_EXEC_UWORD_EXPANDER_TOP := vsp_exec_uword_expander
VSP_EXEC_UWORD_EXPANDER_OBJ := \
	$(BUILD_DIR)/vsp_exec_uword_expander_obj_dir
VSP_EXEC_UWORD_EXPANDER_TB  := \
	$(abspath sim/vsp_exec_uword_expander_tb.cpp)
VSP_UWORD_PREDECODER_TOP := vsp_uword_predecoder
VSP_UWORD_PREDECODER_OBJ := $(BUILD_DIR)/vsp_uword_predecoder_obj_dir
VSP_UWORD_PREDECODER_TB  := $(abspath sim/vsp_uword_predecoder_tb.cpp)
VSP_UWORD_BUNDLE_ASSEMBLER_TOP := vsp_uword_bundle_assembler
VSP_UWORD_BUNDLE_ASSEMBLER_OBJ := \
	$(BUILD_DIR)/vsp_uword_bundle_assembler_obj_dir
VSP_UWORD_BUNDLE_ASSEMBLER_TB := \
	$(abspath sim/vsp_uword_bundle_assembler_tb.cpp)
VSP_UWORD_MULTI_FRAMER_TOP := vsp_uword_multi_framer
VSP_UWORD_MULTI_FRAMER_OBJ := $(BUILD_DIR)/vsp_uword_multi_framer_obj_dir
VSP_UWORD_MULTI_FRAMER_TB := \
	$(abspath sim/vsp_uword_multi_framer_tb.cpp)
VSP_UWORD_PROGRAM_SOURCE_TOP := vsp_uword_program_source
VSP_UWORD_PROGRAM_SOURCE_OBJ := \
	$(BUILD_DIR)/vsp_uword_program_source_obj_dir
VSP_UWORD_PROGRAM_SOURCE_TB := \
	$(abspath sim/vsp_uword_program_source_tb.cpp)
VSP_UWORD_PROGRAM_FRONTEND_TOP := vsp_uword_program_frontend
VSP_UWORD_PROGRAM_FRONTEND_OBJ := \
	$(BUILD_DIR)/vsp_uword_program_frontend_obj_dir
VSP_UWORD_PROGRAM_FRONTEND_TB := \
	$(abspath sim/vsp_uword_program_frontend_tb.cpp)
VSP_UWORD_CLUSTER_PROGRAM_TOP := vsp_uword_cluster_program_wrapper
VSP_UWORD_CLUSTER_PROGRAM_OBJ := \
	$(BUILD_DIR)/vsp_uword_cluster_program_obj_dir
VSP_UWORD_CLUSTER_PROGRAM_TB := \
	$(abspath sim/vsp_uword_cluster_program_wrapper_tb.cpp)
VSP_DMEM_SUBSYSTEM_TOP := vsp_dmem_subsystem_wrapper_tb_top
VSP_DMEM_SUBSYSTEM_OBJ := $(BUILD_DIR)/vsp_dmem_subsystem_obj_dir
VSP_DMEM_SUBSYSTEM_TB_TOP := \
	$(abspath sim/integration/vsp_dmem_subsystem_wrapper_tb_top.sv)
VSP_DMEM_SUBSYSTEM_TB := \
	$(abspath sim/integration/vsp_dmem_subsystem_wrapper_tb.cpp)
VSP_DMEM_SUBSYSTEM_TEST_RTL := $(VSP_DMEM_SUBSYSTEM_WRAPPER_RTL) \
	$(VSP_DMEM_SUBSYSTEM_TB_TOP)
VSP_DMEM_CACHED_FABRIC_TOP := vsp_dmem_cached_fabric_wrapper
VSP_DMEM_CACHED_FABRIC_TEST_TOP := \
	vsp_dmem_cached_fabric_wrapper_tb_top
VSP_DMEM_CACHED_FABRIC_OBJ := \
	$(BUILD_DIR)/vsp_dmem_cached_fabric_obj_dir
VSP_DMEM_CACHED_FABRIC_TB_TOP := \
	$(abspath sim/integration/vsp_dmem_cached_fabric_wrapper_tb_top.sv)
VSP_DMEM_CACHED_FABRIC_TB := \
	$(abspath sim/integration/vsp_dmem_cached_fabric_wrapper_tb.cpp)
VSP_DMEM_CACHED_FABRIC_TEST_RTL := \
	$(VSP_DMEM_CACHED_FABRIC_WRAPPER_RTL) \
	$(VSP_DMEM_CACHED_FABRIC_TB_TOP)
VSP_IFETCH_CACHED_CLIENT_TOP := vsp_ifetch_cached_client_wrapper
VSP_IFETCH_FAULT_TOP := vsp_ifetch_fault_tb_top
VSP_IFETCH_FAULT_OBJ := $(BUILD_DIR)/vsp_ifetch_fault_obj_dir
VSP_IFETCH_FAULT_TB := $(abspath sim/integration/vsp_ifetch_fault_tb.cpp)
VSP_IFETCH_FAULT_RTL := $(VSP_IFETCH_CACHED_CLIENT_WRAPPER_RTL) \
	$(abspath sim/integration/vsp_ifetch_fault_tb_top.sv)
VSP_IFETCH_REDIRECT_ASM := examples/uword/program_ifetch_redirect_prefix.uasm
VSP_IFETCH_REDIRECT_HEX := $(BUILD_DIR)/program_ifetch_redirect_prefix.hex
VSP_UWORD_MEMORY_SYSTEM_TOP := vsp_uword_memory_system_wrapper
VSP_UWORD_MEMORY_SYSTEM_TEST_TOP := \
	vsp_uword_memory_system_wrapper_tb_top
VSP_UWORD_MEMORY_SYSTEM_OBJ := \
	$(BUILD_DIR)/vsp_uword_memory_system_obj_dir
VSP_UWORD_MEMORY_SYSTEM_TB_TOP := \
	$(abspath sim/integration/vsp_uword_memory_system_wrapper_tb_top.sv)
VSP_UWORD_MEMORY_SYSTEM_TB := \
	$(abspath sim/integration/vsp_uword_memory_system_wrapper_tb.cpp)
VSP_UWORD_MEMORY_SYSTEM_TEST_RTL := \
	$(VSP_UWORD_MEMORY_SYSTEM_WRAPPER_RTL) \
	$(VSP_UWORD_MEMORY_SYSTEM_TB_TOP)
VSP_HOST_CONTROL_TEST_TOP := vsp_host_control_tb_top
VSP_HOST_CONTROL_OBJ := $(BUILD_DIR)/vsp_host_control_obj_dir
VSP_HOST_CONTROL_TB := $(abspath sim/integration/vsp_host_control_tb.cpp)
VSP_HOST_CONTROL_TEST_RTL := $(VSP_HOST_CONTROL_RTL) \
	$(abspath sim/integration/vsp_host_control_tb_top.sv)
VSP_MMIO_SYSTEM_TEST_TOP := vsp_mmio_system_tb_top
VSP_MMIO_SYSTEM_OBJ := $(BUILD_DIR)/vsp_mmio_system_obj_dir
VSP_MMIO_SYSTEM_TB := $(abspath sim/integration/vsp_mmio_system_tb.cpp)
VSP_MMIO_SYSTEM_TEST_RTL := $(VSP_MMIO_SYSTEM_WRAPPER_RTL) \
	$(abspath sim/integration/vsp_mmio_system_tb_top.sv)
VSP_UNCACHED_DEVICE_MERGE_TEST_TOP := \
	vsp_uncached_device_merge_tb_top
VSP_UNCACHED_DEVICE_MERGE_OBJ := \
	$(BUILD_DIR)/vsp_uncached_device_merge_obj_dir
VSP_UNCACHED_DEVICE_MERGE_TB_TOP := \
	$(abspath sim/integration/vsp_uncached_device_merge_tb_top.sv)
VSP_UNCACHED_DEVICE_MERGE_TB := \
	$(abspath sim/integration/vsp_uncached_device_merge_tb.cpp)
VSP_UNCACHED_DEVICE_MERGE_TEST_RTL := \
	$(VSP_MEMORY_ENDPOINTS_PKG_RTL) \
	$(RTL_VSP_UNCACHED_DEVICE_MERGE) \
	$(VSP_UNCACHED_DEVICE_MERGE_TB_TOP)
VSP_UWORD_CACHED_PROGRAM_TOP := vsp_uword_cached_program_wrapper
VSP_UWORD_CACHED_PROGRAM_TEST_TOP := \
	vsp_uword_cached_program_wrapper_tb_top
VSP_UWORD_CACHED_PROGRAM_OBJ := \
	$(BUILD_DIR)/vsp_uword_cached_program_obj_dir
VSP_UWORD_CACHED_PROGRAM_TB_TOP := \
	$(abspath sim/integration/vsp_uword_cached_program_wrapper_tb_top.sv)
VSP_UWORD_CACHED_PROGRAM_TB := \
	$(abspath sim/integration/vsp_uword_cached_program_wrapper_tb.cpp)
VSP_UWORD_CACHED_PROGRAM_TEST_RTL := \
	$(VSP_UWORD_CACHED_PROGRAM_WRAPPER_RTL) \
	$(VSP_UWORD_CACHED_PROGRAM_TB_TOP)
VSP_MEMORY_UWORD_DECODER_TOP := vsp_memory_uword_decoder
VSP_MEMORY_UWORD_DECODER_OBJ := \
	$(BUILD_DIR)/vsp_memory_uword_decoder_obj_dir
VSP_MEMORY_UWORD_DECODER_TB := \
	$(abspath sim/vsp_memory_uword_decoder_tb.cpp)
VSP_CONTROL_UWORD_DECODER_TOP := vsp_control_uword_decoder
VSP_CONTROL_UWORD_DECODER_OBJ := \
	$(BUILD_DIR)/vsp_control_uword_decoder_obj_dir
VSP_CONTROL_UWORD_DECODER_TB := \
	$(abspath sim/vsp_control_uword_decoder_tb.cpp)
VSP_UWORD_ACTION_ADAPTER_TOP := vsp_uword_action_adapter
VSP_UWORD_ACTION_ADAPTER_OBJ := \
	$(BUILD_DIR)/vsp_uword_action_adapter_branch_obj_dir
VSP_UWORD_ACTION_ADAPTER_TB := \
	$(abspath sim/vsp_uword_action_adapter_branch_tb.cpp)
VSP_ORDERED_ACTION_WINDOW_TOP := vsp_ordered_action_window
VSP_ORDERED_ACTION_WINDOW_OBJ := \
	$(BUILD_DIR)/vsp_ordered_action_window_obj_dir
VSP_ORDERED_ACTION_WINDOW_TB := \
	$(abspath sim/vsp_ordered_action_window_tb.cpp)
VSP_ROUTE_RENDEZVOUS_TOP := vsp_route_rendezvous_table
VSP_ROUTE_RENDEZVOUS_OBJ := $(BUILD_DIR)/vsp_route_rendezvous_obj_dir
VSP_ROUTE_RENDEZVOUS_TB := \
	$(abspath sim/vsp_route_rendezvous_table_tb.cpp)
VSP_ROUTE_WAVE_CONTROLLER_TOP := vsp_route_wave_controller
VSP_ROUTE_WAVE_CONTROLLER_OBJ := \
	$(BUILD_DIR)/vsp_route_wave_controller_obj_dir
VSP_ROUTE_WAVE_CONTROLLER_TB := \
	$(abspath sim/vsp_route_wave_controller_tb.cpp)
CLUSTER_ROUTE_WAVE_PIPELINE_TOP := vsp_cluster_route_wave_pipeline
CLUSTER_ROUTE_WAVE_PIPELINE_OBJ := \
	$(BUILD_DIR)/cluster_route_wave_pipeline_obj_dir
CLUSTER_ROUTE_WAVE_PIPELINE_TB := \
	$(abspath sim/vsp_cluster_route_wave_pipeline_tb.cpp)
VSP_UWORD_ASM_TOOL := tools/vsp_uword_asm.py
VSP_UWORD_ASM_TB := sim/vsp_uword_asm_tb.py
VSP_UWORD_PC_SOURCE := examples/uword/pc_smoke.uasm
VSP_UWORD_PC_HEX := $(BUILD_DIR)/pc_smoke.hex
VSP_UWORD_PC_LISTING := $(BUILD_DIR)/pc_smoke.lst
VSP_UWORD_PC_SYMBOLS := $(BUILD_DIR)/pc_smoke.json
VSP_UWORD_EXEC_END_SOURCE := examples/uword/program_exec_end.uasm
VSP_UWORD_EXEC_END_HEX := $(BUILD_DIR)/program_exec_end.hex
VSP_UWORD_MEMORY_STATE_SOURCE := examples/uword/program_memory_state.uasm
VSP_UWORD_MEMORY_STATE_HEX := $(BUILD_DIR)/program_memory_state.hex
VSP_UWORD_BRANCH_LOOP_SOURCE := examples/uword/program_branch_loop.uasm
VSP_UWORD_BRANCH_LOOP_HEX := $(BUILD_DIR)/program_branch_loop.hex
VSP_UWORD_VECTOR_MEMORY_LOOP_SOURCE := \
	examples/uword/program_vector_memory_loop.uasm
VSP_UWORD_VECTOR_MEMORY_LOOP_HEX := \
	$(BUILD_DIR)/program_vector_memory_loop.hex
VSP_UWORD_PHYSICAL_MEMORY_SOURCE := \
	examples/uword/program_vector_memory_physical.uasm
VSP_UWORD_PHYSICAL_MEMORY_HEX := \
	$(BUILD_DIR)/program_vector_memory_physical.hex
VSP_HOST_MEMORY_FAULT_SOURCE := examples/uword/program_host_memory_fault.uasm
VSP_HOST_MEMORY_FAULT_HEX := $(BUILD_DIR)/program_host_memory_fault.hex
CLUSTER_RESULT_COLLECTOR_TOP := simd_cluster_result_collector
CLUSTER_RESULT_COLLECTOR_OBJ := $(BUILD_DIR)/cluster_result_collector_obj_dir
CLUSTER_RESULT_COLLECTOR_TB  := $(abspath sim/simd_cluster_result_collector_tb.cpp)
CLUSTER_EXEC_TOP := simd_cluster_exec
CLUSTER_EXEC_OBJ := $(BUILD_DIR)/cluster_exec_obj_dir
CLUSTER_EXEC_TB  := $(abspath sim/simd_cluster_exec_tb.cpp)
CLUSTER_EXEC_TRACKER_CREDIT_OBJ := \
	$(BUILD_DIR)/cluster_exec_tracker_credit_obj_dir
CLUSTER_EXEC_TRACKER_CREDIT_TB  := \
	$(abspath sim/simd_cluster_exec_tracker_credit_tb.cpp)
VECTOR_MEMORY_ENGINE_TOP := vsp_vector_memory_engine
VECTOR_MEMORY_ENGINE_OBJ := $(BUILD_DIR)/vector_memory_engine_obj_dir
VECTOR_MEMORY_ENGINE_TB  := $(abspath sim/vsp_vector_memory_engine_tb.cpp)
VECTOR_MEMORY_ENGINE_16GROUP_OBJ := \
	$(BUILD_DIR)/vector_memory_engine_16group_obj_dir
VECTOR_MEMORY_ENGINE_16GROUP_TB := \
	$(abspath sim/vsp_vector_memory_engine_16group_tb.cpp)
VSP_ORDERED_DMEM_MODEL_TOP := vsp_ordered_dmem_model
VSP_ORDERED_DMEM_MODEL_OBJ := $(BUILD_DIR)/ordered_dmem_model_obj_dir
VSP_ORDERED_DMEM_MODEL_TB := \
	$(abspath sim/vsp_ordered_dmem_model_tb.cpp)
VSP_ORDERED_DMEM_MODEL_RTL := $(RTL_VSP_PKG) \
	sim/models/vsp_ordered_dmem_model.sv
VSP_ORDERED_IFETCH_MODEL_TOP := vsp_ordered_ifetch_model
VSP_ORDERED_IFETCH_MODEL_OBJ := $(BUILD_DIR)/ordered_ifetch_model_obj_dir
VSP_ORDERED_IFETCH_MODEL_TB := \
	$(abspath sim/vsp_ordered_ifetch_model_tb.cpp)
VSP_ORDERED_IFETCH_MODEL_RTL := $(RTL_VSP_PKG) \
	sim/models/vsp_ordered_ifetch_model.sv
VSP_SEQUENCER_STATE_ENGINE_TOP := vsp_sequencer_state_engine
VSP_SEQUENCER_STATE_ENGINE_OBJ := \
	$(BUILD_DIR)/vsp_sequencer_state_engine_obj_dir
VSP_SEQUENCER_STATE_ENGINE_TB := \
	$(abspath sim/vsp_sequencer_state_engine_tb.cpp)
CLUSTER_VRF_ARBITER_TOP := vsp_cluster_vrf_arbiter
CLUSTER_VRF_ARBITER_OBJ := $(BUILD_DIR)/cluster_vrf_arbiter_obj_dir
CLUSTER_VRF_ARBITER_TB  := $(abspath sim/vsp_cluster_vrf_arbiter_tb.cpp)
CLUSTER_MEMORY_WRAPPER_TOP := vsp_cluster_memory_wrapper
CLUSTER_MEMORY_WRAPPER_OBJ := $(BUILD_DIR)/cluster_memory_wrapper_obj_dir
CLUSTER_MEMORY_WRAPPER_TB  := $(abspath sim/vsp_cluster_memory_wrapper_tb.cpp)
CLUSTER_REGISTER_ROUTE_TOP := vsp_cluster_register_route_engine
CLUSTER_REGISTER_ROUTE_OBJ := $(BUILD_DIR)/cluster_register_route_obj_dir
CLUSTER_REGISTER_ROUTE_TB := \
	$(abspath sim/vsp_cluster_register_route_engine_tb.cpp)
CLUSTER_REGISTER_ROUTE_RTL := $(RTL_VRF_GATHER) \
	$(RTL_CLUSTER_REGISTER_ROUTE_ENGINE)
VSP_DECODED_ACTION_CONTROLLER_TOP := vsp_decoded_action_controller
VSP_DECODED_ACTION_CONTROLLER_OBJ := \
	$(BUILD_DIR)/vsp_decoded_action_controller_obj_dir
VSP_DECODED_ACTION_CONTROLLER_TB := \
	$(abspath sim/vsp_decoded_action_controller_tb.cpp)
CLUSTER_CONTROLLER_WRAPPER_TOP := vsp_cluster_controller_wrapper
CLUSTER_CONTROLLER_WRAPPER_OBJ := \
	$(BUILD_DIR)/cluster_controller_wrapper_obj_dir
CLUSTER_CONTROLLER_WRAPPER_TB := \
	$(abspath sim/vsp_cluster_controller_wrapper_tb.cpp)
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
SEPARABLE_TOP := simd_datapath
SEPARABLE_OBJ := $(BUILD_DIR)/gaussian_separable_obj_dir
SEPARABLE_TB  := $(abspath sim/gaussian3x3_separable_tb.cpp)
SOBEL_TOP := simd_datapath
SOBEL_OBJ := $(BUILD_DIR)/sobel_obj_dir
SOBEL_TB  := $(abspath sim/sobel3x3_tb.cpp)
MEDIAN_TOP := simd_datapath
MEDIAN_OBJ := $(BUILD_DIR)/median_obj_dir
MEDIAN_TB  := $(abspath sim/median3x3_tb.cpp)
LANE_GATHER_TOP := vsp_lane_gather
LANE_GATHER_OBJ := $(BUILD_DIR)/vsp_lane_gather_obj_dir
LANE_GATHER_TB  := $(abspath sim/vsp_lane_gather_tb.cpp)
WORD_FIRST_GATHER_PHASE_TOP := vsp_word_first_gather_phase
WORD_FIRST_GATHER_PHASE_OBJ := $(BUILD_DIR)/word_first_gather_phase_obj_dir
WORD_FIRST_GATHER_PHASE_TB := \
	$(abspath sim/vsp_word_first_gather_phase_tb.cpp)
FOUR_PASS_GATHER_ENGINE_TOP := vsp_four_pass_gather_engine
FOUR_PASS_GATHER_ENGINE_OBJ := $(BUILD_DIR)/four_pass_gather_engine_obj_dir
FOUR_PASS_GATHER_ENGINE_TB := \
	$(abspath sim/vsp_four_pass_gather_engine_tb.cpp)
MUL32_MICRO_TB := sim/mul32_microcode_tb.cpp
MUL32_MICRO_BIN := $(BUILD_DIR)/mul32_microcode_tb

.PHONY: all lint test test-vcs-fft64 generate-fft64-vsp test-vsp-bfp \
	test-vsp-m8e8 \
	test-fft64-vsp plot-fft64-vsp plot-vcs-fft64-vsp \
	test-vcs-fft64-vsp prepare-verdi-fft64-vsp view-verdi-fft64-vsp \
	generate-fft64-mixed-vsp test-fft64-fixtures test-fft64-spectrum \
	test-fft64-mixed-vsp verify-fft64-mixed-vsp \
	plot-fft64-mixed-time-domain plot-fft64-mixed-vsp \
	test-vcs-fft64-mixed-vsp verify-vcs-fft64-mixed-vsp \
	plot-vcs-fft64-mixed-vsp compare-fft64-mixed-vsp \
	prepare-verdi-fft64-mixed-vsp view-verdi-fft64-mixed-vsp \
	test-vsp-exec-uword-expander \
	test-vsp-uword-predecoder test-vsp-uword-asm \
	test-vsp-uword-bundle-assembler \
	test-vsp-uword-multi-framer \
	test-vsp-uword-program-source \
	test-vsp-uword-program-frontend \
	test-vsp-uword-cluster-program \
	check-memory-ip-deps check-memory-ip-lock \
	lint-memory-integration test-memory-integration \
	lint-memory-product-integration test-memory-product-integration \
	lint-ifetch-product-integration lint-vsp-uword-memory-system \
	test-vsp-uword-memory-system test-vsp-ifetch-fault \
	lint-vsp-host-control test-vsp-host-control \
	lint-vsp-mmio-system test-vsp-mmio-system \
	test-vsp-uncached-device-merge \
	lint-vsp-uword-cached-program test-vsp-uword-cached-program \
	test-vsp-memory-uword-decoder test-vsp-control-uword-decoder \
	test-vsp-uword-action-adapter \
	test-vsp-ordered-action-window \
	test-vsp-route-rendezvous-table \
	test-vsp-route-wave-controller test-cluster-route-wave-pipeline \
	test-vsp-decoded-action-controller test-cluster-controller-wrapper \
	test-cluster-exec-tracker-credit \
	test-vsp-vector-memory-engine-16group \
	test-vsp-ordered-dmem-model test-vsp-ordered-ifetch-model \
	test-vsp-sequencer-state-engine test-cluster-vrf-arbiter \
	test-cluster-memory-wrapper test-cluster-register-route \
	test-vsp-word-first-gather-phase \
	test-vsp-four-pass-gather-engine test-experimental-routing \
	lint-experimental-routing clean

all: test

$(VCS_FFT64_SIM): $(VCS_FFT64_TB) $(VCS_FFT64_FIXTURES) Makefile
	mkdir -p $(VCS_FFT64_DIR)
	cd $(VCS_FFT64_DIR) && $(VCS) -full64 -sverilog -timescale=1ns/1ps \
		-LDFLAGS $(VCS_LDFLAGS) \
		-Mdir=$(abspath $(VCS_FFT64_DIR)/csrc) \
		-l compile.log \
		-o $(abspath $@) $(abspath $(VCS_FFT64_TB))

# Opt-in: VCS is a licensed commercial simulator and is not a requirement of
# the default Verilator regression.
test-vcs-fft64: $(VCS_FFT64_SIM)
	$(VCS_FFT64_SIM) -l $(VCS_FFT64_DIR)/run.log

generate-fft64-vsp:
	$(PYTHON) $(FFT64_VSP_GENERATOR) --output-dir $(FFT64_VSP_ARTIFACT_DIR)

generate-fft64-mixed-vsp:
	$(PYTHON) $(FFT64_VSP_GENERATOR) --waveform mixed \
		--output-dir $(FFT64_MIXED_ARTIFACT_DIR)

test-fft64-fixtures:
	$(PYTHON) $(FFT64_FIXTURE_TB)

test-fft64-spectrum:
	$(PYTHON) $(FFT64_SPECTRUM_TB)

test-vsp-bfp:
	$(PYTHON) $(VSP_BFP_TB)

test-vsp-m8e8:
	$(PYTHON) $(VSP_M8E8_TB)

$(FFT64_VSP_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP): \
		$(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) $(FFT64_VSP_TB) \
		$(BUILD_META) $(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --trace --trace-depth 4 \
		--cc --exe --top-module $(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP) \
		--Mdir $(FFT64_VSP_OBJ) \
		$(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) $(FFT64_VSP_TB)
	$(MAKE) -C $(FFT64_VSP_OBJ) \
		-f V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP).mk

test-fft64-vsp: test-vsp-bfp generate-fft64-vsp check-memory-ip-lock \
		$(FFT64_VSP_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP)
	$(FFT64_VSP_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP) \
		$(FFT64_VSP_PROGRAM) $(FFT64_VSP_DATA) $(FFT64_VSP_GOLDEN) \
		$(FFT64_VSP_OUTPUT) $(FFT64_VSP_VCD) $(FFT64_VSP_CSV) 1 8

plot-fft64-vsp: test-fft64-vsp
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(FFT64_VSP_CSV) \
		--output-prefix $(FFT64_VSP_PLOT_PREFIX) \
		--title "FFT64 static-BFP8 spectrum (Verilator)" \
		--neato $(GRAPHVIZ_NEATO)

test-fft64-mixed-vsp: test-vsp-bfp test-fft64-fixtures \
		generate-fft64-mixed-vsp check-memory-ip-lock \
		$(FFT64_VSP_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP)
	$(FFT64_VSP_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP) \
		$(FFT64_MIXED_PROGRAM) $(FFT64_MIXED_DATA) \
		$(FFT64_MIXED_GOLDEN) $(FFT64_MIXED_OUTPUT) \
		$(FFT64_MIXED_VCD) $(FFT64_MIXED_CSV) 64 127

verify-fft64-mixed-vsp: test-fft64-spectrum test-fft64-mixed-vsp
	$(PYTHON) $(FFT64_SPECTRUM_VERIFIER) \
		$(FFT64_MIXED_INPUT_CSV) $(FFT64_MIXED_CSV) \
		--input-code-denominator 127 \
		--manifest $(FFT64_MIXED_MANIFEST) \
		--reference-csv $(FFT64_MIXED_DFT_CSV) \
		--comparison-csv $(FFT64_MIXED_COMPARE_CSV) \
		--metrics-json $(FFT64_MIXED_METRICS)

plot-fft64-mixed-time-domain: generate-fft64-mixed-vsp
	$(PYTHON) $(FFT64_INPUT_PLOTTER) $(FFT64_MIXED_INPUT_CSV) \
		--input-code-denominator 127 \
		--output-prefix $(FFT64_MIXED_TIME_PLOT_PREFIX) \
		--title "FFT64 q/127 three-tone input waveform" \
		--neato $(GRAPHVIZ_NEATO)

plot-fft64-mixed-vsp: verify-fft64-mixed-vsp plot-fft64-mixed-time-domain
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(FFT64_MIXED_CSV) \
		--view components \
		--output-prefix $(FFT64_MIXED_PLOT_PREFIX)_components \
		--title "FFT64 three-tone spectrum components (Verilator)" \
		--neato $(GRAPHVIZ_NEATO)
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(FFT64_MIXED_CSV) \
		--view one-sided-amplitude \
		--output-prefix $(FFT64_MIXED_PLOT_PREFIX)_one_sided_amplitude \
		--title "FFT64 three-tone one-sided amplitude (Verilator)" \
		--neato $(GRAPHVIZ_NEATO)
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(FFT64_MIXED_CSV) \
		--view relative-db \
		--output-prefix $(FFT64_MIXED_PLOT_PREFIX)_relative_db \
		--title "FFT64 three-tone relative spectrum (Verilator)" \
		--neato $(GRAPHVIZ_NEATO)

$(VCS_FFT64_VSP_SIM): $(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) \
		$(VCS_FFT64_VSP_TB) $(BUILD_META) $(VSP_MEMORY_IP_LOCK)
	mkdir -p $(VCS_FFT64_VSP_DIR)
	cd $(VCS_FFT64_VSP_DIR) && $(VCS) -full64 -sverilog \
		-timescale=1ns/1ps -top fft64_vsp_vcs_tb \
		+define+FFT64_VCS_WAVE -debug_access+all -kdb \
		-LDFLAGS $(VCS_LDFLAGS) \
		-Mdir=$(abspath $(VCS_FFT64_VSP_DIR)/csrc) -l compile.log \
		-o $(abspath $@) $(abspath $(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL)) \
		$(VCS_FFT64_VSP_TB)

$(VCS_FFT64_MIXED_SIM): $(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) \
		$(VCS_FFT64_VSP_TB) $(BUILD_META) $(VSP_MEMORY_IP_LOCK)
	mkdir -p $(VCS_FFT64_MIXED_DIR)
	cd $(VCS_FFT64_MIXED_DIR) && $(VCS) -full64 -sverilog \
		-timescale=1ns/1ps -top fft64_vsp_vcs_tb \
		+define+FFT64_VCS_WAVE -debug_access+all -kdb \
		-LDFLAGS $(VCS_LDFLAGS) \
		-Mdir=$(abspath $(VCS_FFT64_MIXED_DIR)/csrc) -l compile.log \
		-o $(abspath $@) $(abspath $(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL)) \
		$(VCS_FFT64_VSP_TB)

# Optional licensed run.  The same generated program/data/golden files are
# installed through the backing SRAM sideband before normal I/D-cache traffic.
test-vcs-fft64-vsp: test-vsp-bfp generate-fft64-vsp check-memory-ip-lock \
		$(VCS_FFT64_VSP_SIM)
	cd $(VCS_FFT64_VSP_DIR) && ./simv \
		+PROGRAM_HEX=$(abspath $(FFT64_VSP_PROGRAM)) \
		+DATA_HEX=$(abspath $(FFT64_VSP_DATA)) \
		+GOLDEN_HEX=$(abspath $(FFT64_VSP_GOLDEN)) \
		+OUTPUT_HEX=$(abspath $(VCS_FFT64_VSP_DIR)/fft64_q7_vcs_output.hex) \
		+CSV_FILE=$(VCS_FFT64_VSP_CSV) \
		+SCALE_NUM=1 +SCALE_DEN=8 \
		+WAVE_FILE=$(VCS_FFT64_VSP_VPD) -l run.log

test-vcs-fft64-mixed-vsp: test-vsp-bfp test-fft64-fixtures \
		generate-fft64-mixed-vsp check-memory-ip-lock \
		$(VCS_FFT64_MIXED_SIM)
	cd $(VCS_FFT64_MIXED_DIR) && ./simv \
		+PROGRAM_HEX=$(abspath $(FFT64_MIXED_PROGRAM)) \
		+DATA_HEX=$(abspath $(FFT64_MIXED_DATA)) \
		+GOLDEN_HEX=$(abspath $(FFT64_MIXED_GOLDEN)) \
		+OUTPUT_HEX=$(abspath $(VCS_FFT64_MIXED_DIR)/fft64_mixed_vcs_output.hex) \
		+CSV_FILE=$(VCS_FFT64_MIXED_CSV) \
		+SCALE_NUM=64 +SCALE_DEN=127 \
		+WAVE_FILE=$(VCS_FFT64_MIXED_VPD) -l run.log

verify-vcs-fft64-mixed-vsp: test-fft64-spectrum test-vcs-fft64-mixed-vsp
	$(PYTHON) $(FFT64_SPECTRUM_VERIFIER) \
		$(FFT64_MIXED_INPUT_CSV) $(VCS_FFT64_MIXED_CSV) \
		--input-code-denominator 127 \
		--manifest $(FFT64_MIXED_MANIFEST) \
		--reference-csv $(VCS_FFT64_MIXED_DFT_CSV) \
		--comparison-csv $(VCS_FFT64_MIXED_COMPARE_CSV) \
		--metrics-json $(VCS_FFT64_MIXED_METRICS)

compare-fft64-mixed-vsp: verify-fft64-mixed-vsp verify-vcs-fft64-mixed-vsp
	cmp $(FFT64_MIXED_OUTPUT) \
		$(VCS_FFT64_MIXED_DIR)/fft64_mixed_vcs_output.hex
	cmp $(FFT64_MIXED_CSV) $(VCS_FFT64_MIXED_CSV)

plot-vcs-fft64-vsp: test-vcs-fft64-vsp
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(VCS_FFT64_VSP_CSV) \
		--output-prefix $(VCS_FFT64_VSP_PLOT_PREFIX) \
		--title "FFT64 static-BFP8 spectrum (VCS)" \
		--neato $(GRAPHVIZ_NEATO)

plot-vcs-fft64-mixed-vsp: verify-vcs-fft64-mixed-vsp \
		plot-fft64-mixed-time-domain
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(VCS_FFT64_MIXED_CSV) \
		--view components \
		--output-prefix $(VCS_FFT64_MIXED_PLOT_PREFIX)_components \
		--title "FFT64 three-tone spectrum components (VCS)" \
		--neato $(GRAPHVIZ_NEATO)
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(VCS_FFT64_MIXED_CSV) \
		--view one-sided-amplitude \
		--output-prefix $(VCS_FFT64_MIXED_PLOT_PREFIX)_one_sided_amplitude \
		--title "FFT64 three-tone one-sided amplitude (VCS)" \
		--neato $(GRAPHVIZ_NEATO)
	$(PYTHON) $(FFT64_VSP_PLOTTER) $(VCS_FFT64_MIXED_CSV) \
		--view relative-db \
		--output-prefix $(VCS_FFT64_MIXED_PLOT_PREFIX)_relative_db \
		--title "FFT64 three-tone relative spectrum (VCS)" \
		--neato $(GRAPHVIZ_NEATO)

# Convert the VCS VPD into an FSDB that Verdi can open without an interactive
# VCD conversion prompt.  Run test-vcs-fft64-vsp first to create the VPD.
prepare-verdi-fft64-vsp:
	@test -f $(VCS_FFT64_VSP_VPD) || { \
		echo "missing $(VCS_FFT64_VSP_VPD); run make test-vcs-fft64-vsp first" >&2; \
		exit 1; \
	}
	cd $(VCS_FFT64_VSP_DIR) && $(VPD2VCD) fft64_vsp.vpd fft64_vsp_vcs.vcd
	cd $(VCS_FFT64_VSP_DIR) && $(VFAST) fft64_vsp_vcs.vcd \
		-o fft64_vsp_vcs.fsdb

view-verdi-fft64-vsp: prepare-verdi-fft64-vsp
	cd $(VCS_FFT64_VSP_DIR) && $(VERDI) -undockWin -dbdir simv.daidir \
		-ssf fft64_vsp_vcs.fsdb -play $(VCS_FFT64_VSP_VERDI_SCRIPT) -nologo

prepare-verdi-fft64-mixed-vsp:
	@test -f $(VCS_FFT64_MIXED_VPD) || { \
		echo "missing $(VCS_FFT64_MIXED_VPD); run make test-vcs-fft64-mixed-vsp first" >&2; \
		exit 1; \
	}
	cd $(VCS_FFT64_MIXED_DIR) && $(VPD2VCD) fft64_mixed_vsp.vpd \
		fft64_mixed_vsp_vcs.vcd
	cd $(VCS_FFT64_MIXED_DIR) && $(VFAST) fft64_mixed_vsp_vcs.vcd \
		-o fft64_mixed_vsp_vcs.fsdb

view-verdi-fft64-mixed-vsp: prepare-verdi-fft64-mixed-vsp
	cd $(VCS_FFT64_MIXED_DIR) && $(VERDI) -undockWin -dbdir simv.daidir \
		-ssf fft64_mixed_vsp_vcs.fsdb \
		-play $(VCS_FFT64_VSP_VERDI_SCRIPT) -nologo

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) \
		-GELEM_W=8 -GACC_W=16 $(RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module $(TOP) \
		-GELEM_W=16 -GACC_W=32 $(RTL)
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
		--top-module $(ISSUE_DECODE_STAGE_TOP) $(ISSUE_DECODE_STAGE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(ISSUE_DECODE_STAGE_TOP) -GRAW_WORD_W=17 \
		-GRESOLVED_W=9 -GCACHED_META_W=7 -GCONTEXT_W=2 \
		-GGROUP_COUNT=6 -GRESOURCE_W=11 -GCANONICAL_PAYLOAD_W=53 \
		$(ISSUE_DECODE_STAGE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_EXEC_UWORD_EXPANDER_TOP) \
		$(VSP_EXEC_UWORD_EXPANDER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_PREDECODER_TOP) \
		$(VSP_UWORD_PREDECODER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_PREDECODER_TOP) -GBUNDLE_WORDS=8 \
		$(VSP_UWORD_PREDECODER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_MULTI_FRAMER_TOP) \
		$(VSP_UWORD_MULTI_FRAMER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_MULTI_FRAMER_TOP) -GPC_W=40 \
		-GBUNDLE_WORDS=5 -GADMIT_SLOTS=2 \
		$(VSP_UWORD_MULTI_FRAMER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_PROGRAM_SOURCE_TOP) \
		$(VSP_UWORD_PROGRAM_SOURCE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_PROGRAM_FRONTEND_TOP) \
		$(VSP_UWORD_PROGRAM_FRONTEND_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_PROGRAM_FRONTEND_TOP) -GPC_W=40 \
		-GSTORE_WORDS=17 -GBUNDLE_WORDS=3 \
		$(VSP_UWORD_PROGRAM_FRONTEND_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_CLUSTER_PROGRAM_TOP) \
		$(VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_CLUSTER_PROGRAM_TOP) -GFETCH_WORDS=2 \
		-GGROUP_COUNT=16 -GISSUE_SLOTS=1 -GCONTEXT_COUNT=1 \
		$(VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_MEMORY_UWORD_DECODER_TOP) \
		-GMAX_SPAN_BYTES=4 $(VSP_MEMORY_UWORD_DECODER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_CONTROL_UWORD_DECODER_TOP) \
		-GSTATE_REGS=5 $(VSP_CONTROL_UWORD_DECODER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_UWORD_ACTION_ADAPTER_TOP) \
		$(VSP_UWORD_ACTION_ADAPTER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_ACTION_WINDOW_TOP) \
		$(VSP_ORDERED_ACTION_WINDOW_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_ACTION_WINDOW_TOP) \
		-GGROUP_COUNT=6 -GWINDOW_DEPTH=5 -GADMIT_LANES=4 \
		-GEXEC_SLOTS=3 -GSIDE_SLOTS=2 -GCOMPLETION_LANES=4 \
		-GRETIRE_SLOTS=4 \
		-GPC_W=40 -GSEQ_W=8 -GDEP_W=11 \
		$(VSP_ORDERED_ACTION_WINDOW_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_RESULT_COLLECTOR_TOP) \
		$(CLUSTER_RESULT_COLLECTOR_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_RESULT_COLLECTOR_TOP) -GGROUP_COUNT=6 \
		-GLANES=8 -GCONTEXT_COUNT=3 $(CLUSTER_RESULT_COLLECTOR_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_EXEC_TOP) $(CLUSTER_EXEC_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_EXEC_TOP) -GGROUP_COUNT=6 \
		-GISSUE_SLOTS=3 -GQUEUE_DEPTH=3 -GTRACKER_ENTRIES=5 \
		-GLANES=8 -GCONTEXT_COUNT=3 $(CLUSTER_EXEC_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VECTOR_MEMORY_ENGINE_TOP) $(VECTOR_MEMORY_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VECTOR_MEMORY_ENGINE_TOP) -GGROUP_COUNT=6 \
		-GVRF_ROWS=7 -GEXEC_CONTEXT_COUNT=3 -GMEM_OFFSET_W=12 \
		-GADDR_CONTEXT_W=5 $(VECTOR_MEMORY_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_DMEM_MODEL_TOP) \
		$(VSP_ORDERED_DMEM_MODEL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_DMEM_MODEL_TOP) \
		-GBEAT_BYTES=8 -GMEM_BYTES=512 -GOUTSTANDING_DEPTH=1 \
		-GRESPONSE_LATENCY=1 $(VSP_ORDERED_DMEM_MODEL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_IFETCH_MODEL_TOP) \
		$(VSP_ORDERED_IFETCH_MODEL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ORDERED_IFETCH_MODEL_TOP) \
		-GMAX_WORDS=3 -GMEM_WORDS=17 -GOUTSTANDING_DEPTH=1 \
		-GRESPONSE_LATENCY=1 $(VSP_ORDERED_IFETCH_MODEL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_SEQUENCER_STATE_ENGINE_TOP) \
		$(VSP_SEQUENCER_STATE_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_SEQUENCER_STATE_ENGINE_TOP) \
		-GSTATE_REGS=5 -GCONTEXT_COUNT=3 -GTAG_W=6 \
		$(VSP_SEQUENCER_STATE_ENGINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_VRF_ARBITER_TOP) \
		$(CLUSTER_VRF_ARBITER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_VRF_ARBITER_TOP) -GCLIENT_COUNT=3 \
		-GGROUP_COUNT=6 -GVRF_ROWS=7 -GEXEC_CONTEXT_COUNT=3 \
		$(CLUSTER_VRF_ARBITER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_MEMORY_WRAPPER_TOP) \
		$(CLUSTER_MEMORY_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_MEMORY_WRAPPER_TOP) -GGROUP_COUNT=16 \
		-GISSUE_SLOTS=1 -GQUEUE_DEPTH=4 -GTRACKER_ENTRIES=4 \
		-GLANES=4 -GCONTEXT_COUNT=1 $(CLUSTER_MEMORY_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_DECODED_ACTION_CONTROLLER_TOP) \
		$(VSP_DECODED_ACTION_CONTROLLER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_DECODED_ACTION_CONTROLLER_TOP) \
		-GGROUP_COUNT=6 -GCONTEXT_COUNT=3 -GTAG_W=5 \
		-GEXEC_PAYLOAD_W=17 -GMEMORY_PAYLOAD_W=19 \
		-GEXEC_CPL_PAYLOAD_W=11 -GMEMORY_CPL_PAYLOAD_W=23 \
		$(VSP_DECODED_ACTION_CONTROLLER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_CONTROLLER_WRAPPER_TOP) \
		$(CLUSTER_CONTROLLER_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_CONTROLLER_WRAPPER_TOP) -GGROUP_COUNT=16 \
		-GISSUE_SLOTS=1 -GQUEUE_DEPTH=4 -GTRACKER_ENTRIES=4 \
		-GCONTEXT_COUNT=1 $(CLUSTER_CONTROLLER_WRAPPER_RTL)
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

# Retired cross-group register-routing experiments stay callable for design
# comparison, but they are intentionally outside the product-path lint/test.
lint-experimental-routing:
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(BENES_TOP) $(BENES_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ROUTE_RENDEZVOUS_TOP) \
		$(VSP_ROUTE_RENDEZVOUS_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(VSP_ROUTE_WAVE_CONTROLLER_TOP) \
		$(VSP_ROUTE_WAVE_CONTROLLER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_REGISTER_ROUTE_TOP) \
		$(CLUSTER_REGISTER_ROUTE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(CLUSTER_ROUTE_WAVE_PIPELINE_TOP) \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(LANE_GATHER_TOP) $(LANE_GATHER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(WORD_FIRST_GATHER_PHASE_TOP) \
		$(WORD_FIRST_GATHER_PHASE_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(FOUR_PASS_GATHER_ENGINE_TOP) \
		$(FOUR_PASS_GATHER_ENGINE_RTL)

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

$(ISSUE_DECODE_STAGE_OBJ)/V$(ISSUE_DECODE_STAGE_TOP): \
		$(ISSUE_DECODE_STAGE_RTL) $(ISSUE_DECODE_STAGE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(ISSUE_DECODE_STAGE_TOP) -GRAW_WORD_W=12 \
		-GRESOLVED_W=7 -GCACHED_META_W=6 -GCONTEXT_W=2 \
		-GGROUP_COUNT=4 -GRESOURCE_W=5 -GCANONICAL_PAYLOAD_W=16 \
		-GDECODE_META_W=7 -GERROR_CAUSE_W=3 \
		--Mdir $(ISSUE_DECODE_STAGE_OBJ) $(ISSUE_DECODE_STAGE_RTL) \
		$(ISSUE_DECODE_STAGE_TB)
	$(MAKE) -C $(ISSUE_DECODE_STAGE_OBJ) \
		-f V$(ISSUE_DECODE_STAGE_TOP).mk

$(VSP_EXEC_UWORD_EXPANDER_OBJ)/V$(VSP_EXEC_UWORD_EXPANDER_TOP): \
		$(VSP_EXEC_UWORD_EXPANDER_RTL) $(VSP_EXEC_UWORD_EXPANDER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_EXEC_UWORD_EXPANDER_TOP) \
		--Mdir $(VSP_EXEC_UWORD_EXPANDER_OBJ) \
		$(VSP_EXEC_UWORD_EXPANDER_RTL) $(VSP_EXEC_UWORD_EXPANDER_TB)
	$(MAKE) -C $(VSP_EXEC_UWORD_EXPANDER_OBJ) \
		-f V$(VSP_EXEC_UWORD_EXPANDER_TOP).mk

test-vsp-exec-uword-expander: \
		$(VSP_EXEC_UWORD_EXPANDER_OBJ)/V$(VSP_EXEC_UWORD_EXPANDER_TOP)
	$(VSP_EXEC_UWORD_EXPANDER_OBJ)/V$(VSP_EXEC_UWORD_EXPANDER_TOP)

$(VSP_UWORD_PREDECODER_OBJ)/V$(VSP_UWORD_PREDECODER_TOP): \
		$(VSP_UWORD_PREDECODER_RTL) $(VSP_UWORD_PREDECODER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_PREDECODER_TOP) \
		--Mdir $(VSP_UWORD_PREDECODER_OBJ) \
		$(VSP_UWORD_PREDECODER_RTL) $(VSP_UWORD_PREDECODER_TB)
	$(MAKE) -C $(VSP_UWORD_PREDECODER_OBJ) \
		-f V$(VSP_UWORD_PREDECODER_TOP).mk

test-vsp-uword-predecoder: \
		$(VSP_UWORD_PREDECODER_OBJ)/V$(VSP_UWORD_PREDECODER_TOP)
	$(VSP_UWORD_PREDECODER_OBJ)/V$(VSP_UWORD_PREDECODER_TOP)

$(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ)/V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP): \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_RTL) \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_BUNDLE_ASSEMBLER_TOP) \
		--Mdir $(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ) \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_RTL) \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_TB)
	$(MAKE) -C $(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ) \
		-f V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP).mk

test-vsp-uword-bundle-assembler: \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ)/V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP)
	$(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ)/V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP)

$(VSP_UWORD_MULTI_FRAMER_OBJ)/V$(VSP_UWORD_MULTI_FRAMER_TOP): \
		$(VSP_UWORD_MULTI_FRAMER_RTL) \
		$(VSP_UWORD_MULTI_FRAMER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_MULTI_FRAMER_TOP) \
		--Mdir $(VSP_UWORD_MULTI_FRAMER_OBJ) \
		$(VSP_UWORD_MULTI_FRAMER_RTL) \
		$(VSP_UWORD_MULTI_FRAMER_TB)
	$(MAKE) -C $(VSP_UWORD_MULTI_FRAMER_OBJ) \
		-f V$(VSP_UWORD_MULTI_FRAMER_TOP).mk

test-vsp-uword-multi-framer: \
		$(VSP_UWORD_MULTI_FRAMER_OBJ)/V$(VSP_UWORD_MULTI_FRAMER_TOP)
	$(VSP_UWORD_MULTI_FRAMER_OBJ)/V$(VSP_UWORD_MULTI_FRAMER_TOP)

$(VSP_UWORD_PROGRAM_SOURCE_OBJ)/V$(VSP_UWORD_PROGRAM_SOURCE_TOP): \
		$(VSP_UWORD_PROGRAM_SOURCE_RTL) \
		$(VSP_UWORD_PROGRAM_SOURCE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_PROGRAM_SOURCE_TOP) \
		--Mdir $(VSP_UWORD_PROGRAM_SOURCE_OBJ) \
		$(VSP_UWORD_PROGRAM_SOURCE_RTL) \
		$(VSP_UWORD_PROGRAM_SOURCE_TB)
	$(MAKE) -C $(VSP_UWORD_PROGRAM_SOURCE_OBJ) \
		-f V$(VSP_UWORD_PROGRAM_SOURCE_TOP).mk

test-vsp-uword-program-source: \
		$(VSP_UWORD_PROGRAM_SOURCE_OBJ)/V$(VSP_UWORD_PROGRAM_SOURCE_TOP)
	$(VSP_UWORD_PROGRAM_SOURCE_OBJ)/V$(VSP_UWORD_PROGRAM_SOURCE_TOP)

test-vsp-uword-asm:
	$(PYTHON) $(VSP_UWORD_ASM_TB)

$(VSP_UWORD_PC_HEX): $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_PC_SOURCE) \
		$(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_PC_SOURCE) \
		-o $@ --base-pc 0x20 --listing $(VSP_UWORD_PC_LISTING) \
		--symbols $(VSP_UWORD_PC_SYMBOLS)

$(VSP_UWORD_PROGRAM_FRONTEND_OBJ)/V$(VSP_UWORD_PROGRAM_FRONTEND_TOP): \
		$(VSP_UWORD_PROGRAM_FRONTEND_RTL) \
		$(VSP_UWORD_PROGRAM_FRONTEND_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_PROGRAM_FRONTEND_TOP) \
		-GSTORE_WORDS=16 -GSTORE_BASE_PC=32 \
		--Mdir $(VSP_UWORD_PROGRAM_FRONTEND_OBJ) \
		$(VSP_UWORD_PROGRAM_FRONTEND_RTL) \
		$(VSP_UWORD_PROGRAM_FRONTEND_TB)
	$(MAKE) -C $(VSP_UWORD_PROGRAM_FRONTEND_OBJ) \
		-f V$(VSP_UWORD_PROGRAM_FRONTEND_TOP).mk

test-vsp-uword-program-frontend: $(VSP_UWORD_PC_HEX) \
		$(VSP_UWORD_PROGRAM_FRONTEND_OBJ)/V$(VSP_UWORD_PROGRAM_FRONTEND_TOP)
	$(VSP_UWORD_PROGRAM_FRONTEND_OBJ)/V$(VSP_UWORD_PROGRAM_FRONTEND_TOP) \
		$(VSP_UWORD_PC_HEX)

$(VSP_UWORD_EXEC_END_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_UWORD_EXEC_END_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_EXEC_END_SOURCE) \
		-o $@ --base-pc 0x20

$(VSP_UWORD_MEMORY_STATE_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_UWORD_MEMORY_STATE_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_MEMORY_STATE_SOURCE) \
		-o $@ --base-pc 0x20

$(VSP_UWORD_BRANCH_LOOP_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_UWORD_BRANCH_LOOP_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_BRANCH_LOOP_SOURCE) \
		-o $@ --base-pc 0x20

$(VSP_UWORD_VECTOR_MEMORY_LOOP_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_UWORD_VECTOR_MEMORY_LOOP_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_VECTOR_MEMORY_LOOP_SOURCE) \
		-o $@ --base-pc 0x20

$(VSP_UWORD_PHYSICAL_MEMORY_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_UWORD_PHYSICAL_MEMORY_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_UWORD_PHYSICAL_MEMORY_SOURCE) \
		-o $@ --base-pc 0x20

$(VSP_HOST_MEMORY_FAULT_HEX): $(VSP_UWORD_ASM_TOOL) \
		$(VSP_HOST_MEMORY_FAULT_SOURCE) $(BUILD_META) | $(BUILD_DIR)
	$(PYTHON) $(VSP_UWORD_ASM_TOOL) $(VSP_HOST_MEMORY_FAULT_SOURCE) \
		-o $@ --base-pc 0x200

$(VSP_UWORD_CLUSTER_PROGRAM_OBJ)/V$(VSP_UWORD_CLUSTER_PROGRAM_TOP): \
		$(VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL) \
		$(VSP_UWORD_CLUSTER_PROGRAM_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_CLUSTER_PROGRAM_TOP) \
		-GSTORE_WORDS=16 -GSTORE_BASE_PC=32 \
		--Mdir $(VSP_UWORD_CLUSTER_PROGRAM_OBJ) \
		$(VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL) \
		$(VSP_UWORD_CLUSTER_PROGRAM_TB)
	$(MAKE) -C $(VSP_UWORD_CLUSTER_PROGRAM_OBJ) \
		-f V$(VSP_UWORD_CLUSTER_PROGRAM_TOP).mk

test-vsp-uword-cluster-program: $(VSP_UWORD_EXEC_END_HEX) \
		$(VSP_UWORD_MEMORY_STATE_HEX) $(VSP_UWORD_BRANCH_LOOP_HEX) \
		$(VSP_UWORD_VECTOR_MEMORY_LOOP_HEX) \
		$(VSP_UWORD_CLUSTER_PROGRAM_OBJ)/V$(VSP_UWORD_CLUSTER_PROGRAM_TOP)
	$(VSP_UWORD_CLUSTER_PROGRAM_OBJ)/V$(VSP_UWORD_CLUSTER_PROGRAM_TOP) \
		$(VSP_UWORD_EXEC_END_HEX) $(VSP_UWORD_MEMORY_STATE_HEX) \
		$(VSP_UWORD_BRANCH_LOOP_HEX) $(VSP_UWORD_VECTOR_MEMORY_LOOP_HEX)

check-memory-ip-deps:
	@missing=0; \
	for source in $(VSP_EXTERNAL_MEMORY_IP_REQUIRED); do \
		if test ! -f "$$source"; then \
			echo "missing memory IP source: $$source" >&2; \
			missing=1; \
		fi; \
	done; \
	test "$$missing" -eq 0

check-memory-ip-lock: check-memory-ip-deps $(VSP_MEMORY_IP_LOCK)
	@set -- $(VSP_EXTERNAL_MEMORY_IP_RTL); \
	failed=0; \
	while read -r expected logical_source; do \
		if test "$$#" -eq 0; then \
			echo "memory IP lock has no matching source: $$logical_source" >&2; \
			failed=1; \
			continue; \
		fi; \
		actual_source="$$1"; \
		shift; \
		actual=$$(sha256sum "$$actual_source" | awk '{print $$1}'); \
		if test "$$actual" = "$$expected"; then \
			echo "$$logical_source ($$actual_source): OK"; \
		else \
			echo "memory IP content mismatch: $$logical_source" >&2; \
			echo "  source:   $$actual_source" >&2; \
			echo "  expected: $$expected" >&2; \
			echo "  actual:   $$actual" >&2; \
			failed=1; \
		fi; \
	done < $(VSP_MEMORY_IP_LOCK); \
	if test "$$#" -ne 0; then \
		echo "memory IP source list has $$# unlocked entries" >&2; \
		failed=1; \
	fi; \
	test "$$failed" -eq 0

lint-memory-integration: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_DMEM_SUBSYSTEM_TOP) \
		$(VSP_DMEM_SUBSYSTEM_TEST_RTL)

lint-memory-product-integration: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_DMEM_CACHED_FABRIC_TOP) \
		$(VSP_DMEM_CACHED_FABRIC_WRAPPER_RTL)

lint-ifetch-product-integration: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_IFETCH_CACHED_CLIENT_TOP) \
		$(VSP_IFETCH_CACHED_CLIENT_WRAPPER_RTL)

lint-vsp-uword-memory-system: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_UWORD_MEMORY_SYSTEM_TOP) \
		$(VSP_UWORD_MEMORY_SYSTEM_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_UWORD_MEMORY_SYSTEM_TOP) \
		-GICACHE_LINE_BYTES=64 -GDCACHE_LINE_BYTES=32 \
		$(VSP_UWORD_MEMORY_SYSTEM_WRAPPER_RTL)

lint-vsp-uword-cached-program: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module $(VSP_UWORD_CACHED_PROGRAM_TOP) \
		$(VSP_UWORD_CACHED_PROGRAM_WRAPPER_RTL)

lint-vsp-host-control: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module vsp_host_control $(VSP_HOST_CONTROL_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module vsp_host_control \
		-GGROUP_COUNT=16 -GPADDR_W=32 -GTAG_W=4 -GASID_W=4 \
		$(VSP_HOST_CONTROL_RTL)

lint-vsp-mmio-system: check-memory-ip-lock
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module vsp_mmio_system_wrapper $(VSP_MMIO_SYSTEM_WRAPPER_RTL)
	$(VERILATOR) --lint-only -Wall -Wno-fatal --assert \
		--top-module vsp_mmio_system_wrapper -GGROUP_COUNT=16 -GPADDR_W=32 \
		$(VSP_MMIO_SYSTEM_WRAPPER_RTL)

$(VSP_HOST_CONTROL_OBJ)/V$(VSP_HOST_CONTROL_TEST_TOP): \
		$(VSP_HOST_CONTROL_TEST_RTL) $(VSP_HOST_CONTROL_TB) \
		$(BUILD_META) $(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_HOST_CONTROL_TEST_TOP) --Mdir $(VSP_HOST_CONTROL_OBJ) \
		$(VSP_HOST_CONTROL_TEST_RTL) $(VSP_HOST_CONTROL_TB)
	$(MAKE) -C $(VSP_HOST_CONTROL_OBJ) -f V$(VSP_HOST_CONTROL_TEST_TOP).mk

test-vsp-host-control: check-memory-ip-lock \
		$(VSP_HOST_CONTROL_OBJ)/V$(VSP_HOST_CONTROL_TEST_TOP)
	$(VSP_HOST_CONTROL_OBJ)/V$(VSP_HOST_CONTROL_TEST_TOP)

$(VSP_MMIO_SYSTEM_OBJ)/V$(VSP_MMIO_SYSTEM_TEST_TOP): \
		$(VSP_MMIO_SYSTEM_TEST_RTL) $(VSP_MMIO_SYSTEM_TB) \
		$(BUILD_META) $(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_MMIO_SYSTEM_TEST_TOP) --Mdir $(VSP_MMIO_SYSTEM_OBJ) \
		$(VSP_MMIO_SYSTEM_TEST_RTL) $(VSP_MMIO_SYSTEM_TB)
	$(MAKE) -C $(VSP_MMIO_SYSTEM_OBJ) -f V$(VSP_MMIO_SYSTEM_TEST_TOP).mk

test-vsp-mmio-system: check-memory-ip-lock \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX) $(VSP_HOST_MEMORY_FAULT_HEX) \
		$(VSP_MMIO_SYSTEM_OBJ)/V$(VSP_MMIO_SYSTEM_TEST_TOP)
	$(VSP_MMIO_SYSTEM_OBJ)/V$(VSP_MMIO_SYSTEM_TEST_TOP) \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX) $(VSP_HOST_MEMORY_FAULT_HEX)

$(VSP_DMEM_CACHED_FABRIC_OBJ)/V$(VSP_DMEM_CACHED_FABRIC_TEST_TOP): \
		$(VSP_DMEM_CACHED_FABRIC_TEST_RTL) \
		$(VSP_DMEM_CACHED_FABRIC_TB) $(BUILD_META) \
		$(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_DMEM_CACHED_FABRIC_TEST_TOP) \
		--Mdir $(VSP_DMEM_CACHED_FABRIC_OBJ) \
		$(VSP_DMEM_CACHED_FABRIC_TEST_RTL) \
		$(VSP_DMEM_CACHED_FABRIC_TB)
	$(MAKE) -C $(VSP_DMEM_CACHED_FABRIC_OBJ) \
		-f V$(VSP_DMEM_CACHED_FABRIC_TEST_TOP).mk

test-memory-product-integration: check-memory-ip-lock \
		$(VSP_DMEM_CACHED_FABRIC_OBJ)/V$(VSP_DMEM_CACHED_FABRIC_TEST_TOP)
	$(VSP_DMEM_CACHED_FABRIC_OBJ)/V$(VSP_DMEM_CACHED_FABRIC_TEST_TOP)

$(VSP_UNCACHED_DEVICE_MERGE_OBJ)/V$(VSP_UNCACHED_DEVICE_MERGE_TEST_TOP): \
		$(VSP_UNCACHED_DEVICE_MERGE_TEST_RTL) \
		$(VSP_UNCACHED_DEVICE_MERGE_TB) $(BUILD_META) \
		$(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_UNCACHED_DEVICE_MERGE_TEST_TOP) \
		--Mdir $(VSP_UNCACHED_DEVICE_MERGE_OBJ) \
		$(VSP_UNCACHED_DEVICE_MERGE_TEST_RTL) \
		$(VSP_UNCACHED_DEVICE_MERGE_TB)
	$(MAKE) -C $(VSP_UNCACHED_DEVICE_MERGE_OBJ) \
		-f V$(VSP_UNCACHED_DEVICE_MERGE_TEST_TOP).mk

test-vsp-uncached-device-merge: check-memory-ip-lock \
		$(VSP_UNCACHED_DEVICE_MERGE_OBJ)/V$(VSP_UNCACHED_DEVICE_MERGE_TEST_TOP)
	$(VSP_UNCACHED_DEVICE_MERGE_OBJ)/V$(VSP_UNCACHED_DEVICE_MERGE_TEST_TOP)

$(VSP_UWORD_CACHED_PROGRAM_OBJ)/V$(VSP_UWORD_CACHED_PROGRAM_TEST_TOP): \
		$(VSP_UWORD_CACHED_PROGRAM_TEST_RTL) \
		$(VSP_UWORD_CACHED_PROGRAM_TB) $(BUILD_META) \
		$(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_UWORD_CACHED_PROGRAM_TEST_TOP) \
		--Mdir $(VSP_UWORD_CACHED_PROGRAM_OBJ) \
		$(VSP_UWORD_CACHED_PROGRAM_TEST_RTL) \
		$(VSP_UWORD_CACHED_PROGRAM_TB)
	$(MAKE) -C $(VSP_UWORD_CACHED_PROGRAM_OBJ) \
		-f V$(VSP_UWORD_CACHED_PROGRAM_TEST_TOP).mk

test-vsp-uword-cached-program: check-memory-ip-lock \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX) \
		$(VSP_UWORD_CACHED_PROGRAM_OBJ)/V$(VSP_UWORD_CACHED_PROGRAM_TEST_TOP)
	$(VSP_UWORD_CACHED_PROGRAM_OBJ)/V$(VSP_UWORD_CACHED_PROGRAM_TEST_TOP) \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX)

$(VSP_UWORD_MEMORY_SYSTEM_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP): \
		$(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) \
		$(VSP_UWORD_MEMORY_SYSTEM_TB) $(BUILD_META) \
		$(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP) \
		--Mdir $(VSP_UWORD_MEMORY_SYSTEM_OBJ) \
		$(VSP_UWORD_MEMORY_SYSTEM_TEST_RTL) \
		$(VSP_UWORD_MEMORY_SYSTEM_TB)
	$(MAKE) -C $(VSP_UWORD_MEMORY_SYSTEM_OBJ) \
		-f V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP).mk

$(VSP_IFETCH_REDIRECT_HEX): $(VSP_IFETCH_REDIRECT_ASM) tools/vsp_uword_asm.py | $(BUILD_DIR)
	$(PYTHON) tools/vsp_uword_asm.py $(VSP_IFETCH_REDIRECT_ASM) \
		--base-pc 0x00400ff0 --output $@

test-vsp-uword-memory-system: check-memory-ip-lock \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX) $(VSP_IFETCH_REDIRECT_HEX) \
		$(VSP_UWORD_MEMORY_SYSTEM_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP)
	$(VSP_UWORD_MEMORY_SYSTEM_OBJ)/V$(VSP_UWORD_MEMORY_SYSTEM_TEST_TOP) \
		$(VSP_UWORD_PHYSICAL_MEMORY_HEX) $(VSP_IFETCH_REDIRECT_HEX)

$(VSP_IFETCH_FAULT_OBJ)/V$(VSP_IFETCH_FAULT_TOP): \
		$(VSP_IFETCH_FAULT_RTL) $(VSP_IFETCH_FAULT_TB) \
		$(BUILD_META) $(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_IFETCH_FAULT_TOP) --Mdir $(VSP_IFETCH_FAULT_OBJ) \
		$(VSP_IFETCH_FAULT_RTL) $(VSP_IFETCH_FAULT_TB)
	$(MAKE) -C $(VSP_IFETCH_FAULT_OBJ) -f V$(VSP_IFETCH_FAULT_TOP).mk

test-vsp-ifetch-fault: check-memory-ip-lock \
		$(VSP_IFETCH_FAULT_OBJ)/V$(VSP_IFETCH_FAULT_TOP)
	$(VSP_IFETCH_FAULT_OBJ)/V$(VSP_IFETCH_FAULT_TOP)

$(VSP_DMEM_SUBSYSTEM_OBJ)/V$(VSP_DMEM_SUBSYSTEM_TOP): \
		$(VSP_DMEM_SUBSYSTEM_TEST_RTL) $(VSP_DMEM_SUBSYSTEM_TB) \
		$(BUILD_META) $(VSP_MEMORY_IP_LOCK) | check-memory-ip-lock $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --assert --cc --exe \
		--top-module $(VSP_DMEM_SUBSYSTEM_TOP) \
		--Mdir $(VSP_DMEM_SUBSYSTEM_OBJ) \
		$(VSP_DMEM_SUBSYSTEM_TEST_RTL) $(VSP_DMEM_SUBSYSTEM_TB)
	$(MAKE) -C $(VSP_DMEM_SUBSYSTEM_OBJ) \
		-f V$(VSP_DMEM_SUBSYSTEM_TOP).mk

test-memory-integration: check-memory-ip-lock \
		$(VSP_DMEM_SUBSYSTEM_OBJ)/V$(VSP_DMEM_SUBSYSTEM_TOP)
	$(VSP_DMEM_SUBSYSTEM_OBJ)/V$(VSP_DMEM_SUBSYSTEM_TOP)

$(VSP_MEMORY_UWORD_DECODER_OBJ)/V$(VSP_MEMORY_UWORD_DECODER_TOP): \
		$(VSP_MEMORY_UWORD_DECODER_RTL) $(VSP_MEMORY_UWORD_DECODER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_MEMORY_UWORD_DECODER_TOP) \
		-GMAX_SPAN_BYTES=4 --Mdir $(VSP_MEMORY_UWORD_DECODER_OBJ) \
		$(VSP_MEMORY_UWORD_DECODER_RTL) $(VSP_MEMORY_UWORD_DECODER_TB)
	$(MAKE) -C $(VSP_MEMORY_UWORD_DECODER_OBJ) \
		-f V$(VSP_MEMORY_UWORD_DECODER_TOP).mk

test-vsp-memory-uword-decoder: \
		$(VSP_MEMORY_UWORD_DECODER_OBJ)/V$(VSP_MEMORY_UWORD_DECODER_TOP)
	$(VSP_MEMORY_UWORD_DECODER_OBJ)/V$(VSP_MEMORY_UWORD_DECODER_TOP)

$(VSP_CONTROL_UWORD_DECODER_OBJ)/V$(VSP_CONTROL_UWORD_DECODER_TOP): \
		$(VSP_CONTROL_UWORD_DECODER_RTL) $(VSP_CONTROL_UWORD_DECODER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_CONTROL_UWORD_DECODER_TOP) -GSTATE_REGS=5 \
		--Mdir $(VSP_CONTROL_UWORD_DECODER_OBJ) \
		$(VSP_CONTROL_UWORD_DECODER_RTL) $(VSP_CONTROL_UWORD_DECODER_TB)
	$(MAKE) -C $(VSP_CONTROL_UWORD_DECODER_OBJ) \
		-f V$(VSP_CONTROL_UWORD_DECODER_TOP).mk

test-vsp-control-uword-decoder: \
		$(VSP_CONTROL_UWORD_DECODER_OBJ)/V$(VSP_CONTROL_UWORD_DECODER_TOP)
	$(VSP_CONTROL_UWORD_DECODER_OBJ)/V$(VSP_CONTROL_UWORD_DECODER_TOP)

$(VSP_UWORD_ACTION_ADAPTER_OBJ)/V$(VSP_UWORD_ACTION_ADAPTER_TOP): \
		$(VSP_UWORD_ACTION_ADAPTER_RTL) $(VSP_UWORD_ACTION_ADAPTER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_UWORD_ACTION_ADAPTER_TOP) \
		--Mdir $(VSP_UWORD_ACTION_ADAPTER_OBJ) \
		$(VSP_UWORD_ACTION_ADAPTER_RTL) $(VSP_UWORD_ACTION_ADAPTER_TB)
	$(MAKE) -C $(VSP_UWORD_ACTION_ADAPTER_OBJ) \
		-f V$(VSP_UWORD_ACTION_ADAPTER_TOP).mk

test-vsp-uword-action-adapter: \
		$(VSP_UWORD_ACTION_ADAPTER_OBJ)/V$(VSP_UWORD_ACTION_ADAPTER_TOP)
	$(VSP_UWORD_ACTION_ADAPTER_OBJ)/V$(VSP_UWORD_ACTION_ADAPTER_TOP)

$(VSP_ORDERED_ACTION_WINDOW_OBJ)/V$(VSP_ORDERED_ACTION_WINDOW_TOP): \
		$(VSP_ORDERED_ACTION_WINDOW_RTL) \
		$(VSP_ORDERED_ACTION_WINDOW_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_ORDERED_ACTION_WINDOW_TOP) \
		-GPC_W=16 -GSEQ_W=8 -GRAW_RECORD_W=16 -GDEP_W=4 \
		--Mdir $(VSP_ORDERED_ACTION_WINDOW_OBJ) \
		$(VSP_ORDERED_ACTION_WINDOW_RTL) \
		$(VSP_ORDERED_ACTION_WINDOW_TB)
	$(MAKE) -C $(VSP_ORDERED_ACTION_WINDOW_OBJ) \
		-f V$(VSP_ORDERED_ACTION_WINDOW_TOP).mk

test-vsp-ordered-action-window: \
		$(VSP_ORDERED_ACTION_WINDOW_OBJ)/V$(VSP_ORDERED_ACTION_WINDOW_TOP)
	$(VSP_ORDERED_ACTION_WINDOW_OBJ)/V$(VSP_ORDERED_ACTION_WINDOW_TOP)

$(VSP_ROUTE_RENDEZVOUS_OBJ)/V$(VSP_ROUTE_RENDEZVOUS_TOP): \
		$(VSP_ROUTE_RENDEZVOUS_RTL) \
		$(VSP_ROUTE_RENDEZVOUS_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_ROUTE_RENDEZVOUS_TOP) \
		-GENTRY_COUNT=3 -GCONTEXT_COUNT=3 -GPARTICIPANT_COUNT=3 \
		--Mdir $(VSP_ROUTE_RENDEZVOUS_OBJ) \
		$(VSP_ROUTE_RENDEZVOUS_RTL) \
		$(VSP_ROUTE_RENDEZVOUS_TB)
	$(MAKE) -C $(VSP_ROUTE_RENDEZVOUS_OBJ) \
		-f V$(VSP_ROUTE_RENDEZVOUS_TOP).mk

test-vsp-route-rendezvous-table: \
		$(VSP_ROUTE_RENDEZVOUS_OBJ)/V$(VSP_ROUTE_RENDEZVOUS_TOP)
	$(VSP_ROUTE_RENDEZVOUS_OBJ)/V$(VSP_ROUTE_RENDEZVOUS_TOP)

$(VSP_ROUTE_WAVE_CONTROLLER_OBJ)/V$(VSP_ROUTE_WAVE_CONTROLLER_TOP): \
		$(VSP_ROUTE_WAVE_CONTROLLER_RTL) \
		$(VSP_ROUTE_WAVE_CONTROLLER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_ROUTE_WAVE_CONTROLLER_TOP) -GENTRY_COUNT=3 \
		--Mdir $(VSP_ROUTE_WAVE_CONTROLLER_OBJ) \
		$(VSP_ROUTE_WAVE_CONTROLLER_RTL) \
		$(VSP_ROUTE_WAVE_CONTROLLER_TB)
	$(MAKE) -C $(VSP_ROUTE_WAVE_CONTROLLER_OBJ) \
		-f V$(VSP_ROUTE_WAVE_CONTROLLER_TOP).mk

test-vsp-route-wave-controller: \
		$(VSP_ROUTE_WAVE_CONTROLLER_OBJ)/V$(VSP_ROUTE_WAVE_CONTROLLER_TOP)
	$(VSP_ROUTE_WAVE_CONTROLLER_OBJ)/V$(VSP_ROUTE_WAVE_CONTROLLER_TOP)

$(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ)/V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP): \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_RTL) \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_ROUTE_WAVE_PIPELINE_TOP) -GENTRY_COUNT=3 \
		--Mdir $(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ) \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_RTL) \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_TB)
	$(MAKE) -C $(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ) \
		-f V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP).mk

test-cluster-route-wave-pipeline: \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ)/V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP)
	$(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ)/V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP)

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

$(CLUSTER_EXEC_OBJ)/V$(CLUSTER_EXEC_TOP): \
		$(CLUSTER_EXEC_RTL) $(CLUSTER_EXEC_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_EXEC_TOP) \
		--Mdir $(CLUSTER_EXEC_OBJ) $(CLUSTER_EXEC_RTL) \
		$(CLUSTER_EXEC_TB)
	$(MAKE) -C $(CLUSTER_EXEC_OBJ) \
		-f V$(CLUSTER_EXEC_TOP).mk

$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_TOP): \
		$(CLUSTER_EXEC_RTL) $(CLUSTER_EXEC_TRACKER_CREDIT_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_EXEC_TOP) -GTRACKER_ENTRIES=1 \
		--Mdir $(CLUSTER_EXEC_TRACKER_CREDIT_OBJ) \
		$(CLUSTER_EXEC_RTL) $(CLUSTER_EXEC_TRACKER_CREDIT_TB)
	$(MAKE) -C $(CLUSTER_EXEC_TRACKER_CREDIT_OBJ) \
		-f V$(CLUSTER_EXEC_TOP).mk

test-cluster-exec-tracker-credit: \
		$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_TOP)
	$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_TOP)

$(VECTOR_MEMORY_ENGINE_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP): \
		$(VECTOR_MEMORY_ENGINE_RTL) $(VECTOR_MEMORY_ENGINE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VECTOR_MEMORY_ENGINE_TOP) \
		--Mdir $(VECTOR_MEMORY_ENGINE_OBJ) \
		$(VECTOR_MEMORY_ENGINE_RTL) $(VECTOR_MEMORY_ENGINE_TB)
	$(MAKE) -C $(VECTOR_MEMORY_ENGINE_OBJ) \
		-f V$(VECTOR_MEMORY_ENGINE_TOP).mk

$(VECTOR_MEMORY_ENGINE_16GROUP_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP): \
		$(VECTOR_MEMORY_ENGINE_RTL) $(VECTOR_MEMORY_ENGINE_16GROUP_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VECTOR_MEMORY_ENGINE_TOP) \
		-GGROUP_COUNT=16 -GVRF_ROW_BYTES=4 -GEXEC_CONTEXT_COUNT=1 \
		--Mdir $(VECTOR_MEMORY_ENGINE_16GROUP_OBJ) \
		$(VECTOR_MEMORY_ENGINE_RTL) $(VECTOR_MEMORY_ENGINE_16GROUP_TB)
	$(MAKE) -C $(VECTOR_MEMORY_ENGINE_16GROUP_OBJ) \
		-f V$(VECTOR_MEMORY_ENGINE_TOP).mk

test-vsp-vector-memory-engine-16group: \
		$(VECTOR_MEMORY_ENGINE_16GROUP_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP)
	$(VECTOR_MEMORY_ENGINE_16GROUP_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP)

$(VSP_ORDERED_DMEM_MODEL_OBJ)/V$(VSP_ORDERED_DMEM_MODEL_TOP): \
		$(VSP_ORDERED_DMEM_MODEL_RTL) $(VSP_ORDERED_DMEM_MODEL_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_ORDERED_DMEM_MODEL_TOP) \
		--Mdir $(VSP_ORDERED_DMEM_MODEL_OBJ) \
		$(VSP_ORDERED_DMEM_MODEL_RTL) $(VSP_ORDERED_DMEM_MODEL_TB)
	$(MAKE) -C $(VSP_ORDERED_DMEM_MODEL_OBJ) \
		-f V$(VSP_ORDERED_DMEM_MODEL_TOP).mk

test-vsp-ordered-dmem-model: \
		$(VSP_ORDERED_DMEM_MODEL_OBJ)/V$(VSP_ORDERED_DMEM_MODEL_TOP)
	$(VSP_ORDERED_DMEM_MODEL_OBJ)/V$(VSP_ORDERED_DMEM_MODEL_TOP)

$(VSP_ORDERED_IFETCH_MODEL_OBJ)/V$(VSP_ORDERED_IFETCH_MODEL_TOP): \
		$(VSP_ORDERED_IFETCH_MODEL_RTL) $(VSP_ORDERED_IFETCH_MODEL_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_ORDERED_IFETCH_MODEL_TOP) \
		-GMEM_WORDS=16 -GBASE_PC=32 -GOUTSTANDING_DEPTH=3 \
		--Mdir $(VSP_ORDERED_IFETCH_MODEL_OBJ) \
		$(VSP_ORDERED_IFETCH_MODEL_RTL) $(VSP_ORDERED_IFETCH_MODEL_TB)
	$(MAKE) -C $(VSP_ORDERED_IFETCH_MODEL_OBJ) \
		-f V$(VSP_ORDERED_IFETCH_MODEL_TOP).mk

test-vsp-ordered-ifetch-model: \
		$(VSP_ORDERED_IFETCH_MODEL_OBJ)/V$(VSP_ORDERED_IFETCH_MODEL_TOP)
	$(VSP_ORDERED_IFETCH_MODEL_OBJ)/V$(VSP_ORDERED_IFETCH_MODEL_TOP)

$(VSP_SEQUENCER_STATE_ENGINE_OBJ)/V$(VSP_SEQUENCER_STATE_ENGINE_TOP): \
		$(VSP_SEQUENCER_STATE_ENGINE_RTL) \
		$(VSP_SEQUENCER_STATE_ENGINE_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_SEQUENCER_STATE_ENGINE_TOP) \
		-GSTATE_REGS=5 -GCONTEXT_COUNT=3 \
		--Mdir $(VSP_SEQUENCER_STATE_ENGINE_OBJ) \
		$(VSP_SEQUENCER_STATE_ENGINE_RTL) \
		$(VSP_SEQUENCER_STATE_ENGINE_TB)
	$(MAKE) -C $(VSP_SEQUENCER_STATE_ENGINE_OBJ) \
		-f V$(VSP_SEQUENCER_STATE_ENGINE_TOP).mk

test-vsp-sequencer-state-engine: \
		$(VSP_SEQUENCER_STATE_ENGINE_OBJ)/V$(VSP_SEQUENCER_STATE_ENGINE_TOP)
	$(VSP_SEQUENCER_STATE_ENGINE_OBJ)/V$(VSP_SEQUENCER_STATE_ENGINE_TOP)

$(CLUSTER_VRF_ARBITER_OBJ)/V$(CLUSTER_VRF_ARBITER_TOP): \
		$(CLUSTER_VRF_ARBITER_RTL) $(CLUSTER_VRF_ARBITER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_VRF_ARBITER_TOP) \
		--Mdir $(CLUSTER_VRF_ARBITER_OBJ) \
		$(CLUSTER_VRF_ARBITER_RTL) $(CLUSTER_VRF_ARBITER_TB)
	$(MAKE) -C $(CLUSTER_VRF_ARBITER_OBJ) \
		-f V$(CLUSTER_VRF_ARBITER_TOP).mk

test-cluster-vrf-arbiter: \
		$(CLUSTER_VRF_ARBITER_OBJ)/V$(CLUSTER_VRF_ARBITER_TOP)
	$(CLUSTER_VRF_ARBITER_OBJ)/V$(CLUSTER_VRF_ARBITER_TOP)

$(CLUSTER_MEMORY_WRAPPER_OBJ)/V$(CLUSTER_MEMORY_WRAPPER_TOP): \
		$(CLUSTER_MEMORY_WRAPPER_RTL) $(CLUSTER_MEMORY_WRAPPER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_MEMORY_WRAPPER_TOP) \
		--Mdir $(CLUSTER_MEMORY_WRAPPER_OBJ) \
		$(CLUSTER_MEMORY_WRAPPER_RTL) $(CLUSTER_MEMORY_WRAPPER_TB)
	$(MAKE) -C $(CLUSTER_MEMORY_WRAPPER_OBJ) \
		-f V$(CLUSTER_MEMORY_WRAPPER_TOP).mk

test-cluster-memory-wrapper: \
		$(CLUSTER_MEMORY_WRAPPER_OBJ)/V$(CLUSTER_MEMORY_WRAPPER_TOP)
	$(CLUSTER_MEMORY_WRAPPER_OBJ)/V$(CLUSTER_MEMORY_WRAPPER_TOP)

$(CLUSTER_REGISTER_ROUTE_OBJ)/V$(CLUSTER_REGISTER_ROUTE_TOP): \
		$(CLUSTER_REGISTER_ROUTE_RTL) $(CLUSTER_REGISTER_ROUTE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_REGISTER_ROUTE_TOP) \
		--Mdir $(CLUSTER_REGISTER_ROUTE_OBJ) \
		$(CLUSTER_REGISTER_ROUTE_RTL) $(CLUSTER_REGISTER_ROUTE_TB)
	$(MAKE) -C $(CLUSTER_REGISTER_ROUTE_OBJ) \
		-f V$(CLUSTER_REGISTER_ROUTE_TOP).mk

test-cluster-register-route: \
		$(CLUSTER_REGISTER_ROUTE_OBJ)/V$(CLUSTER_REGISTER_ROUTE_TOP)
	$(CLUSTER_REGISTER_ROUTE_OBJ)/V$(CLUSTER_REGISTER_ROUTE_TOP)

$(VSP_DECODED_ACTION_CONTROLLER_OBJ)/V$(VSP_DECODED_ACTION_CONTROLLER_TOP): \
		$(VSP_DECODED_ACTION_CONTROLLER_RTL) \
		$(VSP_DECODED_ACTION_CONTROLLER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(VSP_DECODED_ACTION_CONTROLLER_TOP) \
		--Mdir $(VSP_DECODED_ACTION_CONTROLLER_OBJ) \
		$(VSP_DECODED_ACTION_CONTROLLER_RTL) \
		$(VSP_DECODED_ACTION_CONTROLLER_TB)
	$(MAKE) -C $(VSP_DECODED_ACTION_CONTROLLER_OBJ) \
		-f V$(VSP_DECODED_ACTION_CONTROLLER_TOP).mk

test-vsp-decoded-action-controller: \
		$(VSP_DECODED_ACTION_CONTROLLER_OBJ)/V$(VSP_DECODED_ACTION_CONTROLLER_TOP)
	$(VSP_DECODED_ACTION_CONTROLLER_OBJ)/V$(VSP_DECODED_ACTION_CONTROLLER_TOP)

$(CLUSTER_CONTROLLER_WRAPPER_OBJ)/V$(CLUSTER_CONTROLLER_WRAPPER_TOP): \
		$(CLUSTER_CONTROLLER_WRAPPER_RTL) \
		$(CLUSTER_CONTROLLER_WRAPPER_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(CLUSTER_CONTROLLER_WRAPPER_TOP) \
		--Mdir $(CLUSTER_CONTROLLER_WRAPPER_OBJ) \
		$(CLUSTER_CONTROLLER_WRAPPER_RTL) \
		$(CLUSTER_CONTROLLER_WRAPPER_TB)
	$(MAKE) -C $(CLUSTER_CONTROLLER_WRAPPER_OBJ) \
		-f V$(CLUSTER_CONTROLLER_WRAPPER_TOP).mk

test-cluster-controller-wrapper: \
		$(CLUSTER_CONTROLLER_WRAPPER_OBJ)/V$(CLUSTER_CONTROLLER_WRAPPER_TOP)
	$(CLUSTER_CONTROLLER_WRAPPER_OBJ)/V$(CLUSTER_CONTROLLER_WRAPPER_TOP)

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

$(LANE_GATHER_OBJ)/V$(LANE_GATHER_TOP): $(LANE_GATHER_RTL) $(LANE_GATHER_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(LANE_GATHER_TOP) --Mdir $(LANE_GATHER_OBJ) \
		$(LANE_GATHER_RTL) $(LANE_GATHER_TB)
	$(MAKE) -C $(LANE_GATHER_OBJ) -f V$(LANE_GATHER_TOP).mk

$(WORD_FIRST_GATHER_PHASE_OBJ)/V$(WORD_FIRST_GATHER_PHASE_TOP): \
		$(WORD_FIRST_GATHER_PHASE_RTL) $(WORD_FIRST_GATHER_PHASE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(WORD_FIRST_GATHER_PHASE_TOP) \
		--Mdir $(WORD_FIRST_GATHER_PHASE_OBJ) \
		$(WORD_FIRST_GATHER_PHASE_RTL) $(WORD_FIRST_GATHER_PHASE_TB)
	$(MAKE) -C $(WORD_FIRST_GATHER_PHASE_OBJ) \
		-f V$(WORD_FIRST_GATHER_PHASE_TOP).mk

test-vsp-word-first-gather-phase: \
		$(WORD_FIRST_GATHER_PHASE_OBJ)/V$(WORD_FIRST_GATHER_PHASE_TOP)
	$(WORD_FIRST_GATHER_PHASE_OBJ)/V$(WORD_FIRST_GATHER_PHASE_TOP)

$(FOUR_PASS_GATHER_ENGINE_OBJ)/V$(FOUR_PASS_GATHER_ENGINE_TOP): \
		$(FOUR_PASS_GATHER_ENGINE_RTL) $(FOUR_PASS_GATHER_ENGINE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe \
		--top-module $(FOUR_PASS_GATHER_ENGINE_TOP) \
		--Mdir $(FOUR_PASS_GATHER_ENGINE_OBJ) \
		$(FOUR_PASS_GATHER_ENGINE_RTL) $(FOUR_PASS_GATHER_ENGINE_TB)
	$(MAKE) -C $(FOUR_PASS_GATHER_ENGINE_OBJ) \
		-f V$(FOUR_PASS_GATHER_ENGINE_TOP).mk

test-vsp-four-pass-gather-engine: \
		$(FOUR_PASS_GATHER_ENGINE_OBJ)/V$(FOUR_PASS_GATHER_ENGINE_TOP)
	$(FOUR_PASS_GATHER_ENGINE_OBJ)/V$(FOUR_PASS_GATHER_ENGINE_TOP)

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

$(SOBEL_OBJ)/V$(SOBEL_TOP): $(DATAPATH_RTL) $(SOBEL_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(SOBEL_TOP) \
		--Mdir $(SOBEL_OBJ) $(DATAPATH_RTL) $(SOBEL_TB)
	$(MAKE) -C $(SOBEL_OBJ) -f V$(SOBEL_TOP).mk

$(SEPARABLE_OBJ)/V$(SEPARABLE_TOP): $(DATAPATH_RTL) $(SEPARABLE_TB) \
		$(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(SEPARABLE_TOP) \
		--Mdir $(SEPARABLE_OBJ) $(DATAPATH_RTL) $(SEPARABLE_TB)
	$(MAKE) -C $(SEPARABLE_OBJ) -f V$(SEPARABLE_TOP).mk

$(MEDIAN_OBJ)/V$(MEDIAN_TOP): $(DATAPATH_RTL) $(MEDIAN_TB) $(BUILD_META) | $(BUILD_DIR)
	$(VERILATOR) -Wall -Wno-fatal --cc --exe --top-module $(MEDIAN_TOP) \
		--Mdir $(MEDIAN_OBJ) $(DATAPATH_RTL) $(MEDIAN_TB)
	$(MAKE) -C $(MEDIAN_OBJ) -f V$(MEDIAN_TOP).mk

$(MUL32_MICRO_BIN): $(MUL32_MICRO_TB) $(BUILD_META) | $(BUILD_DIR)
	$(CXX) -std=c++17 -O2 -Wall -Wextra -pedantic $< -o $@

test-experimental-routing: $(BENES_OBJ)/V$(BENES_TOP) \
		$(VSP_ROUTE_RENDEZVOUS_OBJ)/V$(VSP_ROUTE_RENDEZVOUS_TOP) \
		$(VSP_ROUTE_WAVE_CONTROLLER_OBJ)/V$(VSP_ROUTE_WAVE_CONTROLLER_TOP) \
		$(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ)/V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP) \
		$(CLUSTER_REGISTER_ROUTE_OBJ)/V$(CLUSTER_REGISTER_ROUTE_TOP) \
		$(LANE_GATHER_OBJ)/V$(LANE_GATHER_TOP) \
		$(WORD_FIRST_GATHER_PHASE_OBJ)/V$(WORD_FIRST_GATHER_PHASE_TOP) \
		$(FOUR_PASS_GATHER_ENGINE_OBJ)/V$(FOUR_PASS_GATHER_ENGINE_TOP)
	$(BENES_OBJ)/V$(BENES_TOP)
	$(VSP_ROUTE_RENDEZVOUS_OBJ)/V$(VSP_ROUTE_RENDEZVOUS_TOP)
	$(VSP_ROUTE_WAVE_CONTROLLER_OBJ)/V$(VSP_ROUTE_WAVE_CONTROLLER_TOP)
	$(CLUSTER_ROUTE_WAVE_PIPELINE_OBJ)/V$(CLUSTER_ROUTE_WAVE_PIPELINE_TOP)
	$(CLUSTER_REGISTER_ROUTE_OBJ)/V$(CLUSTER_REGISTER_ROUTE_TOP)
	$(LANE_GATHER_OBJ)/V$(LANE_GATHER_TOP)
	$(WORD_FIRST_GATHER_PHASE_OBJ)/V$(WORD_FIRST_GATHER_PHASE_TOP)
	$(FOUR_PASS_GATHER_ENGINE_OBJ)/V$(FOUR_PASS_GATHER_ENGINE_TOP)

test: $(OBJ_DIR)/V$(TOP) \
		$(ISSUE_DISPATCH_OBJ)/V$(ISSUE_DISPATCH_TOP) \
		$(ISSUE_DISPATCH_WIDE_OBJ)/V$(ISSUE_DISPATCH_TOP) \
		$(ISSUE_QUEUE_OBJ)/V$(ISSUE_QUEUE_TOP) \
		$(ISSUE_QUEUE_DEPTH1_OBJ)/V$(ISSUE_QUEUE_TOP) \
		$(CLUSTER_ISSUE_FRONTEND_OBJ)/V$(CLUSTER_ISSUE_FRONTEND_TOP) \
		$(GROUP_COMPLETION_TRACKER_OBJ)/V$(GROUP_COMPLETION_TRACKER_TOP) \
		$(ISSUE_DECODE_STAGE_OBJ)/V$(ISSUE_DECODE_STAGE_TOP) \
		$(VSP_EXEC_UWORD_EXPANDER_OBJ)/V$(VSP_EXEC_UWORD_EXPANDER_TOP) \
		$(VSP_UWORD_PREDECODER_OBJ)/V$(VSP_UWORD_PREDECODER_TOP) \
		$(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ)/V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP) \
		$(VSP_UWORD_MULTI_FRAMER_OBJ)/V$(VSP_UWORD_MULTI_FRAMER_TOP) \
		$(VSP_UWORD_PROGRAM_SOURCE_OBJ)/V$(VSP_UWORD_PROGRAM_SOURCE_TOP) \
		$(VSP_UWORD_PC_HEX) \
		$(VSP_UWORD_PROGRAM_FRONTEND_OBJ)/V$(VSP_UWORD_PROGRAM_FRONTEND_TOP) \
		$(VSP_UWORD_EXEC_END_HEX) \
		$(VSP_UWORD_MEMORY_STATE_HEX) \
		$(VSP_UWORD_BRANCH_LOOP_HEX) \
		$(VSP_UWORD_VECTOR_MEMORY_LOOP_HEX) \
		$(VSP_UWORD_CLUSTER_PROGRAM_OBJ)/V$(VSP_UWORD_CLUSTER_PROGRAM_TOP) \
		$(VSP_MEMORY_UWORD_DECODER_OBJ)/V$(VSP_MEMORY_UWORD_DECODER_TOP) \
		$(VSP_CONTROL_UWORD_DECODER_OBJ)/V$(VSP_CONTROL_UWORD_DECODER_TOP) \
		$(VSP_UWORD_ACTION_ADAPTER_OBJ)/V$(VSP_UWORD_ACTION_ADAPTER_TOP) \
		$(VSP_ORDERED_ACTION_WINDOW_OBJ)/V$(VSP_ORDERED_ACTION_WINDOW_TOP) \
		$(CLUSTER_RESULT_COLLECTOR_OBJ)/V$(CLUSTER_RESULT_COLLECTOR_TOP) \
		$(CLUSTER_EXEC_OBJ)/V$(CLUSTER_EXEC_TOP) \
		$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_TOP) \
		$(VECTOR_MEMORY_ENGINE_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP) \
		$(VECTOR_MEMORY_ENGINE_16GROUP_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP) \
		$(VSP_ORDERED_DMEM_MODEL_OBJ)/V$(VSP_ORDERED_DMEM_MODEL_TOP) \
		$(VSP_ORDERED_IFETCH_MODEL_OBJ)/V$(VSP_ORDERED_IFETCH_MODEL_TOP) \
		$(VSP_SEQUENCER_STATE_ENGINE_OBJ)/V$(VSP_SEQUENCER_STATE_ENGINE_TOP) \
		$(CLUSTER_VRF_ARBITER_OBJ)/V$(CLUSTER_VRF_ARBITER_TOP) \
		$(CLUSTER_MEMORY_WRAPPER_OBJ)/V$(CLUSTER_MEMORY_WRAPPER_TOP) \
		$(VSP_DECODED_ACTION_CONTROLLER_OBJ)/V$(VSP_DECODED_ACTION_CONTROLLER_TOP) \
		$(CLUSTER_CONTROLLER_WRAPPER_OBJ)/V$(CLUSTER_CONTROLLER_WRAPPER_TOP) \
		$(UOP_LEGAL_OBJ)/V$(UOP_LEGAL_TOP) \
		$(ROUTE_OBJ)/V$(ROUTE_TOP) \
		$(COMPACT_OBJ)/V$(COMPACT_TOP) \
		$(MASK_OBJ)/V$(MASK_TOP) \
		$(DYNAMIC_OBJ)/V$(DYNAMIC_TOP) \
		$(REDUCE_OBJ)/V$(REDUCE_TOP) $(SAD_OBJ)/V$(SAD_TOP) \
		$(DATAPATH_OBJ)/V$(DATAPATH_TOP) \
		$(GROUP_WRAPPER_OBJ)/V$(GROUP_WRAPPER_TOP) \
		$(GAUSSIAN_OBJ)/V$(GAUSSIAN_TOP) \
		$(SOBEL_OBJ)/V$(SOBEL_TOP) \
		$(SEPARABLE_OBJ)/V$(SEPARABLE_TOP) \
		$(MEDIAN_OBJ)/V$(MEDIAN_TOP) $(MUL32_MICRO_BIN)
	$(OBJ_DIR)/V$(TOP)
	$(ISSUE_DISPATCH_OBJ)/V$(ISSUE_DISPATCH_TOP)
	$(ISSUE_DISPATCH_WIDE_OBJ)/V$(ISSUE_DISPATCH_TOP)
	$(ISSUE_QUEUE_OBJ)/V$(ISSUE_QUEUE_TOP)
	$(ISSUE_QUEUE_DEPTH1_OBJ)/V$(ISSUE_QUEUE_TOP)
	$(CLUSTER_ISSUE_FRONTEND_OBJ)/V$(CLUSTER_ISSUE_FRONTEND_TOP)
	$(GROUP_COMPLETION_TRACKER_OBJ)/V$(GROUP_COMPLETION_TRACKER_TOP)
	$(ISSUE_DECODE_STAGE_OBJ)/V$(ISSUE_DECODE_STAGE_TOP)
	$(VSP_EXEC_UWORD_EXPANDER_OBJ)/V$(VSP_EXEC_UWORD_EXPANDER_TOP)
	$(VSP_UWORD_PREDECODER_OBJ)/V$(VSP_UWORD_PREDECODER_TOP)
	$(VSP_UWORD_BUNDLE_ASSEMBLER_OBJ)/V$(VSP_UWORD_BUNDLE_ASSEMBLER_TOP)
	$(VSP_UWORD_MULTI_FRAMER_OBJ)/V$(VSP_UWORD_MULTI_FRAMER_TOP)
	$(VSP_UWORD_PROGRAM_SOURCE_OBJ)/V$(VSP_UWORD_PROGRAM_SOURCE_TOP)
	$(PYTHON) $(VSP_UWORD_ASM_TB)
	$(PYTHON) $(VSP_BFP_TB)
	$(PYTHON) $(VSP_M8E8_TB)
	$(VSP_UWORD_PROGRAM_FRONTEND_OBJ)/V$(VSP_UWORD_PROGRAM_FRONTEND_TOP) \
		$(VSP_UWORD_PC_HEX)
	$(VSP_UWORD_CLUSTER_PROGRAM_OBJ)/V$(VSP_UWORD_CLUSTER_PROGRAM_TOP) \
		$(VSP_UWORD_EXEC_END_HEX) $(VSP_UWORD_MEMORY_STATE_HEX) \
		$(VSP_UWORD_BRANCH_LOOP_HEX) $(VSP_UWORD_VECTOR_MEMORY_LOOP_HEX)
	$(VSP_MEMORY_UWORD_DECODER_OBJ)/V$(VSP_MEMORY_UWORD_DECODER_TOP)
	$(VSP_CONTROL_UWORD_DECODER_OBJ)/V$(VSP_CONTROL_UWORD_DECODER_TOP)
	$(VSP_UWORD_ACTION_ADAPTER_OBJ)/V$(VSP_UWORD_ACTION_ADAPTER_TOP)
	$(VSP_ORDERED_ACTION_WINDOW_OBJ)/V$(VSP_ORDERED_ACTION_WINDOW_TOP)
	$(CLUSTER_RESULT_COLLECTOR_OBJ)/V$(CLUSTER_RESULT_COLLECTOR_TOP)
	$(CLUSTER_EXEC_OBJ)/V$(CLUSTER_EXEC_TOP)
	$(CLUSTER_EXEC_TRACKER_CREDIT_OBJ)/V$(CLUSTER_EXEC_TOP)
	$(VECTOR_MEMORY_ENGINE_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP)
	$(VECTOR_MEMORY_ENGINE_16GROUP_OBJ)/V$(VECTOR_MEMORY_ENGINE_TOP)
	$(VSP_ORDERED_DMEM_MODEL_OBJ)/V$(VSP_ORDERED_DMEM_MODEL_TOP)
	$(VSP_ORDERED_IFETCH_MODEL_OBJ)/V$(VSP_ORDERED_IFETCH_MODEL_TOP)
	$(VSP_SEQUENCER_STATE_ENGINE_OBJ)/V$(VSP_SEQUENCER_STATE_ENGINE_TOP)
	$(CLUSTER_VRF_ARBITER_OBJ)/V$(CLUSTER_VRF_ARBITER_TOP)
	$(CLUSTER_MEMORY_WRAPPER_OBJ)/V$(CLUSTER_MEMORY_WRAPPER_TOP)
	$(VSP_DECODED_ACTION_CONTROLLER_OBJ)/V$(VSP_DECODED_ACTION_CONTROLLER_TOP)
	$(CLUSTER_CONTROLLER_WRAPPER_OBJ)/V$(CLUSTER_CONTROLLER_WRAPPER_TOP)
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
	$(SOBEL_OBJ)/V$(SOBEL_TOP)
	$(SEPARABLE_OBJ)/V$(SEPARABLE_TOP)
	$(MEDIAN_OBJ)/V$(MEDIAN_TOP)
	$(MUL32_MICRO_BIN)

clean:
	@build_dir="$(abspath $(BUILD_DIR))"; \
	case "$$build_dir" in \
		""|"/"|"$(abspath .)"|"$(abspath ..)") \
			echo "Refusing to remove unsafe BUILD_DIR=$$build_dir" >&2; exit 1 ;; \
		*) rm -rf -- "$$build_dir" ;; \
	esac
