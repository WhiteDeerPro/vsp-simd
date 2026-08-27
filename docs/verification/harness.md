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
| 协议安全 | `simd_group_wrapper_tb`、`simd_group_completion_tracker_tb`、`simd_issue_queue_tb`、`simd_cluster_issue_frontend_tb`、`simd_issue_dispatch_tb`、`simd_issue_decode_shell_tb`、`simd_cluster_result_collector_tb`、`simd_cluster_exec_shell_tb`、`simd_cluster_exec_shell_tracker_credit_tb`、`simd_uop_legal_tb` | 单 group EXEC/state-write/state-read child 守恒、独立返回背压、FIFO 顺序/弹性替换、RR queue claim、opaque/decoded holding 稳定、reject credit、terminal pop、原子 multicast；tracker 的 candidate/commit 分离、乱序/同拍 child、pending/result lifetime、满表背压与 protocol-error sticky；full-decoded GROUP_EXEC shell 的 ingress/wrapper/tracker/result/reject 及 group-addressed VRF state-read/write 边界 | compact-uword parser/canonical expander、class router、有状态 resource scheduler/controller、host completion 或物理 local SRAM/DMA 已连接，或编码和容量选择最优 |
| VRF span 协议 | `vsp_vrf_span_engine_tb` | single active parent/single outstanding dmem beat 的 LOAD/STORE，exec/address context 分离，address-space/eaddr 传递，4-byte 对齐，稀疏 group 升序 beat、tail，STORE child completion/result 任意序，fault cause/eaddr、背压、stop-on-first 与 partial masks/bytes | 仅凭独立 engine 测试就声称 cluster wiring、ARF/MRF 直接传输、MMU/TLB/PTW/cache/IFetch、多 outstanding/乱序返回或自动 command coalescing 已实现，或描述符已是最终 ISA |
| Cluster VRF service | `vsp_cluster_vrf_service_tb` | 多 client read/write RR 仲裁、单 child owner 保持、read completion/response 独立返回与背压、write completion/error 路由、reset | common class/program-order controller、寄存器依赖检查、group ownership、EXCHANGE 已接线或多 child outstanding 已实现 |
| Decoded memory 闭环 | `vsp_cluster_memory_shell_tb` | span engine 经 shared VRF service 接到 cluster state-read/write；边界外 local-memory model 下 LOAD→ADD-immediate GROUP_EXEC→STORE 的四组结果、dmem backpressure、completion/protocol 状态，共 117 项检查 | common class router/program-order enforcement、owner/resource controller、物理 local SRAM、MMU/cache/DMA、EXCHANGE wiring 或最终 MEMORY ISA 已实现 |
| Row exchange 协议 | `vsp_benes_exchange_engine_tb` | 一条 command 一个 row pass；data/byte mask 同路、route snapshot、全源 capture 后写回、稀疏 group、背压、错误与 partial；长逻辑向量可由独立 pass 组合 | route table/compiler、EXCHANGE class router、VRF bridge、共享资源仲裁、非二次幂 padding、整向量原子性或 Bênes broadcast 已实现 |
| 参数稳健性 | `simd_issue_dispatch_wide_tb`，queue 的非二次幂与单项动态测试/lint，8/16-lane lint | 参数变化下实现没有暴露已测错误 | 8-group、具体 queue 深度或 8/16-lane 已成为架构 profile |
| 组件性质 | `benes_network_tb` | 当前 8-port 裸网络控制能覆盖所有 permutation | 网络规模、流水、分级和物理实现合适 |
| 工作负载证据 | `sad_kernel_tb`、`gaussian3x3_tb` | 现有原语可组成这些映射，数值参考一致 | 真实存储供给、sequencer 吞吐或映射最优 |
| 探索模型 | `mul32_microcode_tb` | low-32 base-256 卷积数学与候选步骤一致 | RTL 已支持 PMAC8 或应该增加该操作 |

当前 `make test` 仍是聚合入口；wrapper、completion tracker、decode holding、result
collector、GROUP_EXEC exec shell、VRF span engine、cluster VRF service、decoded
memory shell、row exchange engine、issue queue 与 frontend 都已纳入现有
`lint/test` 聚合入口，没有为该分类另建顶层脚本。

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
- 每个 accepted GROUP_EXEC command 恰好一条 command completion；若有
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

例如 1/2/3 个 issue slot、slice+WADD 与 wide reducer、分层 exchange 与大 Bênes，
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
