# 验证 harness 与路径漂移

> 状态：验证方法工作稿。它约束我们怎样解释证据，不替代架构讨论，也不要求
> 永久保留任何具体 testbench。

## 1. 能否自动避免自激励？

不能完全避免。harness 可以发现回归、穷举有限状态或比较参考模型，但它通常不会
自行判断以下问题：

- oracle 是否复制了 RTL 的同一个错误假设；
- 已测行为是架构语义、临时实现还是测试便利；
- 更多随机样本是否真的增加了新证据；
- workaround 是否已经推动另一层继续 workaround；
- 一个候选是否值得成为后续设计基础。

因此“测试通过”只应解释为：在列出的假设、输入域和 oracle 下，没有观察到不一致。
它不等于“当前路线最优”，也不自动让候选方案成为架构决定。

## 2. 文档、RTL 与测试的关系

建议维持下面的证据方向：

```text
问题 / workload
      ↓
候选与可证伪条件
      ↓
明确的行为 claim
      ↓
尽量独立的 oracle / invariant
      ↓
testbench 检查 RTL
```

RTL 是当前实现，testbench 是证据，设计文档表达意图。三者冲突时，不由其中任一
层自动胜出；应把冲突判断为以下一种并修正对应层：

- RTL defect；
- stale/同构 oracle；
- 文档歧义；
- 有意的架构变化；
- 尚无足够证据的开放问题。

特别地，不再使用“RTL 与现有测试天然定义未来架构”的优先级。

## 3. 当前 harness 分类

| 类别 | 当前入口 | 能支持的声明 | 不能支持的声明 |
|---|---|---|---|
| 数值/操作语义 | `simd_exec_tb`、`simd_dynamic_alu_tb`、`simd_mask_alu_tb`、`simd_reduce_tb`、`simd_route_tb`、`simd_compact_tb` | 当前运算、mask、route、compact 的有限域语义 | 这些操作或位宽是最终 ISA/PPA 最优解 |
| 集成哨兵 | `simd_datapath_tb` | RF 读写、控制组合、写回和 illegal gate 能协同 | 上层 controller、DMA 或物理 RF 已闭合 |
| EXEC/queue 协议安全 | `simd_group_wrapper_tb`、`simd_group_completion_tracker_tb`、`simd_issue_queue_tb`、`simd_cluster_issue_frontend_tb`、`simd_issue_dispatch_tb`、`simd_issue_decode_stage_tb`、`simd_cluster_result_collector_tb`、`simd_cluster_exec_tb`、`simd_cluster_exec_tracker_credit_tb`、`simd_uop_legal_tb` | 单 group EXEC/state-write/state-read child 守恒、独立返回背压、FIFO 顺序/弹性替换、RR queue claim、opaque/decoded holding 稳定、reject credit、terminal pop、原子 multicast；tracker 的 candidate/commit 分离、乱序/同拍 child、pending/result lifetime、满表背压与 protocol-error sticky；full-decoded EXEC integration 的 ingress/wrapper/tracker/result/reject 及 group-addressed VRF state-read/write 边界 | 仅凭这些 leaf/EXEC 测试声称 compact-uword parser/class router 已接 queue head、有状态 resource scheduler、host completion 或物理 local SRAM/DMA 已连接，或编码和容量选择最优 |
| Uword bundle framing | `vsp_uword_predecoder_tb` | 默认 4-word bundle 中 mixed `EXEC/MEMORY/CONTROL/undefined` record 的结构长度、opaque body、多个完整 record、待续接尾部、undefined-major 一字前进、四种 ROUTE mode 的 `barrier-before/pair-required` scheduling predecode 与 50,000 组独立随机 oracle；8-word 参数 lint | IFetch/PC、跨 bundle assembler、EOF/truncated/epoch、MEMORY/CONTROL semantic decode、action envelope、queue admission/class routing 集成或最终 framing/ISA |
| Uword program delivery | `vsp_uword_asm_tb.py`、`vsp_uword_bundle_assembler_tb`、`vsp_uword_program_frontend_tb` | 工具对 ALU/VRF-indexed `VROUTE`/reduction、`SMOVI/SADD/SADDI` 与 `VLOAD/VSTORE` pseudo-op 的精确编码和非法输入拒绝；非零 byte PC、每 word `+4`、完整地址窗口检查、单 outstanding control-store response、MEMORY/EXEC 跨 bundle、record 背压稳定、EOF 截断、空/非法 stream range、live reset 与 fault，共 783 项 frontend 检查；另有 57 项 bundle 连续性、错误流丢弃和交付检查；40-bit PC/3-word bundle 参数 lint | architectural IFetch/ISA、物理 SRAM/I-cache/MMU、branch/loop/redirect、action window 接线、可持续每拍 4-word/3-action 供给或工具格式长期稳定 |
| Multi-record stream framing | `vsp_uword_multi_framer_tb` | 默认 4-word fetch 与 3-record admission 独立参数化；跨 bundle 四字 record、packed-prefix ready/accept、同拍 dequeue/refill、full stall 稳定、EOF truncation、PC 连续性/不连续输入拒绝、fault/abort 清除不完整 tail，以及 END 超出当前 admission prefix 或与 abort 同时发生时仍保持终止且不误认 opaque body，共 207 项检查；40-bit PC/5-word fetch/2-slot 参数 lint | 4 word 恒等于 4 record；三个对称执行端口；branch prediction/redirect epoch；MEMORY/CONTROL semantic decode；该 framer已接入 resource-aware 三发射顶层或 fetch 宽度已经最优 |
| Ordered action window | `vsp_ordered_action_window_tb` | 默认 4-entry window 的 3-lane admission、2 EXEC view + 1 non-EXEC side view（含 ordered reject）；group overlap、split/non-split child 发射、shared RAW/WAR/WAW metadata、`barrier-before` 等到实际退休但不阻塞无关年轻 action、乱序/同拍 completion、重复/未知 completion 吸收与 sticky 诊断、最多三项 packed-prefix retirement、backpressure、wrap 与 END cutoff，共 139 项检查；它是已验证的顺序依赖表 reference | side view 是 scalar ALU；当前顶层已经三发射；四项深度用于 branch prediction；真实 RF/AGU/memory dependency metadata、per-flow route token/rendezvous、双 completion fan-out、投机、rename、flush 或 concurrent engine integration 已完成 |
| Route rendezvous table | `vsp_route_rendezvous_table_tb` | 3-entry/3-participant 非二次幂配置上，`DEP_IN/DEP_OUT` 按 `{context,epoch,route_id}` 收集，双 role 不同 participant、双 token/payload 保留、单调 frontier 门槛、terminal 背压稳定和 key 占用，越界 context/participant identity、满表背压、ready terminal 连续排出与 RR 跨尾回绕，illegal/同 role/同 participant 冲突 REJECT，冲突 fragment 的 fault identity 保留，exact flush/epoch advance CANCEL、REJECT 优先级和 staged terminal 不受后到 flush 改写，共 121 项检查 | 仅凭该 leaf 测试声称它已连到 predecoder/queue/window/route engine，或声称 frontier 已按 context 维度编号、terminal RR 已保证 architectural retirement order、READY→RUN 资源与双 completion credit 已原子预留、已有 completion fan-out 或顶层 cooperative closure |
| Strict uword program closure | `vsp_uword_cluster_program_wrapper_tb` | behavioral control store → single-outstanding byte-PC source → 4-word multi-framer → slot-0 action adapter 的 global-single-active 闭环；encoded `XOR/ADDI/VROUTE → END` 已能交付 VRF-indexed route 并确认其无隐式 narrow export，另覆盖 `SMOVI/SADD/SADDI → VLOAD → EXEC → VSTORE → END`、resolved base、真实 dmem data/strobe、双向 state/cluster 排序、统一 completion 多拍背压稳定、launch envelope/tag、ordered reject、truncated/empty/missing-END、early/final END 与 fetch-fault abort/restart，共 346 项检查 | 三项 record 已并发发射；ordered action window 已集成；side 是通用 scalar ALU；持续每拍 4-word/3-action 供给、branch/loop、真实 I-cache/MMU 或多 active action 已实现 |
| MEMORY uword semantic decode | `vsp_memory_uword_decoder_tb` | 两词 MEMORY shape、signed-16 canonical offset、state-base query gating，以及物理最大 span 小于编码上限时在任何 width narrowing 前拒绝，共 17 项定向检查 | 当前 fixed profile 是最终 ISA；span/mask、对齐、eaddr overflow 或 dmem fault 已由该组合 decoder 独立处理 |
| VRF span 协议 | `vsp_vector_memory_engine_tb` | single active parent/single outstanding dmem beat 的 LOAD/STORE，exec/address context 分离，address-space/eaddr 传递，4-byte 对齐，稀疏 group 升序 beat、tail，STORE child completion/result 任意序，fault cause/eaddr、背压、stop-on-first 与 partial masks/bytes | 仅凭独立 engine 测试就声称 cluster wiring、ARF/MRF 直接传输、MMU/TLB/PTW/cache/IFetch、多 outstanding/乱序返回或自动 command coalescing 已实现，或描述符已是最终 ISA |
| Ordered dmem 仿真 endpoint | `vsp_ordered_dmem_model_tb` | byte-addressed little-endian backing、partial STORE strobe、STORE ack、LOCAL/address-range/beat-shape fault、四项 FIFO ordered outstanding、满队列同拍 pop+push、response backpressure 稳定与 reset 丢弃在途 response，共 87 项检查；8-byte/depth-1 参数 lint | 物理 SRAM/cache/MMU/DMA 已实现；无 ID 接口支持乱序返回；vector memory engine 已经产生多 outstanding；仿真 latency 是目标时序 |
| Cluster VRF arbiter | `vsp_cluster_vrf_arbiter_tb` | 多 client read/write RR 仲裁、单 child owner 保持、read completion/response 独立返回与背压、write completion/error 路由、reset | 仅凭该单元测试就声称 common class/program-order controller、寄存器依赖检查、group ownership 或多 child outstanding 已实现 |
| Cluster register route | `vsp_cluster_register_route_engine_tb` | 4×SIMD4/16-byte VRF-indexed gather 会在首次 `vd` 写入前完成 active group 的 source/index row 快照；全 mask reverse、稀疏 group mask、inactive destination 保持、active OOB/缺失 source 关闭 byte write 并保留 `vd`、同组 mixed-validity 部分写回、全 invalid group 的零 mask no-op write、invalid-element mask 只诊断且不触发 action error、含 mixed-invalid 的 `vd==vs` 以及 `vd==vi` 别名、read completion/response 两种分离次序与停顿、empty-mask 零 VRF 侧效应拒绝、read-side fault 在首次 commit 前原子 abort、write fault 的精确 group mask/partial commit、full-mask `8 read + 4 write` 事务数、`LOCAL` 与 role-complete `DEP_INOUT` engine 执行、`DEP_IN/DEP_OUT` 有序拒绝且零 VRF 流量，以及 completion 背压稳定 | 当前 engine 为 single-active，经 shared VRF transaction boundary 串行 capture/commit；`DEP_INOUT` 的双槽 dependency precondition 尚无上游证明，双槽 rendezvous/drain 也未接入，slot/queue empty 不构成充分 drain；指令尚无独立细粒度 predicate，OOB 只提供 no-write/undisturbed sentinel 而不提供 zero-fill；不声称固定延迟、`II=1`、并行 RF 端口、write-side fault rollback、16-byte 以外 route、scatter/memory gather、最终拓扑或 PPA |
| Decoded memory/route 闭环 | `vsp_cluster_memory_wrapper_tb` | vector memory engine 与 register-route engine 经 shared VRF arbiter 接到 cluster state-read/write；边界外 local-memory model 下 LOAD→ADD-immediate EXEC→VROUTE→STORE 的四组结果、MEMORY→route drain、route→MEMORY lock、route owner reject、dmem backpressure、completion/protocol 状态，共 205 项检查 | 仅凭该 blocking profile 就声称一般化 dependency scheduler、并行 route、细粒度 predicate、物理 local SRAM、MMU/cache/DMA 或最终 MEMORY ISA 已实现 |
| Ordered action controller | `vsp_decoded_action_controller_tb` | strict single-active class routing、reserved-class/upstream-decode/owner/control local reject 零 child 副作用、统一 completion 背压、同拍或延后 child completion、identity/protocol sticky、live reset 与 global `END` | queue/control-store/predecode、invalid-context cause 穷举、per-context 并发、动态 owner/resource、一般化 barrier、host ABI 或最终指令格式 |
| Profile-v0 controller 闭环 | `vsp_cluster_controller_wrapper_tb` | 持续 action 输入下的 decoded source LOAD → decoded index LOAD → encoded ADDI → VRF-indexed 16-byte cluster `VROUTE` → decoded STORE → END 自动排序与实际写回；统一详细 completion、EXEC child reject、MEMORY fault/partial、owner/decode error、dmem/result/completion 背压，以及有限 result staging 对 END 的间接反压 | 物理 SRAM/MMU/cache/DMA、并行 route capture/commit、固定延迟或 `II=1`、16-byte 以外 route、scatter、最终 MEMORY/CONTROL encoding、sequencer PC/loop、并发吞吐组织或整个 kernel 无错误的 `program_done` 语义 |
| 参数稳健性 | `simd_issue_dispatch_wide_tb`，queue 的非二次幂与单项动态测试/lint，8/16-lane lint | 参数变化下实现没有暴露已测错误 | 8-group、具体 queue 深度或 8/16-lane 已成为架构 profile |
| 组件性质 | `benes_network_tb` | 当前 8-port 裸网络控制能覆盖所有 permutation | 网络规模、流水、分级和物理实现合适 |
| 组件性质 | `vsp_lane_gather_tb` | 16-lane 固定 crossbar 的九种 mode（含动态 GATHER）、rotate wrap 报告与零填充 shift 推导、保留 mode 无数据拒绝，以及置换多重集/可逆合成等独立性质，共 100060 项检查；8/12/64-lane 参数 lint | 该网络规模、分级、流水或面积合适；已接入数据通路；stripe、索引来源、资源预留、group ownership、写回事务或跨组 out-of-range 语义已定义；它是最终路由方案 |
| 工作负载证据 | `sad_kernel_tb`、`gaussian3x3_tb` | 现有原语可组成这些映射，数值参考一致 | 真实存储供给、sequencer 吞吐或映射最优 |
| 工作负载证据 | `sobel3x3_tb` | `WSUB_U` 负 ACC 累加链、共享 align 表达 1/2 系数、source-A route 参与宽三输入操作、`NCLIP_S` 有符号舍入窄化与饱和、`ABS_SAT_S`+`ADD_SAT_U` 合成幅值；两种缩放、step edge 极值、tail mask 与覆盖自证 | 真实存储供给、sequencer 吞吐或映射最优；全量程 `\|Gx\|+\|Gy\|` 可表达（缺宽域 ABS）；本映射覆盖了 `ADD_SAT_U` 的饱和（不可达） |
| 工作负载证据 | `gaussian3x3_separable_tb` | 两 pass 8-bit 可分离 `[1,2,1]` 映射的正确性（独立同算术 oracle）、与精确九 tap 的偏差在本输入域内 max=1、按内容分类的偏差统计、两 pass 各 4 条微操作的计量，以及程序化图样与可选 PGM 手动路径 | 可分离映射更快（无中间行复用时更慢）；line buffer/本地 SRAM 已有 RTL；偏差界 2 是解析证明（实测界）；九 tap 直接映射的数值覆盖（仍由 `gaussian3x3_tb` 负责）；HALF MUL/MAC 已被证明值得增加 |
| 工作负载证据 | `median3x3_tb` | 19-comparator median9 network 的全部 `9!` rank permutation 结构证明、逐 lane RTL 与独立图像 oracle 一致、zero padding/tail mask/噪声图样，以及单写口三指令 compare-exchange 的 57 EXEC/block 计量 | 双结果 MINMAX 值得增加；四 lane reduction 能解决本布局（它会混合四个输出像素）；真实 memory supply 或该序列是系统瓶颈 |
| 探索模型 | `mul32_microcode_tb` | low-32 base-256 卷积数学与候选步骤一致 | RTL 已支持 PMAC8 或应该增加该操作 |

当前 rendezvous leaf 测试只拥有表内收集、frontier 门槛和 terminal 合同。真正接入
双槽 program path 时还需要独立 integration 测试：`00 LOCAL` 不产生 token；`11`
不等 half peer 但等待 participant retirement；queue empty 而 ingress/tracker/reject/
completion/MEMORY/VRF 任一未清时不得 READY；等待期间另一槽 older action 继续推进；
READY→RUN 原子预留 union resources 与两项 completion capacity；FANOUT 在独立背压下
保持 context/tag/mask/status 稳定。这组顶层闭环测试尚未存在。

当前 `make test` 仍是聚合入口；uword 编制器与 program frontend、bundle predecoder、
multi-record framer、ordered action window、wrapper、completion tracker、decode holding、result
collector、EXEC cluster integration、VRF vector memory engine、cluster VRF arbiter、cluster
register-route engine、decoded memory wrapper、strict action controller、controller/program wrapper、issue queue 与 frontend 都已纳入
现有 `lint/test` 聚合入口，没有为该分类另建顶层脚本。

## 4. 新测试的准入问题

在把测试加入常驻回归前，先回答：

1. 它唯一验证的 claim 或故障类型是什么？
2. claim 来自当前行为语义、正确性 invariant、bug，还是探索假设？
3. oracle 是否独立；若复制 RTL/调度算法，只能称为 drift detector；
4. 哪个最低可观察层已经能发现错误？
5. 测试依赖哪些假设，又明确不声称什么？
6. 它替代、合并或覆盖了哪个旧测试？
7. 架构或 harness 变化到什么条件时可以退役？

可用下面的短 manifest 记录：

```text
CLASS:
CLAIM:
SOURCE / QUESTION:
ORACLE:
ASSUMPTIONS:
NON_CLAIMS:
RETIRE_WHEN:
```

这不是要求每个 case 写长说明；同一 testbench 的一组同类 case 可以共享一份。

## 5. 避免“测试驱动更多测试”

- 同一 claim 由最低可观察层的 primary test 负责；上层只测新的集成边界；
- 增加随机次数主要提高已有 oracle 的抽样强度，不被算作新的架构证据；
- 工作负载映射保留少量端到端样本，不重复复制底层全部数值边角；
- 参数化 lint/test 证明实现稳健性，不把参数组合写成架构承诺；
- 候选硬件先进入 model/benchmark，选定前不建立 opcode 合同式 gating test；
- bug case 被更一般的 invariant 完整覆盖后，可以合并或删除。

当前有两个值得留意的同构 oracle：

- `simd_uop_legal_tb` 按连续 opcode 区间生成期望，和 RTL capability 分类较相似；
- dispatcher 随机 test 复制了低槽优先选择算法。

它们适合做漂移检测，但继续扩大随机量不能消除“两边一起错”。更独立的补充应是
少量手写 anchor、metamorphic property 和外部可观察 invariant，例如：

- 插入任意 backpressure 不改变最终提交序列；
- 未 fire 的请求不改变状态；
- multicast 不会部分提交；
- illegal 请求无任何 RF/response 副作用；
- 每个 accepted EXEC command 恰好一条 command completion；若有
  expected result，tag 在 collector retire 前仍不可重用。

这里先记录方法，不在本轮扩展测试。

## 6. 避免“规避驱动更多规避”

workaround 建议附带：

```text
原因 | 影响范围 | 可观察语义代价 | 替代方案 | 重新评估条件 | 对应测试的退役条件
```

若一个 workaround 需要第二个模块再增加专门 workaround，先回到抽象边界重新检查，
而不是默认叠加第三层。例如：

- `cfg_*` 是状态注入接口，不因 testbench 方便就逐步扩展成隐式内存系统；
- 固定 slide boundary 常量是当前 harness 供数方式，不围绕它建立永久互连假设；
- 不支持的组合优先检查 reject/no-side-effect，不自动追加 fallback 微码来维持旧测试；
- PMAC、拟浮点和 wide reduction 在候选阶段用模型和 trace，比用操作码测试更合适。

## 7. 何时删除或改写测试

以下情况删除测试是正常维护，而不是降低质量：

- 它只断言已经改变的内部接线，外部 claim 未变；
- 更低层、更独立的 invariant 已完整覆盖同一故障；
- 对应探索方案已放弃，不再是 gating behavior；
- harness 假设已被真实 wrapper、DMA 或数据源替代；
- 它没有独立 claim，只增加运行时间或随机次数；
- 原 bug 已被更一般性质覆盖，且旧 case 不再有独立故障敏感性。

删除前记录由哪个 claim/test 接替即可。测试是维护代码，不是只能增长不能缩减的
架构历史。

## 8. 架构比较所需的证据

正确性回归回答“实现有没有违反已声明行为”；它通常不能回答“硬件值不值得做”。
后者应让多个候选重放同一 workload/trace，并比较：

- issue 利用率、阻塞原因和每结果微操作数；
- buffer occupancy、网络交付和 RF bank 冲突；
- 综合后的面积、频率和功耗代理；
- 方案不能处理的反例；
- 复杂度转移到了哪个软件、controller 或物理层。

例如 1/2/3 个 issue slot、slice+WADD 与 wide reducer、Omega 与 Bênes 的跨组 gather 实现，
都属于这种比较；现有 regression 通过不会提前结束比较。

## 9. 协作 agent 的额外防漂移检查

自动化协作本身也没有“不会自激励”的保证。工作中采用以下检查降低风险：

- agent 写出的摘要、图和测试彼此不是独立证据，不能互相引用形成闭环；
- 多个 agent 得出相同建议只是审查信号，不按票数升级方案；
- 每次实现前重新区分用户当前问题、RTL 事实、工作假设和非目标；
- 建议同时写能推翻它的反例或重新评估条件；
- 文档整理和 conversation summary 保留原状态标签，不把“多次出现”改写成“已经
  决定”；
- 回归失败先判断 claim 是否仍有效，再决定改 RTL、改 test 还是撤销旧假设；
- 当新规避依赖旧规避时，暂停扩展，回查最初的接口边界。

这些是人工治理措施，不是形式证明。它们能让偏航更容易暴露，但不能替代用户对
架构方向的判断，也不能让 harness 自己决定项目目标。
