# VSP/SIMD 集群实验路线

本路线从已经验证的 SIMD4 group 出发，逐层增加事务、集群和 sequencer 控制。
每一阶段都先形成可独立验证的闭环，再把下一层接上；不以最终 ISA 编码、工艺
流水或物理 SRAM 选择阻塞行为架构开发。

> 这里的配置和顺序是当前工作计划，不自动升级为架构决定。阶段数据可以改变
> 后续步骤、并行度或候选拓扑。

## 当前基线：已完成

- SIMD4 的 VRF/ARF/MRF、BYTE/HALF/WORD 动态 ADD/SUB/shift/compare；
- byte 语义的饱和、AVG、ABSDIFF、MUL/MAC 和宽窄操作；
- local route/broadcast/slide、compact/expand、MRF logic、narrow reduction；
- `vsp_lane_gather`：默认 16 lane 的固定全 crossbar 临时基线，动态索引与静态图样
  已验证，未接入数据通路；
- Gaussian、Sobel、Median、SAD 与 low-32 byte-convolution 参考负载；
- 共享 operation/mode/writeback/reduce/route legality 检查；
- 非法 reduction 的整事务零副作用门控；
- 多 issue slot 的 owner 检查、原子 group-mask dispatch、backpressure、冲突和
  错误 reject；
- 单 admission lane、per-context 有序 FIFO、并行 context head、非二次幂参数和
  full+pop+push 零气泡替换的 issue queue；
- 默认 `4 group / 2 queue / 2 slot` 的 EXEC issue frontend：RR
  live-head、opaque locked shadow、explicit reject credit、terminal pop 与 atomic
  group dispatch；
- 单 SIMD4 transaction wrapper：decoded EXEC/state-write/VRF state-read 仲裁、
  `context+tag`、独立 child completion/response elastic buffer、masked state write、
  无执行副作用的 VRF row read 与窄结果导出；
- 默认 `4 group / 2 alloc slot / 2 context / 4 entry` 的独立 EXEC
  completion tracker：乱序/同拍 child 聚合、illegal mask、RR 可背压
  command completion、独立 expected-result 生命期与 protocol-error sticky；
- 默认 `4 group / 2 context / 2 slot` 的 EXEC cluster execution integration：
  slot-specific tracker/resource gate、原子 ingress multicast、四个 group wrapper、
  buffered reject completion、state-read/write child lane 与 RR result collector；
- 每 issue slot 一项的 decode holding stage：raw/resolved/cached provenance 与
  canonical class/resource/payload 输出在背压下保持稳定；
- `vsp_exec_uword_expander`：解析内部 profile v0 的 32-bit base 与可选 immediate
  extension，覆盖当前 EXEC function 与 SIMD4-local route，并对非法 word 进行无副作用
  canonicalization；已接入 strict controller action 入口，尚未接入 queue/head holding；
- `vsp_uword_predecoder`：默认并行扫描 4 个连续 32-bit uword stream word，按结构长度
  划分完整 record、预判 dispatch class，并报告待续接尾 record；当前是无状态组合
  reference，不含 assembler、envelope 或 class-specific semantic decode；
- `vsp_uword_multi_framer`：默认接收 4 个连续 stream word，并以 packed-prefix
  ready/accept 最多交付 3 条 record；两个宽度独立，4 word 不等于 4 record。它支持
  跨 bundle 拼接、同拍 dequeue/refill、EOF truncation，以及按 record 边界发现
  `CONTROL.END` 后的 sticky fetch stop；显式 stream abort 可在 fetch fault 时清掉
  incomplete tail 而不伪造 EOF，且不会撤销已识别 END；
- `vsp_uword_program_frontend` reference：可编程 control-store 行为模型、半开
  `[start_pc,end_pc)` 的线性 byte PC source，以及跨 bundle/EOF 的有状态 record
  assembler；每个 32-bit base/extension/body 地址 `+4`，完整 PC 越界返回 fault；
  当前 control-store/program-source 是 single-outstanding reference，4-word response
  宽度不证明可持续每拍供应 4 words/3 actions；尚未实现真实 I-side SRAM/cache
  pipeline；
- `vsp_ordered_action_window`：默认四项深度、三项 admission、两个 EXEC 候选和一个
  non-EXEC side 候选（含 MEMORY、CONTROL 与 ordered reject）；支持 group-local
  顺序、shared dependency bit、split
  group 子集推进、乱序 child completion 与按序 retirement。四项只是短暂对齐、背压
  和依赖窗口，不是分支预测队列；side 也不是已经实现的 scalar ALU；
- 独立 VRF-only `vsp_vector_memory_engine`：single active parent/single
  outstanding memory beat、稀疏 group-mask 连续 beat 映射、LOAD/STORE 子事务与
  stop-on-first partial completion；
- `vsp_ordered_dmem_model` 仿真 endpoint：byte array、write strobe、地址空间/范围
  fault、固定延迟、四项 FIFO ordered outstanding、满队列同拍替换与 response
  backpressure 已验证；它不是物理 SRAM/cache/MMU；
- `vsp_ordered_ifetch_model` 仿真 endpoint：read-only word backing、byte-PC、最多四 word
  packed response、地址空间/fault、固定延迟和 FIFO ordered outstanding 已验证；它与
  dmem 模型是两个独立逻辑端口，尚未接入 strict program wrapper，也不是 I-cache；
- `vsp_sequencer_state_engine` decoded reference：per-context 32-bit state RF、恒零
  register 0、`SMOVI/SADD/SADDI`、modulo arithmetic、可背压单项 completion 与
  combinational base query 已验证；当前已接 CONTROL/MEMORY uword semantic decode 和
  strict slot-0 program path；
- `simd_cluster_exec` 的 group-addressed VRF state-read/write child 路径，以及
  `vsp_cluster_vrf_arbiter` 的多 client read/write 仲裁和返回归属保持；
- `vsp_cluster_memory_wrapper` decoded reference integration：vector memory engine 经 shared
  VRF arbiter 接入四组 cluster，端到端 LOAD→EXEC→STORE 回归已通过；
- `vsp_decoded_action_controller` 与 `vsp_cluster_controller_wrapper`：统一
  `EXEC/MEMORY/CONTROL` 分派、owner/context 检查、严格跨 class 顺序、统一
  completion，以及等待 queue/tracker/memory/arbiter 强静止的 `END`；decoded LOAD →
  profile-v0 encoded EXEC → decoded STORE → CONTROL.END 回归已通过；
- `vsp_uword_action_adapter` 与 `vsp_uword_cluster_program_wrapper`：从 behavioral
  control store 的 byte PC 经 4-word multi-record framing 接到 CONTROL state engine 和
  strict class controller；launch envelope/tag、state base snapshot、encoded
  `VLOAD/VSTORE`、opaque/unknown rejection、EOF/truncated、early/final END、fetch-fault
  abort/restart 和真实 EXEC result 已闭环。定向回归已执行
  `SMOVI/SADD/SADDI → VLOAD → EXEC → VSTORE → END`。该 wrapper 只消费 framer slot 0，
  controller 仍是 global single-active，不能把该 closure 解读为三发射或并发
  state/memory scheduling 已实现；
- 全量 lint/test 基线。

当前优先级转向把 multi-record framer、action envelope、浅层依赖窗口和各 class
engine 组成并发控制链，并补充实际 admission legality/resource/state-dependency
metadata、动态 owner 状态与 sequencer loop/redirect。跨组 route 已从这条执行闭环中
解耦并延期。
物理 memory hierarchy 仍在独立 I-side/D-side 逻辑边界之外；当前只新增了可执行
protocol model，没有实现 I-cache/D-cache。候选分层见
[I-side / D-side 内存模型边界](../architecture/memory-hierarchy.md)。在出现新的阻塞负载证据
前，暂缓增加 lane arithmetic feature。

## M1：SIMD4 transaction wrapper `[已实现参考]`

`simd_group_wrapper` 已在现有 `simd_datapath` 外增加握手层，不修改 lane 算术：

- 已展开 uop 的 `exec_valid/exec_ready`；
- `context_id + tag`；
- `fire` 产生唯一一次 `issue_i`；
- 每周期 EXEC/state-write/state-read 最多接受一个，三者完全串行仲裁；
- 普通 completion 与需要外部观察的 result response 分离；
- narrow export/reduction/count 请求先用 1-entry elastic result buffer 验证协议；
  所有事务另有 completion，其 `illegal` 位不要求额外 result；深度不是架构容量结论；
- state-write endpoint 把 VRF/ARF/MRF masked write 提升为有握手的子事务，并与 EXEC
  在接受前仲裁，不依靠 cfg 的静默优先；
- VRF state-read endpoint 直接读取指定 row，独立返回 tagged completion 与
  data response/byte mask；两条返回可分别背压；
- 导出窄结果的 valid mask，供以后跨组 gather staging 使用；
- 控制状态复位，RF 数据仍不复位。

当前 EXEC 与 state-write 共用一个 1-entry completion buffer；EXEC result、
state-read completion 和 state-read data response 各有一个独立的 1-entry elastic
buffer。state-read 只有在它的两条返回都可写时才接受。EXEC result 被阻塞时，
不需要 result 的 EXEC/state-write 仍可在共享 completion 有 credit 时推进。返回均
携带 context+tag，上层在事务要求的返回被接受前不得复用相同 tag。

验收已经覆盖随机 response backpressure、同周期 pop+push、连续 RAW、
EXEC/state-write/state-read 竞争、VRF/ARF/MRF 写入、VRF row read、窄导出、
reduction/count、非法零副作用和 accepted child 返回守恒。program-level VRF
LOAD/STORE parent 由 `vsp_vector_memory_engine` 处理，并已通过 shared VRF arbiter 接到
wrapper/cluster 参考路径。MEMORY action 与 child 都不属于 `simd_op_e`，真实数据也
不进入指令 FIFO。

## M2：四组、双发射 cluster integration `[已实现参考]`

先用 `4 × SIMD4`、两个 issue slot 建立可检查的集成配置：

`simd_cluster_exec` 采用 full-decoded reference admission，并已把 frontend、
tracker、四个 group wrapper 和 result/reject 返回路径组成事务闭环。它没有因此
定义最终 instruction encoding，也不等同于有状态 controller。

- 使用已验证的 atomic dispatcher；
- canonical execution bundle 按 `group_issue_slot` 选择并原子写入每个目标 group 的
  单项 ingress buffer；group 随后可独立被 wrapper 接受，不会产生 partial multicast；
- 首版 owner table 可先作为配置输入，随后状态化；
- owner table 与 slot-specific exact-resource grant 当前仍由外部提供；tracker credit、
  ingress credit 和 reject credit 在 cluster integration 内闭合；
- 只把 `EXEC` 送入 group dispatcher；barrier/admin 等无 group 操作走独立
  controller-local accept/retire 路径；
- 每个 context 每周期最多占一个 slot；
- dispatch 原子 accept 必须同拍获得 tracker allocation credit；
  `alloc_valid/ready` 仅选候选，与 group issue fire 同拍的 `alloc_commit`
  才写入 `context+tag+accepted_group_mask+expected_result_mask`；
- 每 group tagged completion lane 接入 tracker；RR collector 捕获 group result 时
  产生 retire，command completion 可先于 result，但 entry/tag 保持 busy 直到所有
  expected result 被 collector 安全接管；
- trusted state-write 与 VRF state-read child lane 已接入 wrapper 仲裁；read
  completion/data response 和 write completion 各自独立汇聚，均不进入
  EXEC tracker；
- empty-mask/owner reject 先进入有容量的 buffer，再与执行 completion 合并输出；
- 相邻 slide 先从 boundary staging/ingress 读取，不隐式读取另一个正在执行的
  group RF。

当前集成验收已覆盖：四组 ADD 广播、state-write 初始化、state-read 返回、
PASS_A 窄导出、结果
backpressure 与 tag 延寿、两条不同 context 的不相交双发射、empty mask、owner
mismatch、endpoint illegal、state completion 竞争下的背压稳定、无 partial group
fire、单 tracker entry 下未获 grant 的 slot 不虚占 credit，以及最终 tracker 清空。独立
frontend/dispatcher/tracker 随机测试继续覆盖 mask overlap、表满和多返回乱序。

## M3：有状态 controller `[strict ordered state reference 已实现，并发控制待接入]`

- `owner_valid + owner_id` table；
- `simd_issue_queue` 已实现每 context FIFO：一个 admission 入口、所有 context
  并行队头、独立出队和 occupancy；它不解释 entry 位域；
- frontend 已实现 round-robin live-head 选择、每 slot opaque locked shadow、
  group-mask 冲突避让和 terminal pop；
- `simd_issue_decode_stage` 已实现每 issue slot 的 decoded holding、provenance、
  class/response/resource/canonical 元数据与同拍 retire/refill；EXEC
  expander 已实现并接到 controller action 入口；bundle framing/class predecode、
  byte-PC source、跨 bundle multi-record framer 和 action-envelope adapter 也有
  reference。待实现实际 admission legality/class-resource metadata，并替换当前
  `hook_*` 后接入 queue ownership；字段分层见
  [指令交付](instruction-delivery.md)；
- 独立 `vsp_ordered_action_window` 已验证默认 `3 admit / 2 EXEC + 1 side / 4 depth`：
  group mask 重叠、共享依赖、split/non-split、乱序 completion、按序 retirement 和
  END cutoff。它尚未接到真实 EXEC/MEMORY/CONTROL engine，不能据此声称当前顶层
  已达到三发射；
- strict `vsp_uword_cluster_program_wrapper` 已把 slot-0 record/action adapter 接到现有
  state engine/controller，作为 PC→state/MEMORY/EXEC/END 的可执行保序证明；它与
  上述 action window 仍是两条不同 reference，下一步才是把三项 admission 和实际
  state/shared-resource 依赖 metadata 接到多 engine；
- 接入 late expander 时，把 reference frontend 当前内部的 dispatch terminal/pop
  改为 expander/最终合法性/class routing 之后回传，避免 opaque entry 被提前退休；
- `vsp_decoded_action_controller` 已提供一个全局 single-active 的 class router：
  action 在目标 engine 完成并且统一 completion 被接收前不会让更年轻 action 前进；
  静态 decode/control/owner error 以零子请求的 ordered completion 返回；
- `CONTROL.END` 已实现：等待 EXEC queue、completion/result tracker、MEMORY engine
  和 VRF arbiter 全部静止；它不直接检查外部 result 口是否为空，但有限 collector
  满时，外部背压会阻止剩余 result obligation 退休并间接延迟 END；
- 待增加 resource-aware concurrent scheduling、exact shared-resource arbitration、
  动态 owner table 和 context-scoped quiesce；
- entry 留在 FIFO，或原子转移到被 inflight 跟踪的 issue stage；成功 fire 或带容量
  的错误 completion 才从控制器退休；
- context-scoped `QUIESCE(mask)`；当前 `END` 是整个 reference wrapper 的全局结束动作，
  不替代一般化的 ownership handoff barrier；
- 以已有 tracker 的 context/tag busy 与 execution-pending 为 EXEC
  记账基础；再合并 MEMORY/controller inflight；
- quiescent 后 ownership 转移，转移不自动清 RF；
- barrier 等待内部事务和 DMA 完成，但不等待外部把 response FIFO
  读空。

验收：长时间随机 queue/ready/owner 序列无饥饿、无部分 multicast、无 tag
丢失；验证 dispatch/tracker commit 与 group fire 原子对齐、pending-group-mask
聚合、`has_result` mismatch 自修正与早到 result retire 对账、result retire
之前 tag 不重用；barrier
ack 时目标 inflight 必须为零。

## M4：blocking 数据供应闭环 `[decoded + encoded strict reference 已实现]`

本阶段的候选分层与延期项集中在[数据准备与 DMA 边界](data-movement.md)。

- 已实现 decoupled parent request/completion，命令含 LOAD/STORE、
  exec-context/tag、`LOCAL/PHYSICAL/TRANSLATED` address space、opaque
  address context、base-eaddr+signed offset、group mask、VRF row 和 `span_bytes`；
- `span_bytes` 表示编译器已选择的连续合并 span；独立 command 不会自动合并。
  4-byte 对齐，`ceil(span/4)=popcount(mask)`；稀疏 mask 按 group 升序映射
  连续 beat，最后 beat 仅低 byte 有效；
- LOAD 已实现 memory read → masked VRF state-write → child completion；
  STORE 已实现 VRF read child completion/result 任意序收齐 → memory write → ack；
- 已实现 stop-on-first：completion 返回 requested/completed/failed masks、
  committed bytes 和 partial，已提交的较早 group 不回滚；
- 当前仅 VRF；ARF 先用 `NSLICE/NCLIP` 转换到 VRF 再 STORE，
  MRF 不在此 controller 的数据端点内；
- 已实现 `vsp_cluster_vrf_arbiter`，在 parent clients 与 cluster 的单组 VRF
  state-read/write endpoint 之间仲裁；当前一次只保留一个 child owner，read 等待
  completion 与 response 两者，write 等待 completion；
- 已实现 `vsp_cluster_memory_wrapper`，把 vector memory engine 经 VRF arbiter 接到
  四组 cluster execution integration；它继续暴露彼此独立的 decoded EXEC 与 MEMORY
  command 入口，便于叶级验证；
- 已实现 `vsp_cluster_controller_wrapper`，在上一层接收一个 ordered action stream，
  将 encoded EXEC、decoded MEMORY 与 `CONTROL.END` 统一分派和退休；动态
  owner/resource state、queue-head predecode 和多 active action 仍在后续；
- 已实现 fixed-profile MEMORY uword decoder 与 address-state binding：两 word
  `VLOAD/VSTORE` record 在 admission 时快照 `sbase`，并形成现有 decoded MEMORY
  descriptor；CONTROL decoder 同时把 `SMOVI/SADD/SADDI` 接到 state engine。该 encoded
  closure 仍是 strict slot-0、single-active reference，不等于 concurrent window 或
  高吞吐 sequencer 已完成；
- queue 仍只保存 descriptor/metadata，真实 transfer data 走 child/data path；
- `dmem_req/rsp` 保持无 ID 的单飞行有序 data-memory 逻辑口；
  fault cause/eaddr 返回 parent completion；当前没有 MMU、TLB、PTW、
  cache、物理 local SRAM RTL、DMA、一致性或乱序执行；

独立 vector memory engine 验收已覆盖 LOAD/STORE 顺序、背压、tail、稀疏 mask、
错误与 partial 记账。集成 testbench 在 `dmem_*` 外提供 local-memory model，
顺序执行 LOAD → ADD-immediate EXEC → STORE；117 项检查覆盖四组结果、
请求背压、parent completion 与 protocol-error。更外层 controller 回归以持续提供的
action stream 执行 decoded LOAD → profile-v0 encoded ADD-immediate EXEC → decoded
STORE → CONTROL.END，覆盖自动排序、
统一 completion 背压、owner/decode error 与 memory fault。两者都不证明硬件 local
SRAM、最终 MEMORY ISA 或高吞吐 sequencer 已完成。

program-wrapper 回归另从 assembler 生成的 encoded stream 执行
`SMOVI/SADD/SADDI → VLOAD → ADD-immediate EXEC → VSTORE → END`，在 test-side dmem
responder 上检查 address/context、load/store data、write strobe、request backpressure
和八项有序 completion/tag。它同样不实现物理 SRAM、I-cache、MMU、DMA、loop 或
多 action 并发。

## M5：跨组 route `[固定 crossbar 临时基线已实现；接入仍延期]`

组内 4×4 `simd_crossbar/simd_route` 已由单字 `fmt=0xd` 编码接入 profile v0，并通过
assembler→predecoder→expander→controller→group writeback 回归。profile v0 不编码
跨组 route，当前 controller/cluster 工作也不等待跨组网络。

固定 16×16 byte crossbar 已按该基线实现为 `vsp_lane_gather`：纯 gather、九种 mode
（含动态 GATHER）、rotate wrap 报告，独立验证通过。选它而不是先做动态 Bênes/Omega
route-setting 的理由是成本位置——全 crossbar 无需 route 求解，动态索引不引入控制
状态或冲突协议，代价只是 `O(N²)` mux。它先服务负载映射取证，可被后续方案替换。

仍未定义、因此接入继续延期的部分：index 来源、group-local VRF 的 stripe、
source/destination 资源预留、out-of-range 行为、分级/流水和写回事务。接入时它应
作为可替换的 Vector ALU/cluster data-path stage，不改变 EXEC/MEMORY/CONTROL 的
顺序与完成合同。

`benes_network` 和既有多级网络文档保留为探索材料，不接入当前数据通路，也不作为
decoder/class-router 的前置条件。

## M6：负载闭环与可选加速 `[比较集合]`

当前准备比较：

1. 多组 Gaussian 与 SAD 并行；
2. NSLICE + WADD/WSUB 组成的完整乘积求和；
3. 可发射的 PMAC8/对角线卷积方案是否值得进入 RTL；
4. 拟浮点双流。

已完成一项：两 pass 8-bit 可分离 `[1,2,1]` Gaussian 与精确九 tap 的对比
（[结论](../workloads/gaussian3x3-separable.md)）。它同时给出 HALF 支持的优先级
判断：真正缺的是 HALF 粒度的 `ACC→VRF` 导出，而不是 HALF `MUL/MAC` 或宽域 ABS；
可分离滤波本身不构成增加它们的理由。

拟浮点当前只有 workload mapping 假说：M24 可先以 sign-extended WORD32 保存，
E8 独立打包。当前五位 WORD shifter 会把更大 shift amount 截短，所以若采用这套
映射，指数侧需要在送入前定义 drop/clamp；直接把 `[E8|M24]` 当作普通 WORD 整体
移位与当前数据解释不符。M24×M24 的 48-bit 取值窗口和符号修正也尚未定义，因此
low-32 卷积模型不能充当拟浮点乘法闭环的证据。

## 最后阶段：物理化

代表性负载和 trace 已能给出吞吐需求后，再决定：

- RF bank、复制、operand queue 和 bank-conflict stall；
- 组合读或同步 SRAM；
- pipeline/forwarding/scoreboard；
- FIFO 深度和物理 issue 数；
- 跨组 gather 网络的分级、链路宽度、DMA burst 与局部 buffer 容量。

当前路线不优先处理面向 architectural program 的 fetch/decode、分支、异常、
独立标量 CPU、64-bit SIMD 算术和最终 32-bit 指令编码。M3 的内部 compact-uword
program source/parse/canonical expander 属于 controller，不等同于让 SIMD4 成为自行
取指的 CPU。
