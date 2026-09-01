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

VSP_MEM_COMMON_PKG_RTL := \
	$(VSP_MEMORY_COMMON_DIR)/rtl/pkg/vsp_mem_common_pkg.sv
VSP_ADDR_ROUTER_PKG_RTL := \
	$(VSP_ADDRESS_REGION_ROUTER_DIR)/rtl/pkg/vsp_address_region_router_pkg.sv
VSP_TLB_PKG_RTL := $(VSP_TLB_DIR)/rtl/pkg/vsp_tlb_pkg.sv
VSP_PTW_PKG_RTL := $(VSP_PTW_DIR)/rtl/pkg/vsp_ptw_pkg.sv
VSP_MMU_PKG_RTL := $(VSP_MMU_DIR)/rtl/pkg/vsp_mmu_pkg.sv
VSP_LSU_BACKEND_PKG_RTL := \
	$(VSP_LSU_BACKEND_DIR)/rtl/pkg/vsp_lsu_backend_pkg.sv

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

VSP_EXTERNAL_DMEM_IP_RTL := \
	$(VSP_MEM_COMMON_PKG_RTL) \
	$(VSP_ADDR_ROUTER_PKG_RTL) \
	$(VSP_TLB_PKG_RTL) \
	$(VSP_PTW_PKG_RTL) \
	$(VSP_MMU_PKG_RTL) \
	$(VSP_LSU_BACKEND_PKG_RTL) \
	$(VSP_ADDR_SPACE_ROUTER_RTL) \
	$(VSP_ADDR_REGION_ROUTER_RTL) \
	$(VSP_TLB_CORE_RTL) \
	$(VSP_PTW_CORE_RTL) \
	$(VSP_MMU_FRONTEND_RTL) \
	$(VSP_MMU_CORE_RTL) \
	$(VSP_LSU_BACKEND_CORE_RTL)

RTL_VSP_DMEM_SUBSYSTEM_WRAPPER := \
	rtl/integration/vsp_dmem_subsystem_wrapper.sv

VSP_DMEM_SUBSYSTEM_WRAPPER_RTL := \
	$(RTL_VSP_PKG) \
	$(VSP_EXTERNAL_DMEM_IP_RTL) \
	$(RTL_VSP_DMEM_SUBSYSTEM_WRAPPER)

VSP_EXTERNAL_DMEM_IP_REQUIRED := $(VSP_EXTERNAL_DMEM_IP_RTL)
VSP_MEMORY_IP_LOCK := rtl/integration/memory_ip.lock
