# 队列、微指令与译码器候选设计

> 状态：GROUP_EXEC exec shell 与 late-decode holding shell 已有参考 RTL；真实
> predecoder/canonical expander、class router 和 encoded format 尚未实现。本文用于
> 比较实现路径，不拥有最终指令格式或控制器组织的决策权。

## 1. 当前真实状态 `[RTL事实]`

现在已有 full-decoded GROUP_EXEC 集群闭环和译码后的状态边界，但还没有实际解析
compact uword 位域的译码逻辑：

- `simd_datapath` 直接接收 `op`、寄存器地址、立即数、mask、route、reduction
  和写回选择等展开控制；
- testbench 充当外部 sequencer，直接驱动这些信号；
- `simd_uop_legal` 检查展开控制的 mode、写回、route 和 reduction 组合；
- `simd_issue_dispatch` 只处理 `valid/context/group_mask/group_ready` 并输出每个
  group 选择哪个 issue slot，它不保存或解释完整操作 bundle；
- `simd_issue_queue` 为每个 context 保存独立有序 FIFO，当前有一个 admission
  入口并并行暴露所有 context head；它把 `uword/resolved/sched_meta/tag` 当作
  不透明 entry 保存，不解释任何指令位域；
- `simd_cluster_issue_frontend` 默认以 `4 group / 2 queue / 2 slot`
  集成 queue、round-robin live-head 选择、opaque locked shadow、显式
  reject credit、terminal pop 和原子 group dispatch；当前 queue identity 在参考
  profile 中同时作为 ownership context；
- `simd_group_wrapper` 已直接接受 canonical decoded EXEC，并以独立 state-write
  子事务提供 VRF/ARF/MRF 数据注入、tagged child completion 和可背压结果；
  这没有增加 encoded-uword parser。
- `simd_cluster_exec_shell` 已按 `group_issue_slot` 选择完整 canonical bundle，
  通过每 group 单项 ingress 原子 multicast 到四个 wrapper，并接入 tracker、reject
  buffer 和 result collector；当前 admission 仍由可信上游直接提供展开控制；
- `simd_issue_decode_shell` 是每 issue slot 一项、无 fall-through 的 late-decode
  holding stage：它锁存 raw/resolved/cached provenance，以及 hook 产生的
  class/response/group-mask/exact-resource/canonical-payload/legal/error；背压时所有
  字段稳定。当前 hook 是参考 adapter 接口，不是 encoded parser。

因此现在可以准确地说：full-decoded reference profile 已能执行和退休
GROUP_EXEC；decode holding 的协议也已验证。尚缺的是从真实 encoded/compact uword
唯一派生 hook 输出的 predecoder/expander，以及把该 late-decode stage 重排到 queue
head 与 class router 之间。holding shell 本身不等于完成了译码规则。

## 2. 区分三种表示 `[分析模型]`

```text
encoded instruction/uword
    紧凑、适合控制存储和深 FIFO
             │ decode / canonicalize
             ▼
decoded uop bundle
    展开的执行控制，适合 issue、legality 和 datapath
             │ dispatch by slot/group mask
             ▼
SIMD4 group control signals
```

外部软件指令、sequencer 内部 uword 和最终 decoded bundle 不必具有相同宽度或
编码。当前 `op_i`/`exec_op_i` 上的 6-bit `simd_op_e` 只是
canonical GROUP_EXEC bundle 中的 function，不是完整 opcode。

## 3. 三种 queue 方案 `[候选比较]`

| 方案 | 优点 | 代价 |
|---|---|---|
| full-decoded FIFO | 发射端简单、被阻塞时控制稳定 | entry 很宽，FIFO 面积和切换功耗大；编码变化会扩散到所有 queue |
| encoded FIFO + late decode | entry 紧凑、控制存储自然 | 调度前看不到完整资源需求；多 head 可能复制译码或形成时序瓶颈 |
| compact FIFO + cached predecode + head expansion | 存储较小，同时能提前仲裁资源 | 两段译码之间必须保持语义一致，并定义 canonical bundle |

当前 `simd_issue_queue`、frontend 与 decode holding shell 提供第三种 hybrid 可复用
的存储、发射和稳定输出协议边界，但不规定不透明字段的 bit layout。它仍需要真实
predecoder/expander、queue 面积和代表性 trace
比较；前两种方案没有因此被架构性排除。“无解码队列”不是独立方案：保存
encoded uword 只是把译码推迟到队头之后。

## 4. 当前参考数据流 `[候选]`

```text
sequencer / microcode store
        │ encoded uword + resolved sideband
        ▼
admission format parse + predecode
        │ queue_entry + derived sched_meta
        ▼
per-context compact FIFO
        │ expose one ordered head per context
        ▼
round-robin head scheduler
        │ select at most ISSUE_SLOTS heads
        ▼
ISSUE_SLOTS copies of canonical expander
        │ canonical decoded uop
        ▼
exact shared-resource arbitration
        │
        ├─ GROUP_EXEC ── atomic group-mask dispatcher ── SIMD4 wrappers
        ├─ EXCHANGE ──── exchange engine
        ├─ MEMORY ────── DMA/local-memory engine
        └─ CONTROLLER ── barrier/admin state machine
```

深 FIFO 保存紧凑 uword；展开表示只出现在所选队头的组合 expander 输出，或可选的
浅 holding register 中。
canonical expander 数量随 `ISSUE_SLOTS` 增长，而不是随 `CONTEXT_COUNT` 或
`GROUP_COUNT` 增长。对默认四组双发射配置，基线是两个 expander。

当前 frontend 已有 live-head fast path 和每 slot 的 opaque locked shadow。未受理的
live head 在时钟沿被复制到 shadow，FIFO 暂不 pop；只有原子 group accept，
或已获得 `reject_ready` credit 的错误 reject，才同时清 slot 并 terminal
pop。这保证 downstream backpressure 下 payload 稳定，FIFO head 仍是唯一
逻辑 owner。但 shadow 保存的是 opaque payload/resolved/sched_meta，不是已由
本仓库 expander 生成的 canonical decoded bundle。

第一版 `simd_cluster_exec_shell` 已用 full-decoded queue profile 闭合
`group_issue_slot` bundle mux、group ingress、wrapper、tracker 和 result/reject
返回。尚缺的是把真实 predecoder/canonical expander 与 class router 放到选中队头
和该 canonical cluster 边界之间；当前 exec shell 不负责 encoded format。

## 5. Queue entry 应保存什么 `[RTL边界 + 候选语义]`

当前 `simd_issue_queue` 实际保存四项参数化字段：`tag + uword + resolved +
sched_meta`。context 由所属逻辑 FIFO 隐含；默认宽度只是 elaboration 配置，不是
32-bit ISA 或 metadata layout。逻辑上后三项分别对应：

紧凑 uword 保存：

- format/major class 与 function；
- VRF/ARF/MRF 源和目的地址；
- element mode、mask 选择与写回类别；
- immediate/shift 的短编码或 extension 引用；
- route/reduce 子功能或 route preset；
- barrier/exchange/memory 等控制类操作。

由 sequencer 解析后附带的动态 sideband 保存：

- `tag`；per-context FIFO 的 `context_id` 通常由 FIFO 编号隐含，只有共享物理
  queue 才需要逐 entry 保存；
- `target_group_mask`；
- 循环迭代产生的有效 mask；
- 已解析的 scalar 参数、extension word 或控制存储索引；
- 需要时的 memory descriptor 引用、短地址操作数和依赖；bulk data 与完整 mover
  状态不进入 instruction queue。

由 admission predecode 从前两部分唯一派生并缓存的 `sched_meta` 保存：

- `dispatch_class` 与 `response_kind`；
- 当前调度真正消费的粗粒度 group-state/write-port 类别；若以后不同 RF 文件或
  物理 bank 参与队头选择，再加入相应 file mask/bank hint；
- 保守的 shared-resource may-need mask 与 serialize/ordering class；
- 静态合法性和错误原因。

`sched_meta` 不是软件或 sequencer 可以任意填写的第二份资源声明；它必须由硬件
predecoder 生成，并在 canonical expansion 时复核关键约束。
当前四个字段使用独立参数宽度只是为了先验证 FIFO。接入真实 predecoder 前，应由
唯一的 `uword_t/resolved_t/sched_meta_t`（或等价 profile type）的 `$bits` 驱动这些
宽度，避免 controller top 人工重复 `32/16/16`；这仍不要求确定最终 ISA。

`group_mask` 可能比一个普通指令字更宽，也可能来自 owner/context 状态，因此没有
必要强迫它永久占据基础 uword。相邻 boundary data、RF 读数据和 Bênes data 更不
应该进入 instruction FIFO；它们属于 operand/staging 通道。

## 6. Predecode 与调度 `[候选]`

head scheduler 在选择 context 前需要少量信息，但不需要看到完整 datapath bundle。
admission record 向它暴露两类字段：`target_group_mask` 来自受信的 resolved
sideband，predecoder 只验证并使用它；其余 scheduling metadata 由轻量解析唯一
派生：

```text
dispatch_class   = GROUP_EXEC / EXCHANGE / MEMORY / CONTROLLER
response_kind    = NONE / STATUS / GROUP_DATA / MEMORY_DATA
group_state/write_port coarse class
resource_may_need_mask
serialize/ordering class
static_error + cause
```

第二阶段 canonical expander 在某个 head 被 issue slot 选中后才产生：

```text
simd_op + element mode
exact VRF/ARF/MRF row addresses and writeback enables
expanded immediate and default fields
route/reduce/mask/export controls
class-specific GROUP_EXEC / MEMORY / EXCHANGE / CONTROLLER request
final legality + exact resource set
```

这就是“半解码”的准确含义：不是只译一半指令，而是两段译码，中间只缓存调度
提前需要的结果。一个字段是否应该 predecode 的判断标准是：scheduler 在选择 head
之前是否立即消费它。当前还没有 bank/hazard scoreboard，因此完整 RF file mask、
row 地址和 latency class 都留在晚译码；若以后不同 RF 文件并发或物理 bank 冲突
参与 head 选择，可只提前派生相应 file mask、bank index 或 address descriptor，
而不是把整份 decoded bundle 塞回深 FIFO。

`response_kind` 是返回形态，不应与目的执行引擎混成一个 class。例如 reduction
仍是 `GROUP_EXEC`，只是产生 `GROUP_DATA`；barrier/admin 通常走 `CONTROLLER`，不要求
非零 group mask。完成精确资源译码后必须按 `dispatch_class` 分流，不能把所有
canonical uop 都交给 group-mask dispatcher，否则合法的 controller-local 命令会被
空 mask 规则误判。

其中 capability、source/destination 和资源需求必须由 opcode、modifier 与显式
writeback choice 共同派生，不能让软件另带一份可能与 function 矛盾的资源声明；
target mask 等动态字段来自受信的 resolved sideband，并参与 owner/format 校验。
例如 WADD/WSUB 固定读取
`VRF-A+B+ARF`，MAC 读 ARF 而 MUL 不读，SELECT 额外读取 select MRF，MRF logic
复用两个 MRF 口，slide 需要 boundary 资源；compare、MUL、compact 和 MRF logic
还允许不同形式的双目的写回。cached resource 可以保守多报但不能漏报；canonical
expander 在选中后重新生成 exact resource，并检查 `exact ⊆ resource_may_need` 及
class/response 一致性。不一致视为内部译码错误，零执行副作用。

静态 format error 也随 entry 保序保存。只有该 entry 到达本 context 队头且 error
completion sink ready 时才能 reject/pop，不能在 enqueue 时旁路退休而越过更老
指令。

所有路径共享的正确性条件是 entry 所有权不能丢失或复制：它要么仍在 FIFO，要么
已经原子转移到被 scoreboard 跟踪的 reserved issue stage；只有目标引擎 fire，
或者错误 completion 已经获得存储空间，才算从控制器退休。当前
`simd_issue_dispatch` 已有每 slot 的 `issue_reject_ready_i`；空 mask/owner
error 只在该 credit 有效时产生 `ready + reject`。frontend 把这个
terminal reject 与 queue pop 绑定，错误返回无空间时保持 slot 和队头。

`simd_issue_queue.head_ready_i[queue]` 的具体含义就是最终 dequeue/ownership
release，不是“队头已被 live-select”或 shadow slot 已复制。已实现的
locked-shadow 在 slot claim 时保持它为零，并通过 `queue_claimed`
防止同一队首被两个 slot 重复领取；只在 GROUP_EXEC accept 或有
credit 的 reject 时同时清 slot 并拉高该 queue 的 `head_ready_i`。full queue
会据此允许同拍 pop+push，所以 speculative ready 会直接造成过早释放，
而不仅是性能差异。

同一 context 首版每周期只能提供一个 head，所以不会从同一 FIFO 同时取两条不同
指令。不同 context 的 head 可以被多个 issue slot 同周期选中。

## 7. Decoder 与 canonical expander 的分层 `[候选]`

建议把“译码器”拆成两次解析和两个状态边界，而不是一条只执行一次的线性链：

1. **Admission parse/predecode**：识别格式、检查 reserved/未定义 function 与
   extension/preset 引用，解析少量默认值，派生保守 scheduling metadata；这里只
   判定不依赖动态 owner/ready/data 的错误；
2. **Queue storage**：保存原始 uword、resolved sideband、tag 与 cached metadata，
   静态错误也按 context 顺序等待；
3. **Selected-head canonical expansion**：重新解析被选中的 head，扩展 immediate，
   补齐默认字段，生成 exact RF/resource/class request，并做最终 capability/legality
   检查；owner mismatch、动态资源不足和最终 route/control 错误在此后处理；
4. **Issue hold**：候选终局形态是把 decoded bundle 和
   `context/tag/group_mask` 放入每 slot 的浅 holding register。当前
   frontend 的 opaque shadow 已实现稳定与 claim/pop 契约，但不证明
   canonical expansion 已完成。

`simd_issue_decode_shell` 已实现第 4 项所需的一项 elastic holding：没有组合
fall-through，支持同拍 retire/refill，并在 stall 时保持 raw provenance、class、
resource、canonical payload 与错误字段全部稳定。当前 `hook_*` 由 reference driver
产生；未来 compact decoder 在其前方或内部派生同一组字段即可。该模块的
`in_valid && in_ready` 表示 entry 所有权已经转入 holding。若未来仍让 FIFO 持有
entry 直到 engine/error terminal，则必须另加 claim/captured 门控，不能在旧输出退休
时把仍可见的同一 FIFO head 当作 refill 再捕获一次。

### 与通用 CPU decoder 的差异 `[当前边界]`

两者都会把紧凑编码展开成执行控制，但事务环境不同：

| 通用 CPU decoder 常见职责 | 当前 VSP/SIMD decode 边界 |
|---|---|
| 从 PC/IFetch 指令流识别标量 ALU、branch、load/store | 从 sequencer action/uword 识别 `GROUP_EXEC/MEMORY/EXCHANGE/CONTROLLER` class |
| 产生分支、特权、异常、flush/重启元数据 | 产生 group mask、response kind、exact resource、canonical payload 与 ordered error completion 元数据 |
| 产生供后续 in-order 或 rename/issue/commit 结构消费的 uop、分支与异常元数据 | 以 `context+tag`、原子 multicast、engine fire 和 result lifetime 描述事务所有权 |
| 一条 architectural instruction 可展开成一个或多个 uop，再由后续结构选择执行资源 | 一个 issue slot 的 decoded bundle 可原子广播到多个 SIMD4 group；expander 数量随 slot 而不是 group 增长 |
| 非法指令通常形成 trap/精确异常 | 当前非法 action 零执行副作用并保序产生 command completion，不在 SIMD4 内建立异常系统 |

因此这里的 decoder 更接近 sequencer transaction expander，而不是把 SIMD4 变成
一颗自行取指的 CPU。若未来上层加入 architectural IFetch 或精确异常，那是新的
controller 边界，不会自动落入每个 group decoder。

当前 reference frontend 把 opaque slot 直接接到 group dispatcher，并由该
dispatcher 的 accept/reject 触发 queue pop；所以它只适用于入口已经完成最终
GROUP_EXEC 分类与调度合法性检查的配置。以后接入 selected-head late expander 时，
不能简单把 expander 串在现有 `group_issue_slot` 之后，因为那时 terminal 决策已经
发生。届时需要把边界重排为：

```text
queue / RR / opaque shadow
        -> canonical expander / final legality / class router
        -> selected engine fire or ordered error credit
        -> terminal feedback -> queue pop
```

这是接入 hybrid decoder 的结构工作项，不要求保留当前 reference frontend 的内部
组合方式。

错误 uword 不进入任何执行引擎。它由 queue 消费并产生带原 tag 的 error completion，
与 dispatcher 对空 mask/owner mismatch 的 reject 采用相同退休模型；两者都必须先
获得 completion credit。

合法性保留两道防线：ingress/predecode 检查 format、reserved bits、extension/preset
和静态 capability；canonical expander/transaction wrapper 再检查最终控制。现有
`simd_uop_legal` 只覆盖 op-mode、写回 capability、route 和 narrow-reduce
组合，group 内还分别检查具体 `reduce_op`、route index/slide amount 等控制。
即使上级已经检查，也不删除 group 的统一 illegal side-effect gate。

## 8. Canonical 表示与物理拆分 `[候选]`

“canonical decoded uop”是逻辑语义，不要求把所有字段永久绑成一根超宽总线。
建议物理上拆成：

| 表示 | 去向 | 主要内容 |
|---|---|---|
| `queue_entry` | per-context FIFO | compact uword、tag、resolved sideband |
| `sched_meta` | scheduler/resource arbiter | dispatch/response class、粗粒度 RF 使用、may-need resource、serialize、static error |
| `group_uop` | 被选择的 SIMD4 | op/mode、RF 地址、expanded immediate、mask/writeback、route/reduce |
| `issue_envelope` | dispatcher/wrapper | context、tag、response kind；group mask 在 dispatcher 终止 |

每个 group 通过 `group_issue_slot` 已经知道选择哪个 slot，不需要再接收完整
`target_group_mask`；`shared_resource_mask` 也只到 resource arbiter。transaction
wrapper 消费 `group_uop + issue_envelope`，未来修改 compact encoding 不需要修改
SIMD4。

非 group class 不使用 `group_uop`；它们由各自的 canonical request 表示消费。
`issue_envelope` 中可以保留统一的 context/tag/error/retire 信息，使各引擎仍遵守
相同的 queue-pop 与 completion 规则。

`RF_FILL` 等数据动作与算术操作可以共用 sequencer program/uword 空间，但以
`MEMORY` major class 分流，不加入 `simd_op_e`。queue 只保存 descriptor reference、
目标摘要和依赖，不保存 bulk data。parent/child beat、DMA width、local SRAM、
packetizer 和完成聚合统一归入[数据准备与 DMA 边界](data-movement.md)，不在译码页
继续展开。
MEMORY descriptor 中的 effective address、address-space kind 和 opaque address
context 不是 MMU 或 virtual-address 实现证明；当前只将它们传到
`dmem_req/rsp` 逻辑口。

未使用的 `group_uop` 字段由 expander 规范成零。它仍保留 6-bit `op`，并不是把
每个门级控制都展开成 one-hot。`simd_datapath/simd_exec` 仍负责执行功能选择；
上级 expander 负责的
是格式解析、立即数扩展、默认字段、资源分类和非法组合检查。

## 9. 关于指令字 `[开放问题]`

当前没有已定义的 32-bit 或 16-bit instruction。内部信号
`op_i`/`exec_op_i` 携带的 6-bit `simd_op_e` 只是 canonical
`GROUP_EXEC` 的 function，不是完整 opcode。应分开三层：

1. major dispatch class：`GROUP_EXEC/MEMORY/EXCHANGE/CONTROLLER`；
2. 尚未定义编码的 compact uword；
3. 已展开 canonical GROUP_EXEC 中的 `simd_op_e` function。

queue 参数的 32-bit payload、16-bit resolved 和 16-bit sched-meta
只是 opaque 默认宽度，不是格式合同。一个常用本地 ALU uword 也许可以压进
32 bit，但以下内容很
容易超过基础字：

- 完整 32-bit scalar immediate；
- 较大的 `target_group_mask`；
- Bênes raw route control 和大规模 mask；基础字只需保留 route-register/sideband
  引用，具体位域仍开放；
- memory descriptor 引用或短地址操作数；完整 DMA/二维描述符不要求塞进基础字；
- 多个寄存器域、tag 与 barrier 信息。

较自然的方向是“32-bit 常用基础字 + extension/control state/sideband”，或者
内部采用更宽的 microcode word。选择依据应来自常用内核的 code density、decoder
时序和 queue 面积测量。

## 10. Multicast、tag 与退休 `[RTL 事实 + 暂行集成]`

已实现的 `simd_group_completion_tracker` 默认为
`4 group / 2 alloc slot / 2 context / 4 entry`。一条 queue entry 只有一个
command tag。若 `target_group_mask` 含 `k` 个 group，
dispatcher 原子 fire 后生成 `k` 个内部 group 子事务；每个子返回携带相同的
`context_id + tag` 和各自的 `group_id`。`simd_cluster_exec_shell` 已在 dispatch 原子
accept 的同拍提交 tracker entry：`alloc_valid/ready` 只表示候选和
credit，只有与同拍 group issue fire 对应的 `alloc_commit` 写表。保存：

```text
key = context_id + tag
pending_group_mask = accepted_group_mask
expected_result_mask = accepted_result_mask
```

每个无重复的 group completion 清除一位；多 group 可乱序、同拍到达，
illegal 按 group mask 聚合。pending mask 清零产生一条无数据、可背压的
command completion；多 entry 以 RR 选择，stall 时保持稳定。带 payload
的 reduction/count 仍按 group 形成 result record；expected result mask
独立跟踪，command completion 可先报告，但只在 result collector 发出
全部 retire pulse 后才释放 entry/tag。
dispatch 前的 format/empty-mask/owner error 尚未产生 group 子事务，只生成一个
command-level error completion。

需要区分两种生命周期：barrier/quiesce 等待的是内部 `pending_group_mask`、DMA 和
exchange inflight 清零，不必等待外部读取已经缓冲的 response；tag 在所有对应
result/completion record 被 cluster 内部的可靠 buffer 接管前不能复用。接管后的
外部 stall 由该 buffer 承担；若未来改变返回层次或引入更大的内部唯一序号，可重新
定义这一退休边界。
completion 容量核算也不能只按“一条 queue entry 一格”处理：multicast 最坏需要
`popcount(mask)` 个 group result slot，另加可选的 command status。
当前 tracker 满表会对 allocation 背压；live context+tag 也是普通 allocation
dependency，而不是 protocol fault。unknown/wrong/duplicate/mismatch 返回被消费并
置 sticky protocol error。tracker 已与 frontend/wrappers 组成 exec shell，result
collector 在捕获 wrapper response 时产生 retire pulse，并用自己的输出寄存器承接
后续外部背压。
`has_result` 与 allocation mask 不一致时，tracker 依 child 实际回报修正
effective result mask，同时聚合 illegal 并置 sticky；早到的 result retire
也会被对账，不会永久占用 tag。

可替代模型包括每 group subtag、tag generation ID，或引擎内部聚合后只返回一个
command record。决定点不是文档重复次数，而是 response 带宽、tag 生命周期和
barrier 语义的实测复杂度。

## 11. 当前工作建议 `[候选摘要]`

- 控制存储和深 per-queue FIFO：候选上保存紧凑 encoded uword、resolved sideband 与
  硬件派生的 cached `sched_meta`；
- issue slot 前：完整展开成 decoded canonical bundle；
- 当前每个 issue slot：已有 FIFO head 的 opaque locked shadow，以及独立
  `simd_issue_decode_shell` 所验证的 decoded holding 结构；尚需真实 canonical
  expander 把 raw/resolved/cached entry 唯一变成 hook 输出；
- 接入 late expander 时：先把当前 frontend 的 terminal/pop 从内部 group dispatch
  解耦，改由 expander 后的目标 engine 或 ordered error sink 回传；
- expander 后：按 `dispatch_class` 分流，group dispatcher 只接收确实需要 group 的
  指令；
- entry ownership：接入时保持一种一致模型。可以在 decode-shell input fire 时把
  所有权转入 holding，同时继续阻止同 context 越过该 entry；也可以让 FIFO 保持
  owner 到目标路径 terminal，但必须用 captured/claim 状态禁止重复捕获同一 head。
  当前 frontend 的 opaque shadow 属于后一种，独立 decode shell 的 ready/valid 端口
  属于前一种，二者尚未直接串接；
- `simd_datapath`：继续只看展开控制，不加入取指或编码解析；
- 当前 RTL：已有 legality、decoded group wrapper、GROUP_EXEC frontend、completion
  tracker、decode holding shell，以及闭合 queue/dispatch/ingress/wrapper/
  result/reject 的 `simd_cluster_exec_shell`；
- 当前仍没有真实 predecoder/canonical expander、class router、owner
  state、barrier/controller 或 host completion；独立 VRF-only
  `vsp_vrf_span_engine` 已有 RTL，但未接入该控制路径；
- 最终 instruction width 和字段分配继续延期。

本页的 queue/control-store 交付是 controller 内部 uword 路径，不是
architectural IFetch。未来若需要 IFetch，它是与 `dmem_req/rsp` 分开的
逻辑请求类和流控边界；当前没有 IFetch、I-cache、MMU 或精确异常重启。
