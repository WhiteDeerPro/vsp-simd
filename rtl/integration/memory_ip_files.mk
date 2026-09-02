# SPDX-License-Identifier: MIT

# VSP-owned source closure for the external memory-system IP baseline.
#
# The sibling repositories intentionally remain the owners of their RTL.  This
# manifest names only synthesizable package/core files, in compile order; it
# does not recursively include sibling filelists because some of those also
# contain protocol checkers and simulation models.
VSP_WORKSPACE_ROOT ?= $(abspath ..)

VSP_MEMORY_COMMON_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_MEMORY_COMMON
VSP_ADDRESS_REGION_ROUTER_DIR ?= \
	$(VSP_WORKSPACE_ROOT)/VSP_ADDRESS_REGION_ROUTER
VSP_TLB_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_TLB
VSP_PTW_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_PTW
VSP_MMU_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_MMU
VSP_LSU_BACKEND_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_LSU_BACKEND
VSP_CACHE_ADAPTERS_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_CACHE_ADAPTERS
VSP_MEMORY_ENDPOINTS_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_MEMORY_ENDPOINTS
VSP_PHYSICAL_FABRIC_DIR ?= $(VSP_WORKSPACE_ROOT)/VSP_PHYSICAL_FABRIC
CACHE_MODULE_DIR ?= $(VSP_WORKSPACE_ROOT)/CACHE_MODULE

VSP_MEM_COMMON_PKG_RTL := \
	$(VSP_MEMORY_COMMON_DIR)/rtl/pkg/vsp_mem_common_pkg.sv
VSP_ADDR_ROUTER_PKG_RTL := \
	$(VSP_ADDRESS_REGION_ROUTER_DIR)/rtl/pkg/vsp_address_region_router_pkg.sv
VSP_TLB_PKG_RTL := $(VSP_TLB_DIR)/rtl/pkg/vsp_tlb_pkg.sv
VSP_PTW_PKG_RTL := $(VSP_PTW_DIR)/rtl/pkg/vsp_ptw_pkg.sv
VSP_MMU_PKG_RTL := $(VSP_MMU_DIR)/rtl/pkg/vsp_mmu_pkg.sv
VSP_LSU_BACKEND_PKG_RTL := \
	$(VSP_LSU_BACKEND_DIR)/rtl/pkg/vsp_lsu_backend_pkg.sv
CACHE_PKG_RTL := $(CACHE_MODULE_DIR)/rtl/pkg/cache_pkg.sv
VSP_CACHE_ADAPTERS_PKG_RTL := \
	$(VSP_CACHE_ADAPTERS_DIR)/rtl/pkg/vsp_cache_adapters_pkg.sv
VSP_MEMORY_ENDPOINTS_PKG_RTL := \
	$(VSP_MEMORY_ENDPOINTS_DIR)/rtl/pkg/vsp_memory_endpoints_pkg.sv
VSP_PHYSICAL_FABRIC_PKG_RTL := \
	$(VSP_PHYSICAL_FABRIC_DIR)/rtl/pkg/vsp_physical_fabric_pkg.sv

VSP_ADDR_SPACE_ROUTER_RTL := \
	$(VSP_ADDRESS_REGION_ROUTER_DIR)/rtl/core/vsp_address_space_router.sv
VSP_ADDR_REGION_ROUTER_RTL := \
	$(VSP_ADDRESS_REGION_ROUTER_DIR)/rtl/core/vsp_address_region_router.sv
VSP_TLB_CORE_RTL := $(VSP_TLB_DIR)/rtl/core/vsp_tlb.sv
VSP_PTW_CORE_RTL := $(VSP_PTW_DIR)/rtl/core/vsp_ptw.sv
VSP_MMU_FRONTEND_RTL := $(VSP_MMU_DIR)/rtl/core/vsp_mmu_frontend.sv
VSP_MMU_CORE_RTL := $(VSP_MMU_DIR)/rtl/core/vsp_mmu.sv
VSP_LSU_BACKEND_CORE_RTL := \
	$(VSP_LSU_BACKEND_DIR)/rtl/core/vsp_lsu_backend.sv

CACHE_TAG_META_SRAM_RTL := \
	$(CACHE_MODULE_DIR)/rtl/sram/cache_tag_meta_sram.sv
CACHE_DATA_SRAM_RTL := \
	$(CACHE_MODULE_DIR)/rtl/sram/cache_data_sram.sv
CACHE_CORE_MODULE_RTL := $(CACHE_MODULE_DIR)/rtl/core/param_cache.sv
VSP_CACHE_ADAPTER_CORE_RTL := \
	$(VSP_CACHE_ADAPTERS_DIR)/rtl/core/vsp_cache_adapter_core.sv
VSP_DCACHE_ADAPTER_MODULE_RTL := \
	$(VSP_CACHE_ADAPTERS_DIR)/rtl/adapters/vsp_dcache_adapter.sv
VSP_LOCAL_SRAM_RTL := \
	$(VSP_MEMORY_ENDPOINTS_DIR)/rtl/sram/vsp_local_sram.sv
VSP_LOCAL_SRAM_ADAPTER_RTL := \
	$(VSP_MEMORY_ENDPOINTS_DIR)/rtl/core/vsp_local_sram_adapter.sv
VSP_UNCACHED_DEVICE_ADAPTER_RTL := \
	$(VSP_MEMORY_ENDPOINTS_DIR)/rtl/adapters/vsp_uncached_device_adapter.sv
VSP_PHYSICAL_FABRIC_CORE_RTL := \
	$(VSP_PHYSICAL_FABRIC_DIR)/rtl/core/vsp_physical_fabric.sv
VSP_FABRIC_ORDERED_SRAM_RTL := \
	$(VSP_PHYSICAL_FABRIC_DIR)/rtl/sram/vsp_fabric_ordered_sram.sv

VSP_EXTERNAL_DMEM_IP_RTL := \
	$(VSP_MEM_COMMON_PKG_RTL) \
	$(VSP_ADDR_ROUTER_PKG_RTL) \
	$(VSP_TLB_PKG_RTL) \
	$(VSP_PTW_PKG_RTL) \
	$(VSP_MMU_PKG_RTL) \
	$(VSP_LSU_BACKEND_PKG_RTL) \
	$(CACHE_PKG_RTL) \
	$(VSP_CACHE_ADAPTERS_PKG_RTL) \
	$(VSP_MEMORY_ENDPOINTS_PKG_RTL) \
	$(VSP_PHYSICAL_FABRIC_PKG_RTL) \
	$(VSP_ADDR_SPACE_ROUTER_RTL) \
	$(VSP_ADDR_REGION_ROUTER_RTL) \
	$(VSP_TLB_CORE_RTL) \
	$(VSP_PTW_CORE_RTL) \
	$(VSP_MMU_FRONTEND_RTL) \
	$(VSP_MMU_CORE_RTL) \
	$(VSP_LSU_BACKEND_CORE_RTL) \
	$(CACHE_TAG_META_SRAM_RTL) \
	$(CACHE_DATA_SRAM_RTL) \
	$(CACHE_CORE_MODULE_RTL) \
	$(VSP_CACHE_ADAPTER_CORE_RTL) \
	$(VSP_DCACHE_ADAPTER_MODULE_RTL) \
	$(VSP_LOCAL_SRAM_RTL) \
	$(VSP_LOCAL_SRAM_ADAPTER_RTL) \
	$(VSP_UNCACHED_DEVICE_ADAPTER_RTL) \
	$(VSP_PHYSICAL_FABRIC_CORE_RTL) \
	$(VSP_FABRIC_ORDERED_SRAM_RTL)

RTL_VSP_DMEM_SUBSYSTEM_WRAPPER := \
	rtl/integration/vsp_dmem_subsystem_wrapper.sv
RTL_VSP_UNCACHED_DEVICE_MERGE := \
	rtl/integration/vsp_uncached_device_merge.sv
RTL_VSP_DMEM_CACHED_FABRIC_WRAPPER := \
	rtl/integration/vsp_dmem_cached_fabric_wrapper.sv
RTL_VSP_UWORD_CACHED_PROGRAM_WRAPPER := \
	rtl/integration/vsp_uword_cached_program_wrapper.sv

VSP_DMEM_SUBSYSTEM_WRAPPER_RTL := \
	$(RTL_VSP_PKG) \
	$(VSP_EXTERNAL_DMEM_IP_RTL) \
	$(RTL_VSP_DMEM_SUBSYSTEM_WRAPPER)

VSP_DMEM_CACHED_FABRIC_WRAPPER_RTL := \
	$(RTL_VSP_PKG) \
	$(VSP_EXTERNAL_DMEM_IP_RTL) \
	$(RTL_VSP_DMEM_SUBSYSTEM_WRAPPER) \
	$(RTL_VSP_UNCACHED_DEVICE_MERGE) \
	$(RTL_VSP_DMEM_CACHED_FABRIC_WRAPPER)

VSP_UWORD_CACHED_PROGRAM_WRAPPER_RTL := \
	$(VSP_UWORD_CLUSTER_PROGRAM_WRAPPER_RTL) \
	$(VSP_EXTERNAL_DMEM_IP_RTL) \
	$(RTL_VSP_DMEM_SUBSYSTEM_WRAPPER) \
	$(RTL_VSP_UNCACHED_DEVICE_MERGE) \
	$(RTL_VSP_DMEM_CACHED_FABRIC_WRAPPER) \
	$(RTL_VSP_UWORD_CACHED_PROGRAM_WRAPPER)

VSP_EXTERNAL_DMEM_IP_REQUIRED := $(VSP_EXTERNAL_DMEM_IP_RTL)
VSP_MEMORY_IP_LOCK := rtl/integration/memory_ip.lock
