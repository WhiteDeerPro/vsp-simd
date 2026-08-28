# SIMD4 集群控制工作稿

本页并列记录已实现的 GROUP_EXEC frontend/dispatcher/exec-shell 行为、事务正确性
条件和后续 controller 候选。
它不是一份整体生效的最终规格；各节状态分别标注。

## 1. 当前 group profile `[里程碑基线]`

当前控制实验以一个 SIMD4 group 为调度颗粒：

```text
4 × 8-bit physical byte lanes
VRF row = 4 × 8 bit
ARF row = 4 × 32 bit accumulator
MRF row = 4 × 1 bit
```

BYTE/HALF/WORD 是同一个 SIMD4 内的 `4×8 / 2×16 / 1×32` 动态解释，不把
多个 SIMD4 隐式拼成更宽的算术单元。参数化 RTL 可以继续帮助验证网络结构，
当前集群控制模型不依赖大于四 lane 的 group；后续若出现明确负载证据，可以重新
比较其他颗粒。

## 2. 四个不同的数量 `[概念模型]`

- `GROUP_COUNT`：集群包含多少个 SIMD4；
- `CONTEXT_COUNT`：可保存多少条独立控制流的状态；
- `QUEUE_COUNT`：能排队多少条独立微操作流；
- `ISSUE_SLOTS`：一个周期最多发射多少条不同微操作。

一个发射槽可以通过 `group_mask` 把同一条微操作同时交付多个 group，所以
“激活了多少个 group”不等于“发射了多少条不同微操作”。队列数量也可以大于
物理发射槽数量，由仲裁器分时选择。

首版每个 context 每周期最多出现在一个 issue slot；同一 context 的队列严格
FIFO。若以后需要同一任务内的多条独立流，应显式增加 stream/queue 身份，而不是
让较年轻 uop 绕过未接受的同 context 队头。

## 3. 发射单元数量 `[性能假说]`

发射数量不是功能正确性的条件。一个槽理论上可以广播控制所有 group；以下范围
是保证阵列增大后仍逐渐提高混合任务能力的实现 profile。

下文记 `G = GROUP_COUNT`、`C = CONTEXT_COUNT`。

对数建议下界：

\[
I_{log}(G)=
\begin{cases}
1,&G=1\\
1+\lceil\log_4G\rceil,&G>1
\end{cases}
\]

线性建议上界：

\[
I_{linear}(G)=
\begin{cases}
1,&G=1\\
1+\lceil G/4\rceil,&G>1
\end{cases}
\]

在“每 context 每周期只提供一个队头、每个 group 每周期至多接受一条操作”的
基线下，非冗余的 group-execution 配置上界是：

\[
1\le ISSUE\_SLOTS\le\min(C,G)
\]

这里只是有效实现范围，不是 dispatcher 的功能正确性断言。当前 RTL 只要求三个
计数参数为正；`ISSUE_SLOTS > min(C,G)` 仍可工作，只是多出的 group-dispatch slot
不可能同周期都做有用且互不重叠的发射。以后若同一 issue fabric 同时服务
controller-local、DMA 等非 group class，应分别按各引擎带宽核算，不能机械套用
这个上界。

自然的对数分桶是 `1→1、2..4→2、5..16→3、17..64→4`。SystemVerilog
没有 `$clog4`；正整数参数可用 `ceil(log4(G)) = ($clog2(G)+1)/2` 计算。
平衡配置的目标值为：

\[
I_{balanced}=\min(C,G,I_{log}(G))
\]

只有当 `C>=I_log(G)` 时，才存在建议的吞吐配置区间
`I_log(G)..min(C,G,I_linear(G))`。context 数较少或面积优先的实现仍完全合法，
不能因低于对数 profile 而触发 RTL 错误。

## 4. Group 所有权 `[候选控制模型]`

每个 group 保存 `owner_valid + owner_context`。普通发射只有在请求 mask 内的全部 group
都属于发射 context 时才合法。所有权在一个 kernel phase 内保持稳定，只能在：

1. 旧 context 不再发出涉及这些 group 的操作；
2. 所有相关多周期操作和返回结果已经退休；
3. cluster barrier 已经完成；

之后重新配置。所有权变化不是每周期调度动作。

## 5. 原子 multicast 与 backpressure `[RTL事实 + 正确性约束]`

一条带多个 group 的微操作必须全有或全无地接受：

```text
accept = valid
       && group_mask != 0
       && every requested group is owned by context
       && every requested group is ready
       && this slot's shared resources are ready
       && no accepted higher-priority slot overlaps the mask
```

禁止只让 mask 的一部分 group 前进，否则各 group 的微码位置会发生分裂。
同周期 mask 重叠时使用确定性的低槽号优先；失败槽保持有效并在以后重试。

空 mask、无有效 owner 或 owner 不匹配不是可重试的资源等待。dispatcher 禁止
所有 group 状态写入，并只在对应 `issue_reject_ready_i` 有效时给出
`ready + reject`。frontend 只把有 credit 的 reject 视为 terminal，并在同拍
pop 对应 queue head；无错误返回空间时必须保持 slot 和队头。

`group_ready` 表示 group-local 条件已满足。以下任一局部冲突都必须令
相应 group 不 ready：

- 本地多周期执行级或尚未退休的写回；
- 配置、DMA 或跨组 gather 占用目标寄存器文件写口；
- 物理化后无法在本周期提供的 RF bank/operand；
- 该操作所需的返回队列没有空间。

跨组 gather 网络、单实例 scalar-return 口、completion tracker 表项等共享资源是
slot-specific 的：两条 mask 不相交的操作也可能竞争它们。上层 scheduler
先按 uop 派生需求并完成仲裁，再通过每 slot 的 `slot_resource_ready_i`
将获胜结果送入 dispatcher。该信号与 queue pop、tracker allocation 和全部
目标 group fire 同拍 commit；不能只用一份与 slot 无关的 `group_ready`
表达全部共享资源。将它置为全 1 时与原有只检查 group 的行为相同。
对 malformed request，该信号不参与 reject；reject 仍只由对应的 error
credit 决定，且不会产生 group fire。

因此现有 `cfg_*` 写优先行为不能在 cluster 中静默吞掉一条已经接受的执行写；
外层控制器必须在接受前把这种冲突转换成 backpressure。

## 6. 跨组操作 `[语义已收束，RTL 待实现]`

普通逐元素操作只占用目的 group。涉及边界或跨组路由时还需要声明更大的资源集合：

- 相邻 `SLIDE` 必须同时拥有并读取提供边界值的相邻 group，或者明确选择来自
  ingress/zero 的边界；
- 跨组 gather 是 cluster 操作，源和目的 group 的并集在该事务期间被占用；
- 跨组路由采用独立阶段和显式写回，不无条件串入普通 ALU 组合路径。

跨组路由不再是与 MEMORY 并列的独立 command class，也不再以 row packet 为颗粒。
语义收束为寄存器形式的 lane gather：

```text
DR[lane] = SR[IR[lane]]
```

索引向量 `IR` 由 VRF 提供，允许一对一置换与广播，不支持 scatter；同一条操作内
不会出现多个源竞争写同一目的。因此调度只需两个 mask：

```text
src_group_mask       本次 gather 读取的源 group
dst_group_mask       写入的目的 group
resource_group_mask  src_group_mask | dst_group_mask
```

cluster scheduler 需在 action 原子接受前解析三者以完成资源预留。网络拓扑选择
（候选为支持 broadcast 的 Omega 网络）、索引到控制位的派生以及为何不用 Bênes，
统一记录在[路由](../architecture/routing.md)，本页不重复。

超出单条 gather 寻址范围的逻辑向量由 sequencer 拆成多次操作；多次操作不提供整个
向量的原地原子性，源/目的重叠时需要 scratch/ping-pong 或编译器 cycle
decomposition。

ARF 的一个 row 是四个 32-bit accumulator，而不是单个 32-bit word。若未来把
ARF 暴露到跨组路由，需要同时定义 packetizer：选择哪个 accumulator lane、哪些
byte plane 以及如何写回。当前候选不增加 ARF 读口：VRF 源用 `PASS_A`、ARF 源用
`NSLICE`，不做本地写回，直接在 group 的窄结果出口捕获 32-bit row 和 byte mask，
进入 staging 后再写目的 VRF。这样支持"ARF slice 不先落本组 VRF 就外发"，同时
避免形成 `RF→ALU→网络→RF` 的单拍长组合链。

## 7. Operation legality `[RTL事实]`

`elem_mode`、写回类别、route 与 reduction 不是任意正交组合。共享的
`simd_uop_legal` 已按以下基线检查，非法组合整条事务零副作用：

| 操作族 | mode | 合法写回 | route-A | narrow reduce |
|---|---|---|---|---|
| ADD/SUB、MIN/MAX、SHIFT | B/H/W | VRF | 是 | 仅 B |
| CMPEQ/CMPGT | B/H/W | VRF 和/或 MRF | 是 | 否 |
| AND/OR/XOR、PASS、SELECT | B/H/W | VRF | 是 | 仅 B |
| SAT、AVG、ABSDIFF、ABS | B | VRF | 是 | 是 |
| MUL/MAC | B | VRF 低 8 和/或 ARF | 是 | 低 8 结果 |
| WIDEN | B | ARF | 是 | 否 |
| WADD/WSUB | B | ARF | 仅 A | 否 |
| RSHIFT_RND | B | ARF | 否 | 否 |
| NSLICE/NCLIP | B | VRF | 否 | 是 |
| COMPRESS/EXPAND | B/H/W | VRF 和/或 MRF | 是 | 仅 B |
| MAND/MOR/MXOR/MNOT | canonical B | VRF 和/或 MRF | 否 | 否 |

HALF/WORD 的普通运算禁止写 ARF，因为当前 `wide_o` 是各 physical byte 结果分别
零扩展，不是一个 16/32-bit 逻辑元素。reduction 同样只读取 physical byte
结果；完整宽值求和继续使用 NSLICE 与宽累加微码显式组成。

## 8. 返回与同步 `[RTL 事实 + 暂行集成]`

正常进入 group 的 `reduction value/index`、`compact count` 等 group response
至少携带：

```text
context_id + group_id + operation/tag
```

由 DMA/local-memory 等独立引擎产生的 response 不强制带 `group_id`，至少携带：

```text
context_id + tag + engine/transaction_id
```

若某个 memory transaction 自身面向特定 group，可以附带 group/group-mask；这不是
所有 memory response 的共同字段。

dispatch 前发现的空 mask、owner mismatch、format/legality error 没有唯一
`group_id`，它们的 completion 使用：

```text
context_id + tag + error_status + requested_group_mask
```

返回端必须有 valid/ready 或足够深且有容量证明的队列。拟浮点的尾数流和指数流
通过 tag/token 在对齐、合并点同步，不要求两条 sequencer 永久锁步。

已实现的 `simd_group_completion_tracker` 默认为
`4 group / 2 alloc slot / 2 context / 4 entry`。multicast 在 dispatch 边界
原子接受时，`simd_cluster_exec_shell` 同拍提交 `context+tag`、accepted group mask 和
expected result mask。`alloc_valid/ready` 只是候选与 credit；只有
`alloc_commit` 写 entry，且 commit 必须对应同拍 group issue fire，避免
tracker 单独分配。slot-specific `alloc_ready` 已通过 dispatcher 的 resource gate
参与同一次 accept；commit diagnostic 与 entry chooser 分离，避免制造伪组合环。
表满或 context+tag 尚在 live 时会对对应 slot 施加普通 backpressure。

各物理 group 的 child completion 可乱序或同拍到达；每个 pending bit
只清除一次，illegal 按 group mask 聚合。全部 child 收齐后生成一条
无数据、可背压的 command completion，输出 RR 选择并在 stall 时保持稳定。
expected result mask 独立跟踪；command completion 可先被接受，但
entry/tag 必须保持 busy，直到 result collector 捕获所有 expected response 并发出
per-group retire pulse。collector 使用公平 RR 和一个可背压输出寄存器；wrapper
未获选择时继续保持自己的 result buffer，不丢弃同拍多 group response。
unknown tag/context、wrong-group、duplicate child completion 和 result mismatch
都会被消费并置 sticky protocol error。若 child `has_result` 与 allocation
result mask 不同，tracker 以 child 实际回报修正 effective result mask，同时把
command 标记 illegal；已提前观察到的 response retire 也参与对账，
不会因 metadata mismatch 永久泄漏 tag。
dispatch 前 reject 进入一项有容量的 buffer，并与正常 command completion 合并为
同一可背压输出；每周期最多接收一个 reject，其余错误队头继续持有。barrier 等待内部
pending mask 清零，不等待外部读取已缓冲 response。tag 在 collector 尚未安全捕获
全部对应 result 前不得复用；捕获后 record 的保存与外部背压由 collector 承担。
若以后采用 subtag、generation ID 或不同的结果聚合接口，这一模型可以替换。

单 group wrapper 只返回 `context+tag`；tracker 的 child lane 代表物理
`group_id`。exec shell 已处理 GROUP_EXEC child、pre-dispatch reject 和 group result，
并已提供独立的 VRF state-read/write child 边界，但 exec shell 本身仍不处理
host completion、MEMORY parent、owner state 或 barrier。当前 decoded MEMORY
reference integration 位于其外层的 `vsp_cluster_memory_shell`。

## 9. 当前 group wrapper RTL 边界 `[RTL事实]`

`simd_group_wrapper` 已包住一个 `simd_datapath`：

- canonical decoded EXEC、state-write child 与 VRF state-read child 各有
  valid/ready、context 和 tag；
- 每周期三者最多接受一个，完全串行，因而不会触发裸 datapath 的 cfg 静默优先；
- 每个 accepted child transaction 恰好产生一个 tagged group-child completion；
- state-read 另产生独立、可背压的 tagged data response；接受 read 前同时检查
  completion/response buffer credit，非法 read 返回零 data/mask；
- 窄导出、reduction 和 compact count 进入独立 1-entry result buffer；
- result 阻塞时，不需要 result 的事务仍可在 completion 有 credit 时推进；
- VRF 用 `PASS_A` 无本地写回导出，ARF 当前用多次 `NSLICE` 组合导出；
- invalid context/RF file/address、非法 EXEC 和非法窄导出形状均消费请求、零副作用并返回错误。

当前 wrapper RTL 实现的是 VRF-only actor 可使用的单行 VRF state-read/write
child endpoint，而不是 program-level `RF_FILL`。它不属于 `simd_op_e`；metadata
与 write data 在叶端作为一个原子 beat 接受，data 不进入指令队列。
`vsp_vector_memory_engine` 能把一个 VRF-only LOAD/STORE parent 分解为多个 child beat；
当前 MEMORY reference shell 已把这些 child 接到 wrapper。

## 10. 当前 GROUP_EXEC frontend RTL 边界 `[RTL事实]`

`simd_cluster_issue_frontend` 默认参考 profile 为 `4 group / 2 queue / 2
slot`：

- 仅接收已解析、已由可信上游验证的 GROUP_EXEC payload、resolved
  sideband 和 scheduling metadata；
- 集成 `simd_issue_queue`、round-robin live-head 选择、每 slot opaque
  locked shadow、显式 reject credit、terminal pop 和 `simd_issue_dispatch`；
- 当前参考 profile 中 queue identity 同时作为 ownership context；未来多
  stream/context 模型需要显式拆分身份；
- owner 和 group ready 都是外部输入，frontend 不保存 owner table；
- opaque storage 不代表 raw/hybrid/full-decoded adapter 已实现，也不赋予
  payload representation-neutral 的执行语义。

它单独仍不是 cluster shell 或 controller。`simd_cluster_exec_shell` 在其外选择
canonical bundle、原子写入 per-group ingress、实例化 group wrappers，并接入 tracker、
reject buffer 与 result collector；`group_issue_slot_o` 是该 bundle mux 的稳定索引。
owner state、真实 decoder/class router 和 barrier 仍在 shell 之外。

## 11. GROUP_EXEC exec shell RTL 边界 `[RTL事实]`

`simd_cluster_exec_shell` 的首个参考 profile 为 `4 group / 2 context / 2 slot`：

```text
full-decoded GROUP_EXEC admission
          ↓
queue / RR slot / atomic dispatcher
          ↓ accept + tracker alloc_commit
per-group 1-entry EXEC ingress
          ↓
4 × simd_group_wrapper
   ├─ EXEC child completion → command tracker
   ├─ STATE_WRITE child completion → independent state return
   ├─ VRF STATE_READ completion/data → independent state returns
   └─ EXEC response → RR result collector → cluster result
```

- queue 保存 decoder 提供的 exact-resource metadata，并将稳定的 per-slot resource
  request/group mask 暴露给外部仲裁器；tracker credit 与返回 grant 共同进入
  per-slot resource gate；
- 只有已经获得外部 grant、且所有目标 ingress 都可接收的 slot 才参与 tracker
  allocation 预选；未获 grant 的低编号 slot 不会虚占唯一 tracker credit；
- queue pop、tracker commit 和全部目标 ingress 写入在同一 accept 边沿发生；
- ingress 把原子 admission 与各 wrapper 的独立仲裁解耦，后续接入 state-write 不会
  让 multicast 只在部分 group fire；
- result obligation 由共享 `simd_exec_requires_result` 同时供 wrapper 与 tracker
  使用，避免两处形状判断漂移；
- 可信、带 group ID 的 VRF state-read 与 state-write child lane允许外部 actor 接入
  真实 RF data path；这些返回与 GROUP_EXEC tracker 精确分流；
- 多 group 的 state-write completion、state-read completion 和 state-read data
  response 分别由 RR 选择；一旦输出在背压下可见，所选 group 会锁定到握手完成，
  metadata/data 不会在 `valid && !ready` 时跳变；
- 当前 canonical bundle 在 shell 入口已完全展开，内部私有 packed layout 不是
  encoded instruction format；
- `context_exec_quiescent` 只表示 tracker 中的 EXEC child 已清空，不包含仍在 queue
  中的命令、state/reject 返回或未来 MEMORY inflight；真正 barrier quiescence 由
  controller 汇总后另行定义。

它还没有 class router、动态 owner table、barrier、MEMORY parent、跨组 gather、
跨 group boundary staging 或 host/OS completion。因此此模块只称 exec shell，
不称 VSP controller。

## 12. 当前 decoded MEMORY integration `[RTL事实 + 里程碑基线]`

`vsp_cluster_vrf_arbiter` 为多个 VRF-only parent client 提供一个共享 cluster child
边界。它以 RR 在 client read/write request lane 间选择，一次只接受一个 child；
read transaction 保持 client owner，直到 completion 与 data response 都各自完成，
write transaction 保持到 completion。这个 owner 只是返回路由状态，不是 group
ownership、scoreboard 或 program-order 状态。

`vsp_cluster_memory_shell` 组合：

```text
decoded MEMORY → vsp_vector_memory_engine ─┐
                                      ├→ shared VRF arbiter
decoded GROUP_EXEC → cluster exec shell┘       ↓
                                      group VRF state-read/write

dmem_* ↔ external data-memory logical boundary
```

`vsp_cluster_memory_shell` 以单个 MEMORY client 使用该 arbiter。GROUP_EXEC 与
MEMORY 各有独立 command/completion 端口，没有 common class router、统一
error/completion mux 或 program-order enforcement。reference test 通过等待 LOAD
completion 后提交 GROUP_EXEC、再等待其 completion 后提交 STORE 来建立顺序；shell
不会从两个入口自行推导数据依赖。

arbiter 的 `CLIENT_COUNT` 仍是参数，多 client 仲裁已由其单元测试覆盖，为以后并接
其他 VRF-only actor 留出边界；当前 cluster 集成只挂一个 client。跨组 gather 不使用
这条边界：它是 Vector ALU 内的一级，不作为独立 parent actor 竞争 group VRF 端点。

owner snapshot 仍由外部输入，GROUP_EXEC resource grant 在此参考壳中固定为全可用；
动态 owner/resource controller、barrier 与跨 class quiescence 尚未实现。`dmem_*`
是 effective-address 逻辑边界；testbench 的 local-memory model 不等于物理 local
SRAM RTL，也不包含 cache、MMU/TLB/PTW、DMA 或 coherence。当前 117 项端到端检查
只支持“decoded LOAD→GROUP_EXEC→STORE 接线可工作”的声明，不定义最终 ISA。

## 13. 当前 dispatcher RTL 边界 `[RTL事实]`

`simd_issue_dispatch` 只实现以下组合策略：

- context/group 所有权检查；
- 错误命令的无副作用 reject；
- 多 group 原子接受；
- group ready 聚合；
- 重叠 mask 的固定优先级；
- 每个 group 选择被接受的 issue slot；
- 空 mask、所有权错误、backpressure 和冲突诊断。

它只分发槽号，不携带完整操作 bundle，也不保存 owner table。这使控制策略能够
先被穷举验证，而不预先规定指令格式或 sequencer 状态组织。

## 14. 后续实验顺序 `[计划]`

1. 在已有 decode holding shell 的 `hook_*` 位置实现 compact-uword predecode 与
   canonical expander，并把当前 full-decoded admission 重排到 selected-head late
   decode/class-router 边界；terminal/pop 由最终 engine fire 或 error sink 回传；
2. 增加 common class router、program-order/error/completion 汇聚、owner state、
   barrier/quiescent 和 resource-aware scheduling，把当前两个 decoded command
   入口及外部 owner/grant 配置收进有状态 controller；
3. 保留当前 vector-memory→shared VRF arbiter→wrapper 接线，在 `dmem_*` 下游比较并接入
   物理 local SRAM、cache/MMU adapter 或 DMA 边界；
4. 实现跨组 lane gather 网络（候选 Omega）及其索引到控制位的 routing logic，
   作为 Vector ALU 内的一级接入 group wrapper，并用多次 gather + local route
   验证 word 分发和重组；
5. 在 vector memory engine 下游接 DMA/地址空间 adapter，再依据实测比较二维地址
   与多 outstanding，不在
   SIMD group 内处理 cache coherence；
6. 用 Gaussian、SAD、完整乘积求和及拟浮点微码测量队列深度、交换占用和发射
   数量，再决定流水、bank 和专用卷积加速。

逐阶段接口、验收条件和延期项见[开发路线](development-roadmap.md)。
