# 内存子系统集成基线

> 状态：首个 D-side 集成壳，2026-09-01。本页区分 VSP 仓库已经存在的接线与仅在
> 外部 IP 工程中完成的分切片验证。它记录当前产品集成基线，不预先规定最终 cache
> 几何、下级总线或 maintenance 策略。

## 1. 当前集成范围

第一步保留 VSP 现有数据内存 ABI，在它的下方组合外部内存 IP：

```text
当前 VSP 32-bit dmem request/response
                    |
                    v
       vsp_dmem_subsystem_wrapper
                    |
       +------------+-------------+
       |            |             |
 address-space    shared MMU    physical-region
    router       + i/d TLB/PTW      router
       |            |             |
       +------------+-------------+
                    |
       cacheable / local / uncached / device
                    |
                    v
           endpoint 与物理 fabric（外部）
```

[`vsp_dmem_subsystem_wrapper.sv`](../../rtl/integration/vsp_dmem_subsystem_wrapper.sv)
连接真实的 `vsp_lsu_backend`、`vsp_address_space_router`、
`vsp_address_region_router` 和 `vsp_mmu`。MMU 内含私有 iTLB、dTLB 以及共享 PTW。

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

- `LOCAL` 从 LSU 直接进入 local endpoint，地址是 effective address 的零扩展；
- `PHYSICAL` 先经过 address-space router 检查，再进入 final-physical region policy；
- `TRANSLATED` 对该 beat 调用 dMMU，随后进入同一套 final-physical region policy；
- region 成功后只选择 cacheable、local、uncached、device 四者之一。

wrapper 不包含 endpoint 实现和物理 fabric。它同时暴露 MMU 配置、双 TLB 协同
invalidate、PTW 物理读口、LSU barrier-policy 接缝和组件诊断。其中 PTW 端口已经是
物理地址，不能再次送入地址翻译。

wrapper 为未来 IFetch 暴露了共享 MMU 的 instruction-translation client；该端口只负责
翻译。I-side 的 physical-region 分类、bundle 重组、cache 访问及 program-source 集成不属于
这个 D-side wrapper。

## 2. 首版产品参数

首版使用 40-bit 物理地址和现有 32-bit D-side beat：

| 参数 | 首版值 | 理由 |
|---|---:|---|
| `PADDR_W` | 40 | LSU、MMU、PTW、router、cache adapter 与 maintenance controller 的共同支持配置 |
| VSP/D-side eaddr | 32 | 对应现有 vector memory engine 和面向 Sv32 的 V1 接口 |
| D-side data | 32 bit | 对应一个 SIMD4 register row 和现有 LSU/D-cache adapter profile |
| address context | 8 bit | MMU context table 使用的 opaque lookup handle |
| LSU outstanding | 1 | 延续当前严格顺序和 fault 合同 |

`PADDR_W=32` 仍是受支持配置。首版从 40 bit 开始，可以在物理地址超出 32-bit effective
address 范围时保持同一接口。cache line、set、way、lower-memory 宽度及 endpoint latency
由 endpoint 集成选择，不属于 VSP dmem beat 的属性。

region table 目前通过 enable、base、mask、endpoint、permission、idempotence 参数在
elaboration 时配置。以后可以引入运行时 region CSR 或 firmware table，而无需改变 LSU
上游请求形状。

## 3. 外部源码闭包与内容锁

[`memory_ip_files.mk`](../../rtl/integration/memory_ip_files.mk) 以 package-first 的明确顺序
列出所需外部综合源码。VSP 不递归导入外部工程的仿真模型、checker 或项目 filelist。

| 外部工程 | 首个 wrapper 使用的源码 | 职责 |
|---|---|---|
| `VSP_MEMORY_COMMON` | common package | access、address-space、endpoint、fault/status、barrier、maintenance 编码 |
| `VSP_ADDRESS_REGION_ROUTER` | package、address-space router、region router | 请求空间检查与 final-physical endpoint policy |
| `VSP_TLB` | package、TLB core | 私有 instruction/data translation cache |
| `VSP_PTW` | package、PTW core | 通过物理读口执行 Sv32 page-table walk |
| `VSP_MMU` | package、frontend、MMU core | context lookup、i/d 仲裁及 TLB/PTW 组合 |
| `VSP_LSU_BACKEND` | package、LSU core | blocking beat 检查、翻译/region 顺序及 endpoint dispatch |

[`memory_ip.lock`](../../rtl/integration/memory_ip.lock) 记录此基线实际使用的外部 production
source SHA-256。checker 对 Make 实际解析的 `*_DIR` source list 逐项计算，而不是另行
打开固定默认目录。相关检查为：

```sh
make check-memory-ip-deps
make check-memory-ip-lock
make lint-memory-integration
```

lock 用来探测 sibling workspace 中未审查的文件内容变化。它不是 repository tag、语义版本
解析器，也不能证明两项独立修改仍然接口兼容。有意更新外部源码时，应先审查 ABI 和集成
行为，再更新对应 hash。

## 4. 验证状态

当前证据分为两个层次，应分别报告。

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

### 4.2 VSP 所有的集成证据

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

具体 cache/local/uncached/device 实现、physical fabric、与
`vsp_uword_cluster_program_wrapper` 的实际接线及 vector load/compute/store 程序仍是产品级
工作。因此当前结果是一项经过动态测试的 D-side 集成基线，而非完整内存子系统。

## 5. 为什么 I-side 单独进入下一闭环

外部 IFetch 工程已经提供以下可用链路：

```text
vsp_uword_program_source
  -> vsp_ifetch_request_bridge
  -> vsp_ifetch_cache_adapter
  -> vsp_icache_beat_adapter
  -> param_cache
```

它已经分别验证 PHYSICAL path、redirect poison、cache miss/refill、跨 line 和真实 MMU
translation。但还没有接入 VSP 产品 wrapper，原因是：

1. `vsp_uword_cluster_program_wrapper` 仍在内部实例化 behavioral control store，没有暴露
   program-provider 边界；
2. program launch 尚未捕获独立的 I-side address space 和 8-bit address context；execution
   context 是另一种概念，不应隐式复用；
3. 当前 program-source response 把丰富的 IFetch fault 折叠成一个 bit，足以终止现有
   stream，但不能保留产品诊断所需的 cause、effective fault address 和 physical fault
   address。

因此 D-side wrapper 现在只先暴露共享 MMU 的 instruction-translation client，把 program
provider、I-side region routing、I-cache 及 fault-reporting adapter 留在后续集成步骤。这使
初次 D-side bring-up 不必同时承担 fetch interface 重构。

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

可以采用以下集成关系：

```text
source_to_bridge_valid = source_valid && !i_quiesce
source_ready           = bridge_ready && !i_quiesce

fetch_accept_enable = !i_quiesce || bridge_busy
ifetch_idle          = bridge_idle && ifetch_adapter_idle
```

这样在 maintenance command 接受当拍就阻止新的 source handshake，同时让此前已经接受的
工作完整结束。quiesce 只能阻止 admission，不能关闭 response ready 或旧事务退休所需的
任何下游路径。

bridge 的 `redirect_commit_i` 必须接收更新单一 program PC、清除 framer 的同一个 committed
redirect event。launch 还应为整个运行过程快照 I-side address-space/context，避免 host 输入
在 outstanding fetch 期间改变事务语义。

## 7. 为什么首个 wrapper 不接 global maintenance

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

global maintenance 还依赖具体的 D-cache/I-cache adapter、physical fabric drain 语义和可信的
`downstream_quiescent` reset-epoch 条件。产品 wrapper 不应使用无条件 ready/done 常量代替
这些后置条件。

首版只在 `program_active=0` 时接受 host 发起的 maintenance。mid-program `FENCE.I` 还需要
有序退休并清除已经 fetch/frame 的年轻 uword；memory controller 本身不具备 sequencer
层面的这项行为。

## 8. Reset 与事务 ownership

当前内存 IP 均使用 blocking ready/valid transaction。request acceptance 转移 ownership，
直到 response acceptance 才结束；endpoint 接受 store data 不代表该 STORE 已完成。

首个产品组合应让 LSU、MMU/TLB/PTW、adapter、cache、fabric 和无 tag endpoint responder
共享一个 transaction reset epoch：

- reset 可以取消 accepted work，reset 后不必补 response；
- reset deassertion 在 `clk_i` 域同步；
- 前一个 epoch 的 response 不能被误认作新 request 的 completion；
- 如果 lower transport 不能与 client 同步 reset，必须在新 admission 前加入 integration-owned
  epoch tag 或 quarantine/drain。

`internal_quiescent_o` 只覆盖 D-side wrapper 内部状态，不能证明 wrapper 外部的 cache、
endpoint、PTW backing memory 或 physical fabric 没有保留事务。

MMU 的 `cfg_ready` 和 `tlb_inv_req_ready` 只证明 MMU 自身满足接收条件。产品控制在修改
context 或执行 TLB invalidate 前，还必须停止新的 I/D admission，并确认 LSU、IFetch 与
MMU 均已排空；否则一条已被 LSU/IFetch 接受、但尚未到达 MMU 的旧请求可能跨过配置或
invalidate 边界。

## 9. 产品闭环顺序

1. 当 sibling IP 改动时继续维护明确的外部源码闭包、content lock 和组合回归。
2. 接入具体 D-cache/local/uncached/device endpoint 与 physical fabric，验证 endpoint
   status-to-fault 转换和 STORE acknowledgement 恰好一次。
3. 用 D-side wrapper 替换产品 wrapper 当前的直接 dmem model 接线，重新运行完整 vector
   load/compute/store 程序。
4. 提取 I-side provider 边界，增加 launch address metadata，把 IFetch 链接入共享 iMMU 与
   I-cache。
5. 加入 maintenance policy bridge、admission gate、cache/TLB action、physical-fabric drain
   和 reset quarantine。
6. 在把组合称为产品内存子系统前，运行 I/D 竞争、I-cache miss 期间 redirect、PTW 活动
   期间 translated data access、maintenance barrier、backpressure 和 reset stress。
