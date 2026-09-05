# 内存子系统集成基线

> 状态：D-side 产品路径及 I-side 产品组合 RTL 已闭合到同一个通用有序物理下级端口，
> 2026-09-05。本页区分已经存在的接线、动态回归范围和仍由 SoC 集成承担的边界。
> I/D 同顶层回归已扩展到 Sv32 translated fetch、故障归因和修复重跑；host RTL 端口
> 导出有效路径上的首个已消费 IFetch fault。被动 [host MMIO](host-mmio.md) 已接入
> 启动、MMU/维护、冻结结果/诊断和 IRQ；外部总线与 SoC 下级 target 仍未接入。

## 1. 当前集成范围

当前实现保留 VSP 现有 program-source 和数据内存 ABI，并提供两种 executable profile：
`vsp_uword_cached_program_wrapper` 继续使用 behavioral control store，供现有 D-side 程序
回归；`vsp_uword_memory_system_wrapper` 静态选择 external IFetch provider，把 I/D 两侧接入
同一个 memory system。两种 provider 不会在运行时切换。

`vsp_mmio_system_wrapper` 在 combined wrapper 外接入 `vsp_host_control`，作为 host 的
被动寄存器目标，并独占 launch、MMU 和 maintenance 接缝。其 4 KiB aperture 保存控制
与结果；批量程序/数据仍由以下主动 ordered lower port 访问共享内存，详见
[host MMIO ABI](host-mmio.md)。

```text
                         strict uword program path
                         /                       \
 external provider seam /                         \ 32-bit dmem req/rsp
                       v                           v
 redirect-aware request bridge            LSU + D-region policy
        + IFetch bundle adapter            + shared MMU/iTLB/dTLB/PTW
        + independent I-region             + D-cache/local/UC/device
        + read-only I-cache                         |
                       \                            /
                        \ I-cache / D-cache / PTW /
                         \     / UC-device        /
                          shared physical fabric
                                   |
                     generic ordered lower port
                                   |
                SoC bus / RAM / MMIO decode（外部）
```

[`vsp_dmem_subsystem_wrapper.sv`](../../rtl/integration/vsp_dmem_subsystem_wrapper.sv)
连接真实的 `vsp_lsu_backend`、`vsp_address_space_router`、
`vsp_address_region_router` 和 `vsp_mmu`。MMU 内含私有 iTLB、dTLB 以及共享 PTW。

[`vsp_dmem_cached_fabric_wrapper.sv`](../../rtl/integration/vsp_dmem_cached_fabric_wrapper.sv)
在该 policy/translation core 外接入真实 D-cache adapter、可写 `param_cache`、private local
SRAM、uncached/device adapter 和 physical fabric。PTW、D-cache、uncached/device 以及
I-cache native master 在同一 physical fabric 仲裁；fabric 下方只暴露一个协议中立、严格
有序的物理 request/response 口。

[`vsp_ifetch_cached_client_wrapper.sv`](../../rtl/integration/vsp_ifetch_cached_client_wrapper.sv)
把 program source 的 external-provider seam 接到 redirect-aware request bridge、canonical
IFetch bundle adapter、独立的 instruction physical-region router、I-cache beat adapter 和
read-only `param_cache`。它只把 instruction translation 交给共享 MMU，并把 I-cache lower
master 交给共享 fabric；I-region 与 D-region 是不同的 router 实例，虽然首个组合可用同一组
elaboration 参数配置。direct I-side LOCAL endpoint 在该 profile 中关闭。

[`vsp_uword_cached_program_wrapper.sv`](../../rtl/integration/vsp_uword_cached_program_wrapper.sv)
把现有 executable uword wrapper 的 `dmem_*` 口直接连接到上述产品 D-side 组合。因此
encoded `VLOAD/VSTORE/VGATHER/VSCATTER` 不再必须由 testbench data-memory model 承接。
instruction source 仍然是内部 behavioral control store；这个 wrapper 没有把 program fetch
切换到 I-cache。

[`vsp_uword_memory_system_wrapper.sv`](../../rtl/integration/vsp_uword_memory_system_wrapper.sv)
选择 `vsp_uword_cluster_program_wrapper` 的 external-provider profile，并连接上述 I-side 与
D-side wrapper。launch 同时快照独立的 I-side address space 和 opaque 8-bit address
context；execution context 仍是另一种身份。redirect commit 直接送入 request bridge，使已
接受的旧 fetch 完整排空但不向 framer 暴露 stale words。该 wrapper 还接入统一
`vsp_memory_maintenance_controller`，组织 I/D admission quiesce、I/D cache maintenance、
统一 TLB invalidate 和 physical-fabric drain。

wrapper 上游保持现有 blocking VSP beat：

| 字段 | 当前形状 |
|---|---|
| effective byte address | 32 bit |
| 操作 | LOAD 或 STORE |
| 地址空间 | LOCAL、PHYSICAL 或 TRANSLATED |
| address context | opaque 8-bit handle |
| 数据 | 32 bit、little-endian |
| 写掩码 | 4 bit |
| ownership | 从 request 接受到 response 退休仅一个事务 |

地址路径语义如下：

- `LOCAL` 从 LSU 直接进入 local SRAM endpoint，地址是 effective address 的零扩展；
- `PHYSICAL` 先经过 address-space router 检查，再进入 final-physical region policy；
- `TRANSLATED` 对该 beat 调用 dMMU，随后进入同一套 final-physical region policy；
- region 成功后只选择 cacheable、local、uncached、device 四者之一。

其中 `vsp_dmem_subsystem_wrapper` 仍只负责 policy/translation endpoint seam；具体 endpoint
和 fabric 位于外层 cached/fabric wrapper。UNCACHED 与 DEVICE 在 region policy 以上保持
两个逻辑类别，在进入同一个 fixed-beat master 前由 VSP-owned merge 仲裁。merge 在 request
handshake 时锁存 response owner，不能根据后续 live valid 猜测返回方。两类请求最终都由
下级物理地址译码区分普通存储与 DEVICE target；当前 lower port 下方没有产品 target
decode。独立的 host MMIO aperture 是被动控制目标，不在这条主动数据请求路径上。

cached/fabric wrapper 同时暴露 MMU 配置、双 TLB 协同 invalidate、直接 D-cache
maintenance、fabric drain、LSU barrier-policy 接缝和组件诊断。其中 PTW 端口已经在内部
接入 physical fabric，不能再次送入地址翻译。

cached/fabric wrapper 暴露的 instruction-translation client 和 I-cache-native master 现已由
memory-system wrapper 使用。共享 MMU 只负责 instruction translation；独立 I-region router
完成 final-physical execute/endpoint 检查，随后只读 I-cache 形成 native lower transaction。
I-side wrapper 在 bridge 的 source response 边界保留 cause/eaddr/paddr sideband，并由
memory-system wrapper 记录首个已消费且未被 redirect 撤销的故障。既有 program source
继续使用一位 transport fault 结束当前 fetch；独立 RTL 诊断端口将详细记录交给 host
MMIO 控制器，在终止且 system quiescent 后发布冻结快照。
完整资格、地址和清除合同见[第 5 节](#ifetch-fault-contract)。

## 2. 首版产品参数

首版使用 40-bit 物理地址、128-bit I-cache front 和现有 32-bit D-side beat：

| 参数 | 首版值 | 理由 |
|---|---:|---|
| `PADDR_W` | 40 | LSU、MMU、PTW、router、cache adapter 与 maintenance controller 的共同支持配置 |
| I-side eaddr / fetch bundle | 32 bit / 最多 4×32 bit | 对应单 byte-PC source 与 external IFetch ABI |
| I-cache front | 128 bit | 首个 product profile；adapter 仍负责跨 front beat/line 的有序重组 |
| VSP/D-side eaddr | 32 | 对应现有 vector memory engine 和面向 Sv32 的 V1 接口 |
| D-side data | 32 bit | 对应一个 SIMD4 register row 和现有 LSU/D-cache adapter profile |
| address context | 8 bit | MMU context table 使用的 opaque lookup handle |
| LSU outstanding | 1 | 延续当前严格顺序和 fault 合同 |

`PADDR_W=32` 仍是受支持配置。首版从 40 bit 开始，可以在物理地址超出 32-bit effective
address 范围时保持同一接口。cache line、set、way 和 lower-memory 宽度现在是
cached/fabric wrapper 的参数，仍不属于 VSP dmem beat 的属性；默认值只是一项 bring-up
profile，不是固定的体系结构容量。

region table 目前通过 enable、base、mask、endpoint、permission、idempotence 参数在
elaboration 时配置。以后可以引入运行时 region CSR 或 firmware table，而无需改变 LSU
上游请求形状。

## 3. 外部源码闭包与内容锁

[`memory_ip_files.mk`](../../rtl/integration/memory_ip_files.mk) 以 package-first 的明确顺序
列出所需外部综合源码。VSP 不递归导入外部工程的仿真模型、checker 或项目 filelist。

| 外部工程 | 当前 product closure 使用的源码 | 职责 |
|---|---|---|
| `VSP_MEMORY_COMMON` | common package | access、address-space、endpoint、fault/status、barrier、maintenance 编码 |
| `VSP_ADDRESS_REGION_ROUTER` | package、address-space router、region router | 请求空间检查与 final-physical endpoint policy |
| `VSP_TLB` | package、TLB core | 私有 instruction/data translation cache |
| `VSP_PTW` | package、PTW core | 通过物理读口执行 Sv32 page-table walk |
| `VSP_MMU` | package、frontend、MMU core | context lookup、i/d 仲裁及 TLB/PTW 组合 |
| `VSP_LSU_BACKEND` | package、LSU core | blocking beat 检查、翻译/region 顺序及 endpoint dispatch |
| `CACHE_MODULE` | cache package、tag/data SRAM、`param_cache` | 可参数化 writable D-cache 和 read-only I-cache |
| `VSP_CACHE_ADAPTERS` | package、adapter core、D/I-cache adapter | LSU/IFetch beat 与 cache request/maintenance 的转换 |
| `VSP_IFETCH_ADAPTER` | IFetch package、request bridge、bundle adapter | legacy provider 规范化、redirect poison、translation/region/cache beat 编排 |
| `VSP_MEMORY_ENDPOINTS` | package、local SRAM/adapter、uncached/device adapter | direct-local 存储与 fixed-beat physical client |
| `VSP_MEMORY_MAINTENANCE` | package、global controller | I/D quiesce、cache/TLB action、fabric drain 与 reset quarantine |
| `VSP_PHYSICAL_FABRIC` | package、fabric core；ordered SRAM 仅供 integration top | I-cache/D-cache/PTW/uncached-device 的有序物理仲裁与测试 lower provider |

[`memory_ip.lock`](../../rtl/integration/memory_ip.lock) 记录此基线实际使用的外部 production
source SHA-256。checker 对 Make 实际解析的 `*_DIR` source list 逐项计算，而不是另行
打开固定默认目录。相关检查为：

```sh
make check-memory-ip-deps
make check-memory-ip-lock
make lint-memory-integration
make lint-memory-product-integration
make lint-vsp-uword-cached-program
make lint-ifetch-product-integration
make lint-vsp-uword-memory-system
make test-vsp-ifetch-fault
make test-vsp-uword-memory-system
```

lock 用来探测 sibling workspace 中未审查的文件内容变化。它不是 repository tag、语义版本
解析器，也不能证明两项独立修改仍然接口兼容。有意更新外部源码时，应先审查 ABI 和集成
行为，再更新对应 hash。

## 4. 验证状态

当前证据按以下层次分别报告。

### 4.1 已运行的外部 IP 切片

外部工程已有维护中的测试，覆盖：

- LSU request shape、三种 address space、fault、backpressure、各 reset phase 和
  one-request/one-response accounting；
- LSU 与真实 address-space/region router；
- LSU 与真实 MMU、dTLB、PTW 和 translated access；
- LSU 与 cache/local/uncached/device endpoint 切片；
- VSP vector memory engine 与 LSU direct-local 路径；
- MMU/TLB/PTW 及 router 的独立单元行为。

这些测试证明相应边界上的兼容性，但它们不是包含全部 D-side 组件的同一个 executable。

### 4.2 Policy/translation core 集成证据

首个 wrapper 的完整 production source closure 已通过 Verilator elaboration/lint。
`make test-memory-integration` 还把真实 LSU、router、MMU/TLB/PTW 与 registered
endpoint/PTW responder 组合为同一个 executable；当前结果为 289 checks、14 个完成的
D-side transaction，覆盖：

- VSP 端口发起 LOCAL、PHYSICAL 和 TRANSLATED 请求；
- cacheable/local/uncached/device endpoint 选择；
- BARE context 配置、Sv32 PTW physical BUS fault 和 coordinated TLB invalidate；
- endpoint request/response stall 与 VSP response holding；
- region no-match、invalid context、alignment 和 request-shape fault；
- outstanding endpoint response 被 reset 取消后的干净恢复。

该测试有意使用 registered endpoint/PTW responder，继续作为 policy/translation core 的
隔离回归。

### 4.3 Product D-side 与 behavioral-fetch executable wrapper

`make test-memory-product-integration` 把 cacheable、direct-local、uncached/device、PTW
全部接入真实 physical fabric，并在 fabric 下接 ordered SRAM responder。当前结果为
119 integration checks、270 cycles 和 20 个 lower beat，覆盖：

- direct LOCAL load/store 不进入 physical fabric；
- 初始化完成前即使 LOCAL SRAM 可接收，产品 wrapper 也会统一阻止 D-side admission；
- D-cache miss/refill、hit、write-through、invalidate-all 后重新 refill；
- UNCACHED load 与 DEVICE partial store 的 response ownership；
- BARE translated access、region no-match fault、backpressure、drain 与全路径 quiescence；
- cache/fabric performance event 和 protocol-error 汇总；该项只验证无错误路径及汇总
  可见性，不表示所有 child sticky bit 具有相同 clear 语义。

`make test-vsp-uncached-device-merge` 另以 65 checks、19 cycles 聚焦检查共享 fixed-beat
入口：已停顿的 DEVICE grant 在后到 UNCACHED request 出现时保持 payload/选择稳定，且
response ownership、response backpressure、orphan 消费与 sticky diagnostic 清除均闭合。

`vsp_uword_cached_program_wrapper` 的 RTL 已将 executable program MEMORY request/response
直接闭合到同一 D-side 组合，并保留详细 MEMORY completion（fault eaddr、requested/
completed/failed group mask、committed byte 和 partial）。这证明“程序层到真实 D-side”的
接线已经存在。`make test-vsp-uword-cached-program` 运行三次迭代的 16-byte
`VLOAD -> saturating add -> VSTORE` physical/cacheable 循环，并检查 completion
backpressure、MEMORY metadata、management interlock、cache event 和 backing SRAM；当前
结果为 580 checks、669 cycles、28 lower beats。instruction fetch 仍从 behavioral control
store 取得，不能据此称为完整 I/D memory system。

### 4.4 Product I-side / shared memory-system RTL

`vsp_ifetch_cached_client_wrapper` 和 `vsp_uword_memory_system_wrapper` 已进入明确的 external
source closure，并分别提供 `lint-ifetch-product-integration` 与
`lint-vsp-uword-memory-system` 目标。该 RTL 已经连接 external provider、redirect bridge、
共享 iMMU、独立 I-region、read-only I-cache、统一 maintenance controller 和现有 physical
fabric。

`make test-vsp-uword-memory-system` 已从同一个 generic ordered physical lower SRAM 提供
真实 program image 和 D-side 数据，运行 PHYSICAL I-fetch 加 PHYSICAL/cacheable
`VLOAD -> EXEC -> VSTORE` branch loop，最后由 `END` 收束。该项还覆盖 reset/startup
quarantine、`program_active => !system_quiescent`、程序活动时 host maintenance 不被接受，
以及程序结束后的 MMU-config 单项 ownership/response 背压和 maintenance 仲裁。host
`FENCE_I` 路径按 client quiesce、fabric drain、D-cache drain、I-cache invalidate-all、统一
TLB invalidate、completion 的顺序完成，completion 可背压，随后程序重跑。当前 PHYSICAL
基线为 1292 checks、1483 cycles、72 shared-lower beats 和 4 次 I-cache miss；其中
cold run 为 44 lower beats，maintenance 后 D-cache 保持 warm 的重跑为 28 lower beats。
这些数字仅描述 baseline 子场景，不包含下面新增的检查。

同一测试现已增加真实两级 Sv32 页表：root 位于 `0x2000`，L0 位于 `0x3000`，程序从
虚拟 PC `0x00400020` 启动并映射到物理 `0x20`。首次运行由真实 PTW 经 shared lower
读取 `0x2004`、`0x3000` 两个 PTE，并从物理 code page refill；第二次运行验证 warm
iTLB 不再产生页表读、warm I-cache 不再 refill。程序保持虚拟 END PC，D-side 仍执行
PHYSICAL load/compute/store，并检查最终 SRAM 数据。

故障场景覆盖 invalid context、context 禁止 FETCH、无效 PTE、PTE 无 X、translated
mapping 被 I-region 拒绝执行、I-cache refill 被 lower SRAM 拒绝，以及 PHYSICAL 页无
execute permission。每项检查详细 fault record、无年轻 action/data 副作用、失败收束和
lower 请求数量；修复页表并维护后无 reset 重跑成功。诊断保持跨越 program completion、
protocol clear 和 maintenance，下一次实际 launch/reset 清除。另一个完整程序场景用更老
LI completion 背压延迟 J：顺序路径的 PTW page fault 已被 source 消费并进入 host 记录，
释放 completion 后 J redirect 撤销该故障，目标 END 正常结束。新增 Sv32/IFetch 部分
通过 2355 checks、2700 cycles；本目标合计 3647 checks。

`make test-vsp-ifetch-fault` 是 VSP-owned client 边界的定向测试：实例化真实 bridge、
IFetch adapter、I-region 和 I-cache，使用可控 translation responder 检查 fault metadata
背压保持、有效地址与物理诊断区分，以及 MMU wait、canonical response 捕获同拍、held
source response 三种 redirect 时机下的 poison/drain 和新请求恢复。当前通过 2626
checks、163 cycles。它验证 wrapper 的 sideband 对齐与资格，不重做外部 IP 的独立功能
验收。

上述完整程序的新 redirect 场景发生在 PTW fault 已被 source 消费之后，client 定向测试
使用可控 MMU response；二者都没有覆盖完整产品程序在 outstanding I-cache miss 期间
redirect 的交错，也未覆盖下级 DEVICE target 或外部 AXI/NoC backpressure。被动控制口的
结果与 fault-register 映射由独立 [host MMIO 组合](host-mmio.md) 提供。

## 5. Product I-side 接线

当前 product profile 已使用以下链路：

```text
vsp_uword_program_source external-provider seam
  -> vsp_ifetch_request_bridge
  -> vsp_ifetch_cache_adapter
  -> shared iMMU + independent I-region router
  -> vsp_icache_beat_adapter
  -> read-only param_cache
  -> shared physical fabric
```

`vsp_uword_cluster_program_wrapper` 以 elaboration-time profile 选择 behavioral control store
或 external provider；不是运行时存储源 mux。external profile 关闭 control-store programming
admission，并导出 provider request/response 和精确的 committed redirect event。bridge 把
source 允许在 redirect 前撤回的未接受请求，转换成一旦接受就保持的 canonical IFetch
request；redirect 后已经被 bridge/cache/MMU 接受的事务仍须完整排空，其返回被标记 stale。

launch 的 I-side address-space/context 已由 memory-system wrapper 在实际 start handshake
快照，后续 host 输入不能改变在途 fetch。当前 profile 允许 PHYSICAL 或 TRANSLATED fetch
进入 I-region/I-cache；direct I-side LOCAL endpoint 没有实例化。program source 的既有
一位 fault 继续控制 transport failure，详细 cause/eaddr/paddr 由 VSP-owned I-side
wrapper 的 sideband 与同一 source response 对齐。

<a id="ifetch-fault-contract"></a>

### 5.1 IFetch fault 与 host 诊断合同

`vsp_ifetch_cached_client_wrapper` 的 `source_rsp_fault_cause_o`、
`source_rsp_fault_eaddr_o`、`source_rsp_fault_paddr_o` 只在
`source_rsp_valid_o && source_rsp_fault_o` 时有意义，其余时间输出 NONE/零。metadata 在
canonical response 被 bridge 接受时寄存，再按 bridge 的 live/stale 资格发布；没有
redirect 时，held source response 的一位 fault 和全部 metadata 保持稳定。redirect
可将尚未消费的 response 转成零 words、零 fault/metadata 的 drain token，包括 redirect
与 canonical response 捕获同拍、以及 response 已被 source 背压的情形。原始 canonical
fault 不能绕过这层资格直接成为 host 记录。若 bridge 因 response 协议形状错误产生一位
fault，而没有定义良好的非 NONE canonical cause，sideband 使用 PROTOCOL、accepted
request PC 和零 paddr。

`vsp_uword_memory_system_wrapper` 导出六个 host 观察端口：

| 端口 | 宽度 | 意义 |
|---|---:|---|
| `ifetch_fault_valid_o` | 1 | 当前有效路径已有一条已消费的 IFetch fault 记录 |
| `ifetch_fault_cause_o` | COMMON fault，3 bit | NONE=0、TRANSLATION=1、PERMISSION=2、ACCESS=3、BUS=4、DATA_INTEGRITY=5、PROTOCOL=6 |
| `ifetch_fault_eaddr_o` | 32 | 故障归属的实际请求 word effective byte address |
| `ifetch_fault_paddr_o` | `PADDR_W` | 下层 IP 原样提供的 physical diagnostic address |
| `ifetch_fault_addr_space_o` | 2 | 当前 launch 快照的 I-side address space |
| `ifetch_fault_addr_context_o` | 8 | 当前 launch 快照的 address context；不是 execution context 或 ASID |

记录只在 program source 接受 live fault response，即 `provider_rsp_valid &&
provider_rsp_ready && provider_rsp_fault` 时更新；当前记录有效后不被后续 fault 覆盖。
reset、实际 launch handshake 和 committed redirect 清除记录及全部字段；program
completion、`protocol_error_clear_i`、MMU configuration 和 maintenance 不清除它。
仅把 `start_valid_i` 拉高而没有握手也不清除记录。

source 消费不是最终程序退休点：更老 branch 仍可能在之后 redirect，撤销已经消费的
sequential fetch fault。host 在 `program_active=1` 时看到的记录因此是暂存诊断，必须
允许 committed redirect 清除；被 poison 的旧 response 不建立新记录。host 应在
`program_failed_o` 发生并且 `system_quiescent_o=1` 后读取失败运行的最终记录，再启动
下一次运行。该机制没有定义 exception PC、自动 trap 或程序内 CSR 查询。

`eaddr` 是架构归属地址，`paddr` 是诊断值，两者不能互换。`ifetch_fault_valid_o` 只表示
记录有效，**不是 physical-address-valid**；接口没有独立的 paddr-valid bit。翻译阶段
fault 的 paddr 为零，零值本身不能推导地址是否有效；refill fault 的 paddr 可以指向
失败的物理 lower beat，而不是请求 PC 对应的 word。当前集成回归的对应关系如下：

| 故障来源 | cause | eaddr | paddr |
|---|---|---|---|
| invalid/out-of-range context | ACCESS | `0x00400020` | 0 |
| context 不允许 FETCH | PERMISSION | `0x00400020` | 0 |
| L0 PTE 无效 | TRANSLATION | `0x00400020` | 0 |
| 有效 V/R/U/A leaf 缺 X | PERMISSION | `0x00400020` | 0 |
| translated 页映射到不可执行的 physical region | PERMISSION | `0x00400020` | `0x1020` |
| region 允许但 backing SRAM 拒绝 refill | ACCESS | `0x00400024` | `0x4020` |
| PHYSICAL 请求不可执行 region | PERMISSION | `0x1020` | `0x1020` |

取指故障不生成 MEMORY action completion。source 停止交付故障 bundle，controller 保留
更老完整 record 的退休机会并排空不完整尾部；有效路径最终以 `program_failed` 单拍和
sticky `program_error` 收束。既有 `fetch_protocol_error_o` 汇总包含 source 的一位
transport fault，所以普通 ACCESS/PERMISSION 也可能让这一 aggregate 为高，而
IFetch/MMU/fabric 子模块本身没有发生协议错误。新的详细记录用于区分原因，不改变这些
既有状态信号的合同。

故障后可等路径 quiescent，修复 context/PTE，完成必要维护，再正常 launch。cfg 写入
不自动 invalidate TLB；修改 PTE 权限或映射必须执行统一 TLB invalidate，或包含该步骤的
host `FENCE_I`。[host MMIO ABI](host-mmio.md) 定义结果读取、ACK_RESULT、维护与重新
START 的寄存器序列；OS driver、总线适配和更完整异常策略仍由后续 SoC/软件集成定义。

## 6. I-side admission 与 quiesce 规则

IFetch request bridge 可能已经拥有 program-source request，而 canonical IFetch adapter
尚未接受它。因此 global I-side quiesce 必须作用在 program-source admission 边界，不能只
连接 `vsp_ifetch_cache_adapter.fetch_accept_enable_i`。

如果 quiesce 只关闭后者，可能出现循环等待：

```text
bridge 已拥有 accepted source request
  -> canonical IFetch admission 被关闭
  -> bridge 无法排空，始终不 idle
  -> maintenance 永久等待 ifetch_idle
```

当前 `vsp_ifetch_cached_client_wrapper` 采用以下等价关系：

```text
source_to_bridge_valid = source_valid && ready && source_admit_enable
source_ready           = bridge_ready && ready && source_admit_enable

fetch_accept_enable = source_admit_enable || bridge_busy
ifetch_idle          = bridge_idle && ifetch_adapter_idle
```

这样在 maintenance command 接受当拍就阻止新的 source handshake，同时让此前已经接受的
工作完整结束。quiesce 只能阻止 admission，不能关闭 response ready 或旧事务退休所需的
任何下游路径。

memory-system wrapper 把 `source_admit_enable` 接为 `!maint_i_quiesce`，并保持所有 response
ready 和旧事务下游路径不受该门控。bridge 的 `redirect_commit_i` 已连接更新单一 program
PC、清除 framer 的同一个 committed redirect event；launch address-space/context 也已经在
实际 start handshake 快照。

## 7. 两种 management profile 与尚缺的 LSU policy bridge

`vsp_uword_cached_program_wrapper` 现在为四种 host-side management request 提供一项
registered lane：MMU configuration、coordinated TLB invalidate、D-cache maintenance 和
physical-fabric drain。只在 `program_active=0`、D-side ready 且全路径 quiescent 时接受；
同拍多请求按上述顺序固定优先。payload 在 acceptance 时快照，直到对应 response/drain
completion 才释放 lane。program launch 在 management request present/active 时被阻止，
因此管理事务不会与新程序启动交叉。

这是 D-only behavioral-fetch wrapper 的 bring-up serialization，不是新的 I/D 组合所使用的
完整路径。

`vsp_uword_memory_system_wrapper` 已接入 `vsp_memory_maintenance_controller`。host global
command 只在 `program_active=0` 时才可能被接受；接受后 controller 同拍阻止新的 I/D
admission，等待 LSU、IFetch、共享 MMU/PTW、I/D cache 和下游路径静止，持有 fabric drain，
再按操作串行发出 D-cache、I-cache 或统一 TLB maintenance。program launch 则要求 I/D 路径、
controller 和 lower provider 全部 ready/quiescent，并避开同拍 maintenance/MMU-config
request。mid-program `FENCE.I` 仍不接受，因为 sequencer 尚未定义怎样撤销已 fetch/frame 的
年轻 uword。

`vsp_lsu_backend` 暴露窄的 blocking barrier intent，
`vsp_memory_maintenance_controller` 则接收更宽的 global command，并管理 I/D admission、
cache operation、TLB invalidate、physical-fabric drain 和 reset quarantine。两者之间的
policy bridge 仍需决定：

- 各 LSU barrier 如何映射到 global operation；
- effective line address 如何获得所需的 final physical line address；
- address context 如何映射到 ASID/TLB scope；
- global completion status/fault 如何转换回 LSU barrier response；
- 哪一个 barrier 接受前 idle 信号代表更老的 LSU 工作已经排空。

如果 LSU 接受 barrier 后，再把 LSU 的 public `idle_o` 反馈给 global controller，会产生
另一种循环等待：LSU 必须等到 maintenance response 才重新 idle，而 controller 又在等待
同一个 idle。policy bridge 需要把 ordinary-request quiescence 与 barrier 自身的 ownership
分开表示。

global maintenance 已连接 I-cache adapter/admission、D-cache、统一 MMU/TLB 和 fabric，
但仍依赖 wrapper 外可信的 `lower_quiescent_i` reset-epoch 条件。它不实现 SoC bus drain、
DMA ownership 或 cache coherence。

尚缺的是 LSU narrow barrier intent 到 host/global command 的 policy bridge。当前 combined
wrapper 仍把 LSU barrier seam 关闭；上述 host maintenance 接线不能自动回答 effective line
translation、ASID scope 或 barrier completion 怎样返回 LSU。

## 8. Reset 与事务 ownership

VSP dmem beat、LSU 和 fixed-beat endpoint 使用 blocking ready/valid transaction。request
acceptance 转移 ownership，直到 response acceptance 才结束；endpoint 接受 store data
不代表该 STORE 已完成。D-cache lower refill/write 可以包含多个 beat，physical fabric 在该
client 的 terminal read/write response 前保持 owner，不与另一 client 的 transaction 交错。

当前 combined 产品组合让 program-source bridge、IFetch/LSU、MMU/TLB/PTW、adapter、
I/D cache 和 fabric
共享一个 transaction reset epoch：

- reset 可以取消 accepted work，reset 后不必补 response；
- reset deassertion 在 `clk_i` 域同步；
- 前一个 epoch 的 response 不能被误认作新 request 的 completion；
- 如果 lower transport 不能与 client 同步 reset，必须在新 admission 前加入 integration-owned
  epoch tag 或 quarantine/drain。

内层 `internal_quiescent_o` 只覆盖 LSU/router/MMU。外层 `dmem_path_quiescent_o` 还合取
D-cache、local endpoint、uncached/device merge、physical fabric 和
`lower_quiescent_i`；I-side `quiescent_o` 合取 bridge、IFetch adapter、I-region router、
I-cache adapter 和 I-cache initialization。combined `system_quiescent_o` 再合取 I/D 两侧和
maintenance/config ownership。`lower_quiescent_i` 仍由 wrapper 外部提供，因此不能凭
fabric idle 猜测 AXI/NoC bridge、RAM controller 或 MMIO target 已排空。

MMU 的 `cfg_ready` 和 `tlb_inv_req_ready` 只证明 MMU 自身满足接收条件。产品控制在修改
context 或执行 TLB invalidate 前，还必须停止新的 I/D admission，并确认 LSU、IFetch 与
MMU 均已排空；否则一条已被 LSU/IFetch 接受、但尚未到达 MMU 的旧请求可能跨过配置或
invalidate 边界。

## 9. 当前歧义与集成限制

这些项目不阻止首轮 bring-up，但继续向软件/SoC 边界推进前需要明确。

1. **LOCAL 地址表示。** LSU 当前把 `LOCAL` effective address 零扩展后直接交给 local
   SRAM adapter；adapter 同时拥有 `LOCAL_BASE_ADDR`。首个 executable profile 使用
   base-zero direct-local，并不配置一个指向同一 SRAM 的 physical LOCAL alias。以后若让
   `LOCAL` 表示 offset、让它带系统物理基址，或允许 PHYSICAL/TRANSLATED region alias 到
   同一 SRAM，需要选择一种语义并验证权限、越界和别名行为。
2. **Trusted uword 与 launch metadata。** MEMORY record 可以直接给出
   `LOCAL/PHYSICAL/TRANSLATED` 和 8-bit address context；combined wrapper 的 launch 也直接
   接受 I-side address space/context。当前没有 privilege/CSR 层替不可信程序或 host 描述符
   过滤 physical access、限制 context 或证明 program image 的权限，因此仍是 trusted-uword
   profile。
3. **Maintenance policy bridge。** Host global maintenance 已连接 I/D cache、统一 TLB 和
   fabric，并只在 program inactive 时接受；LSU barrier 到这些 global action 的 policy
   mapping 仍未定义。
4. **真实 lower target。** physical fabric 下方是 generic ordered request/response，不是
   AXI/NoC，也不包含 RAM/MMIO address decoder。UNCACHED 与 DEVICE 虽在上层保持不同
   policy 类别，当前都到达同一个 adapter；是否为 DEVICE 配置强序、副作用和 fault 行为要
   由下级目标集成决定。
5. **Diagnostic clear 非对称。** 顶层 `protocol_error_clear_i` 会清除 VSP-owned LSU/MMU、
   IFetch bridge/bundle adapter、uncached-device merge、maintenance controller 和
   physical-fabric sticky diagnostics；外部 I/D cache beat adapter 的 `protocol_error_o`
   目前只有 reset clear。顶层 aggregate 包含这些位，所以一次顶层 clear 之后仍可能保持为
   一。软件/验证不能把该输入解释为“原子清除全部子模块错误”。
6. **Program memory-fault policy。** 详细 MEMORY fault/partial completion 现已透出，但
   strict controller 的既有行为是退休该错误 action、置 sticky `program_error`，随后继续
   执行较年轻 uword；若之后合法到达 `END`，`program_done` 与 `program_error` 可以同时
   表示“一次有错误但已结束的运行”。当前没有 trap/redirect，也不能由程序读取 fault 后
   分支。该行为适合作为 host-observed bring-up policy，进入不可信或可恢复执行模型前需要
   决定是否改为 fail-stop、异常入口或显式状态查询。
7. **IFetch 诊断与异常边界。** cause/eaddr/paddr 与 launch address-space/context 遵守
   [有效路径与 redirect 合同](#ifetch-fault-contract)，并在 host MMIO 的冻结 IFETCH_*
   寄存器中发布。寄存器读取/确认/重启合同见 [host MMIO ABI](host-mmio.md)；OS driver、
   异常入口和完整产品的 outstanding-miss redirect 验证仍待后续集成。

## 10. 后续闭环顺序

1. 当 sibling IP 改动时继续维护明确的外部源码闭包、content lock 和已有 D-side 回归。
2. 在已有 Sv32/fault/recovery combined I/D 回归上继续补完整产品程序的 redirect during
   an outstanding I-cache miss 和更有针对性的 I/D fabric 竞争。
3. 为 generic ordered lower port 接入具体 SoC target decode/bus adapter，并验证 RAM 与 MMIO
   fault、store acknowledgement、reset epoch 和 `lower_quiescent`。
4. 定义 LSU barrier 到现有 global maintenance command 的 policy bridge；在此之前继续只
   允许 program 外 host maintenance。
5. 在把组合称为 SoC 内存子系统前，加入 AXI/NoC adaptation、真实 RAM/MMIO target decode、
   DMA ownership/coherence policy，并运行 backpressure 与 reset stress。
