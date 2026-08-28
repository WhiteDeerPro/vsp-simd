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
- Gaussian、SAD 与 low-32 byte-convolution 参考负载；
- 共享 operation/mode/writeback/reduce/route legality 检查；
- 非法 reduction 的整事务零副作用门控；
- 多 issue slot 的 owner 检查、原子 group-mask dispatch、backpressure、冲突和
  错误 reject；
- 单 admission lane、per-context 有序 FIFO、并行 context head、非二次幂参数和
  full+pop+push 零气泡替换的 issue queue；
- 默认 `4 group / 2 queue / 2 slot` 的 GROUP_EXEC issue frontend：RR
  live-head、opaque locked shadow、explicit reject credit、terminal pop 与 atomic
  group dispatch；
- 单 SIMD4 transaction wrapper：decoded EXEC/state-write/VRF state-read 仲裁、
  `context+tag`、独立 child completion/response elastic buffer、masked state write、
  无执行副作用的 VRF row read 与窄结果导出；
- 默认 `4 group / 2 alloc slot / 2 context / 4 entry` 的独立 GROUP_EXEC
  completion tracker：乱序/同拍 child 聚合、illegal mask、RR 可背压
  command completion、独立 expected-result 生命期与 protocol-error sticky；
- 默认 `4 group / 2 context / 2 slot` 的 GROUP_EXEC cluster exec shell：
  slot-specific tracker/resource gate、原子 ingress multicast、四个 group wrapper、
  buffered reject completion、state-read/write child lane 与 RR result collector；
- 每 issue slot 一项的 decode holding shell：raw/resolved/cached provenance 与
  canonical class/resource/payload 输出在背压下保持稳定；真实 compact decoder
  仍是可替换 hook；
- 独立 VRF-only `vsp_vector_memory_engine`：single active parent/single
  outstanding memory beat、稀疏 group-mask 连续 beat 映射、LOAD/STORE 子事务与
  stop-on-first partial completion；
- `simd_cluster_exec_shell` 的 group-addressed VRF state-read/write child 路径，以及
  `vsp_cluster_vrf_arbiter` 的多 client read/write 仲裁和返回归属保持；
- `vsp_cluster_memory_shell` decoded reference integration：vector memory engine 经 shared
  VRF arbiter 接入四组 cluster，端到端 LOAD→GROUP_EXEC→STORE 回归已通过；
- 全量 lint/test 基线。

当前优先级转向 decoder/class router、跨 class 顺序、owner/resource controller 与
跨组 lane gather 网络；物理 memory hierarchy 仍在 `dmem_*` 逻辑边界之外。在出现
新的阻塞负载证据前，暂缓增加 lane arithmetic feature。

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

## M2：四组、双发射 cluster shell `[已实现参考]`

先用 `4 × SIMD4`、两个 issue slot 建立可检查的集成配置：

`simd_cluster_exec_shell` 采用 full-decoded reference admission，并已把 frontend、
tracker、四个 group wrapper 和 result/reject 返回路径组成事务闭环。它没有因此
定义最终 instruction encoding，也不等同于有状态 controller。

- 使用已验证的 atomic dispatcher；
- canonical execution bundle 按 `group_issue_slot` 选择并原子写入每个目标 group 的
  单项 ingress buffer；group 随后可独立被 wrapper 接受，不会产生 partial multicast；
- 首版 owner table 可先作为配置输入，随后状态化；
- owner table 与 slot-specific exact-resource grant 当前仍由外部提供；tracker credit、
  ingress credit 和 reject credit 在 shell 内闭合；
- 只把 `GROUP_EXEC` 送入 group dispatcher；barrier/admin 等无 group 操作走独立
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
  GROUP_EXEC tracker；
- empty-mask/owner reject 先进入有容量的 buffer，再与执行 completion 合并输出；
- 相邻 slide 先从 boundary staging/ingress 读取，不隐式读取另一个正在执行的
  group RF。

当前集成验收已覆盖：四组 ADD 广播、state-write 初始化、state-read 返回、
PASS_A 窄导出、结果
backpressure 与 tag 延寿、两条不同 context 的不相交双发射、empty mask、owner
mismatch、endpoint illegal、state completion 竞争下的背压稳定、无 partial group
fire、单 tracker entry 下未获 grant 的 slot 不虚占 credit，以及最终 tracker 清空。独立
frontend/dispatcher/tracker 随机测试继续覆盖 mask overlap、表满和多返回乱序。

## M3：有状态 controller `[decode holding 与 GROUP_EXEC shell 已实现，状态控制待接入]`

- `owner_valid + owner_id` table；
- `simd_issue_queue` 已实现每 context FIFO：一个 admission 入口、所有 context
  并行队头、独立出队和 occupancy；它不解释 entry 位域；
- frontend 已实现 round-robin live-head 选择、每 slot opaque locked shadow、
  group-mask 冲突避让和 terminal pop；
- `simd_issue_decode_shell` 已实现每 issue slot 的 decoded holding、provenance、
  class/response/resource/canonical 元数据与同拍 retire/refill；待实现 compact uword
  admission predecode 和替换当前 `hook_*` 的真实 canonical expander；替代方案和字段
  分层见[指令交付](instruction-delivery.md)；
- 接入 late expander 时，把 reference frontend 当前内部的 dispatch terminal/pop
  改为 expander/最终合法性/class routing 之后回传，避免 opaque entry 被提前退休；
- 待增加 resource-aware scheduling、class router 和 exact shared-resource
  arbitration；
- entry 留在 FIFO，或原子转移到被 inflight 跟踪的 issue stage；成功 fire 或带容量
  的错误 completion 才从控制器退休；
- context-scoped `QUIESCE(mask)`；
- 以已有 tracker 的 context/tag busy 与 execution-pending 为 GROUP_EXEC
  记账基础；再合并 MEMORY/controller inflight；
- quiescent 后 ownership 转移，转移不自动清 RF；
- barrier 等待内部事务和 DMA 完成，但不等待外部把 response FIFO
  读空。

验收：长时间随机 queue/ready/owner 序列无饥饿、无部分 multicast、无 tag
丢失；验证 dispatch/tracker commit 与 group fire 原子对齐、pending-group-mask
聚合、`has_result` mismatch 自修正与早到 result retire 对账、result retire
之前 tag 不重用；barrier
ack 时目标 inflight 必须为零。

## M4：blocking 数据供应闭环 `[decoded reference closure 已实现]`

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
- 已实现 `vsp_cluster_memory_shell`，把 vector memory engine 经该 service 接到四组 exec
  shell。它暴露彼此独立的 decoded GROUP_EXEC 与 MEMORY command 入口，尚无
  common class router、program-order enforcement、owner/resource controller；
- queue 仍只保存 descriptor/metadata，真实 transfer data 走 child/data path；
- `dmem_req/rsp` 保持无 ID 的单飞行有序 data-memory 逻辑口；
  fault cause/eaddr 返回 parent completion；当前没有 MMU、TLB、PTW、
  cache、物理 local SRAM RTL、DMA、一致性或乱序执行；

独立 vector memory engine 验收已覆盖 LOAD/STORE 顺序、背压、tail、稀疏 mask、
错误与 partial 记账。集成 testbench 在 `dmem_*` 外提供 local-memory model，
顺序执行 LOAD → ADD-immediate GROUP_EXEC → STORE；117 项检查覆盖四组结果、
请求背压、parent completion 与 protocol-error。该测试证明 decoded wiring 闭环，
不证明硬件 local SRAM、最终 MEMORY ISA 或跨 class 自动排序已经完成。

## M5：跨组 lane gather `[语义已收束，RTL 待实现]`

本阶段目标是把跨 lane 路由做成 Vector ALU 内的一级，而不是独立 command class：

```text
ROUTE SR, IR, DR
DR[lane] = SR[IR[lane]]
```

- 索引向量 `IR` 来自 VRF，可以是运行时计算结果，不是指令立即数；
- 一个 lane 是 8-bit，索引占一个 lane，单条 gather 寻址上界 256 lane；
- 只做 gather：允许一对一置换与广播，不支持 scatter。同一操作内不会出现多个源
  竞争写同一目的，因此不需要 conflict-detection CAM、写归约或串行化重排；
- 组内 4×4 crossbar（`simd_crossbar`/`simd_route`）已实现并验证；
- 跨组网络候选为 multicast Omega：`log2(N)` 级、每级 `N/2` 个 2×2 switch，
  switch 支持 straight/cross/broadcast，控制位可由索引位模式经组合逻辑直接派生；
- 残余 blocking 由硬件给出 conflict flag，交由软件多 pass；
- 超出单条 gather 范围的向量由 sequencer 拆成多次操作，原地重叠需要
  scratch/ping-pong 或编译器 cycle decomposition。

为何不用 Bênes：它是双射，不支持广播；且控制位需要 O(N log N) 串行求解，无法从
运行时索引向量实时派生。理由与拓扑对比见[路由](../architecture/routing.md)。

负载依据来自 FFT/小波：butterfly 的 stride 跨过 group 边界时（16 lane 下
stride=4）需要跨组交换，若只有组内 crossbar，这些 stage 会退化成
STORE→重排寻址→LOAD 的内存往返。

本阶段待实现：Omega 网络 datapath、索引到控制位的 routing logic、在 Vector ALU
内的接线与资源仲裁。`benes_network` 作为置换网络研究模块保留，不接入数据通路。

验收：随机四路 row permutation 上 data/byte mask 同步且 token 守恒；验证
identity、route 与 inverse 恢复、partial mask、随机 backpressure，以及用
多 pass + local route 完成 WORD byte-plane 分发和重组。任何单 pass 都不得复制
一个活动输入 packet。

随后扩展规模：

- 当前 engine 只接受 `GROUP_COUNT>=2` 的二次幂；以后增加 padding wrapper 后，再用
  六个 SIMD4 测试八端口网络及两个 invalid dummy endpoint；
- 比较更大 group 数下的组合、流水和分级实现，但保持相同的 row-packet/pass 语义；
- 通过真实交换 trace 测量 route reuse、pass 数、scratch 占用和全局链路线长；
- 在 M4 vector memory engine 下游增加 DMA/地址空间 adapter，再评估二维地址状态；
- 非一致性 accelerator 作为首个 SoC 集成候选；CPU cache coherence 是否需要由
  系统边界决定，不在 group 内预设。

## M6：负载闭环与可选加速 `[比较集合]`

当前准备比较：

1. 多组 Gaussian 与 SAD 并行；
2. NSLICE + WADD/WSUB 组成的完整乘积求和；
3. 可发射的 PMAC8/对角线卷积方案是否值得进入 RTL；
4. 拟浮点双流。

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
parse/canonical expander 属于 controller，不等同于让 SIMD4 成为自行取指的 CPU。
