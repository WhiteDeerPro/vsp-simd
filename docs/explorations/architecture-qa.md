# 架构问题集

> 状态：非约束性工作笔记。这里收集讨论中反复出现的问题、当前可观察事实、
> 工作回答和重新评估条件。某个回答被多次引用，不会因此自动升级为架构决定。
>
> 最近整理：2026-08-26。
>
> 2026-08-30 的当前 profile 已收束为单 PC、单 issue slot、4 group/16 byte 实装，
> 16 group/64 byte 为参数上限；跨 group register route 与 route-wave 不再进入产品路径，
> 改用 MEMORY `INDEX_U8` gather/scatter。与此冲突的旧问答只保留为推理历史，当前事实
> 以[术语表](../architecture/terminology.md)和
> [current integration](../architecture/current-integration.md)为准。
>
> **数值格式状态更新（2026-09-04）**：旧`math_fp16_add.uasm`是不可执行的
> S1E7F8概念稿，已经从验证构建排除；真正的BF16（S1E8F7）尚未实现。当前已经
> 执行并验证的是静态BFP8 profile：FFT64从SRAM装载复制的`Ein=-2`，在EXEC中更新
> 为`Eout=4`，再经D-cache写回SRAM。动态指数选择仍是开放问题。详见
> [BFP8块浮点数值契约](../math/BLOCK_FLOATING.md)和
> [动态块浮点与BF16执行缺口](../../issues/open/动态块浮点与BF16执行缺口-Codex-2026-09-04.md)。

## 如何阅读

- `[RTL事实]`：当前源码可直接观察到的行为；以后修改 RTL 时可以变化；
- `[正确性约束]`：在所述接口模型下，违反会造成数据丢失、重复、乱序或错误提交；
- `[工作假设]`：为了推进某一阶段采用的简化；
- `[候选]`：值得实现或测量的方案之一；
- `[开放问题]`：当前证据不足；
- `[负载证据]`：某个参考负载证明“可以组成”，不证明“这是最优架构”。

Q&A 只承载分析。若以后需要一项长期约束，应另外记录作用范围、替代方案、接受者
和重新打开条件，而不是从本页的重复总结中推导出来。

## AQ-001：SIMD4、标量侧与 VSP 是什么关系？

**问题**：SIMD4 是一颗支持 SIMD 的 CPU、VSP 的从属设备，还是 VSP 内核？能否
直接拿一条 SIMD lane 当标量核？

**当前观察 `[RTL事实]`**：现有 SIMD4 只有外部控制的数据通路，没有取指、分支、
异常、地址生成或标量寄存器文件。testbench 直接提供展开控制。
仓库另有图外的 `vsp_vector_memory_engine`，但这不赋予 SIMD4 取指或
通用 CPU 地址/异常语义。

**工作回答 `[工作假设]`**：当前更适合把它看作由 VSP sequencer 调度的执行 group。
标量控制侧负责循环、地址、事件和发射；这不预先决定标量侧最终是 VSP 内部模块、
宿主侧设备还是可编程小核。复用一条 byte lane 可以提供少量标量算术，却不会自动
得到地址状态、控制流和异常语义，因此不是完整标量核的等价替代。

**重新评估**：在 DMA/地址生成和 controller 接口成形后，再比较“专用 sequencer
状态机、小型标量核、宿主命令处理器”三类组织。

## AQ-002：一个 group、lane、WORD 和 ARF row 分别是什么？

**当前观察 `[RTL事实]`**：当前 profile 是一个 SIMD4 group，含四个 8-bit physical
slice。VRF row 可在一次操作中解释为 `4×8 / 2×16 / 1×32`；ARF row 则是四个
相互独立的 32-bit accumulator，不是一条跨四 lane 的 32-bit WORD。

**边界**：动态 HALF/WORD 目前只覆盖部分普通 ALU、移位和比较操作。byte-only 的
MUL/MAC、饱和、AVG、ABSDIFF 与 ARF 操作不会因为 mode 改变而自动成为宽元素操作。

**开放问题 `[开放问题]`**：是否需要真正的 64-bit 运算、是否需要其他 group 粒度，
仍由负载决定；“以后怎样实现”不应代替“是否需要”的判断。

## AQ-003：VRF 与 ARF 如何互相搬运和重排？

**当前观察 `[RTL事实]`**：

- `WIDEN` 从 VRF 构造 ARF；
- `WADD/WSUB` 计算 `ARF + aligned(VRF-A) ± aligned(VRF-B)`；
- `NSLICE` 从每个 ARF accumulator 取一个直接位窗写回 VRF；
- `NCLIP` 做舍入、右移、饱和后写 VRF；
- local route 位于 VRF-A 路径，当前没有宽 ARF crossbar。

**工作回答 `[工作假设]`**：组内需要重排 ARF 内容时，可以先按 byte plane slice
到 VRF，再使用已有 route。ARF 不经本地 VRF、直接捕获 slice 到跨组路由 staging
是一个候选优化，不是当前 RTL 路径。

**重新评估**：若 ARF byte-plane 外发在 trace 中频繁出现，再比较 packetizer、额外
ARF 读口和先落 VRF 三种代价。

## AQ-004：普通整数溢出、平均与舍入如何理解？

**当前观察 `[RTL事实]`**：普通定宽整数算术回绕；名称显式含 `SAT` 或 `NCLIP`
的操作才饱和。当前不产生普通整数溢出异常。这与 C 风格定宽计算的使用方式相近。

`AVG_U/S` 是 byte 语义的二输入 round-to-nearest-up 平均，不是任意长度 reduction
mean。把长求和写成层层 pairwise average 会改变缩放和舍入位置，适合某些近似
滤波映射，但不能自动等同精确 `a+b+c+...`。

**开放问题 `[开放问题]`**：是否增加其他舍入模式或宽 AVG，只在出现明确数值需求
时重新讨论，不因为理论上可能溢出而自动扩展硬件。

## AQ-005：哈达玛积、内积和完整乘积求和是否可表达？

**当前观察 `[RTL事实]`**：byte MUL/MAC 能把每 lane 的完整 8×8 乘积写入对应
32-bit ARF accumulator；local reduction 当前只读取窄结果。

**已有映射 `[负载证据]`**：

- 窄哈达玛积可以直接留在 VRF，随后用 local route + add tree 归约；
- 完整乘积可以留在 ARF，按 byte plane 用 NSLICE 取回，再用带 align 的 WADD/WSUB
  组合宽求和；该映射受寄存器行数和微操作数限制；
- base-256 卷积参考模型证明 low-32 多 byte 乘法可以由 8×8 部分积组成，但当前
  没有可发射 `PMAC8`。

**开放问题 `[开放问题]`**：wide reduction、三/四输入部分积压缩或专用 DOT4 是否
值得增加，需要比较微操作数、ARF 压力和目标吞吐，而不是仅凭“能够做”或“尚未
单拍做”判断。

## AQ-006：组内与跨组路由如何分工？

**当前观察 `[RTL事实]`**：SIMD4 内直接 4×4 crossbar 支持重复索引，因此同时覆盖
permutation、gather 和 broadcast。跨组路由目前没有 RTL：原先的 row-level Bênes
exchange engine 已删除，因为它与所需语义有两处硬冲突——双射不支持广播，且控制位
无法从运行时索引向量实时派生。

**候选 `[候选]`**：不再区分"组内 crossbar + 组间 row exchange"两套控制路径，而是
用统一的 lane gather 语义 `DR[lane] = SR[IR[lane]]` 覆盖两者，索引向量来自 VRF。
候选实现是 multicast Omega 网络：控制位可由索引位模式经组合逻辑直接派生，
switch 原生支持 broadcast。仅支持 gather，不支持 scatter。

**开放问题 `[开放问题]`**：网络分级、非二次幂 padding、Omega 残余 blocking 的实际
发生率和 ARF packetizer 都需要真实 routing trace。Omega datapath、routing logic 与
Vector ALU 内的接线尚未实现。

## AQ-007：context、queue 和 issue slot 应怎样增长？

**当前观察 `[RTL事实]`**：`simd_issue_dispatch` 模块本身只处理多 slot 的
owner 检查、原子 group-mask 接受、backpressure、重叠优先级和带
credit reject。上层 `simd_cluster_issue_frontend` 已把它与 queue、RR
live-head 选择和 opaque locked shadow 集成；当前默认是四 group、两
queue、两 slot。

**性能假说 `[候选]`**：issue 数随 group 数在对数 profile 与较缓的线性 profile
之间增长，可以作为参数扫描范围。它不是功能下界。四组双发射只是首个集成配置。

**决策证据**：用相同的多 context trace 比较 1/2/3/... slot 的利用率、阻塞、面积
和关键路径；不能用“已有双发射测试通过”证明双发射最合适。

## AQ-008：队列保存编码指令还是解码后控制？

**当前观察 `[RTL事实]`**：现在已有保存不透明
`payload/resolved/sched_meta/tag/group_mask` 的 EXEC frontend；它已有
RR 队头选择和受阻后稳定的 opaque holding slot。`simd_cluster_exec` 已用
full-decoded profile 接到 group wrappers，`simd_issue_decode_stage` 也已验证晚译码
holding 协议；`vsp_exec_uword_expander` 已能解析内部 profile v0，standalone bundle
predecoder 也已实现 record framing/class 预判，但还没有 admission legality/cached
metadata 或 queue-head integration。另一个 action-stream reference 已把
该 expander 接到 strict class router，但尚未替换 FIFO head/holding hook；datapath
仍只暴露展开控制边界。当前 32-bit payload、16-bit
resolved 和 16-bit sched-meta 只是 opaque
默认宽度，不是已定义的 instruction format。术语上应分开 major
dispatch class、版本化的内部 compact uword profile，以及 canonical EXEC 中的
6-bit `simd_op_e` function；`op_i`/`exec_op_i` 不是完整 opcode。

**当前建议 `[候选]`**：per-context FIFO 保存 compact uword、resolved sideband
和硬件派生的 scheduling metadata；被选中的队头再由每 issue slot 的 expander
生成 canonical request。完整 decoded FIFO 与晚译码 encoded FIFO 仍是比较对象。

**不变量 `[正确性约束]`**：无论表示方式如何，entry 的所有权不能丢失或复制，
同 context 顺序不能被无意越过，不可逆接受前要有相应 response/error capacity。
entry 可以留在 FIFO，也可以原子转移到被跟踪的 issue stage。

详见[队列与译码候选](../design/instruction-delivery.md)。

## AQ-009：谁发起内存操作？是否考虑一致性？

**当前观察 `[RTL事实]`**：裸 SIMD4 没有 load/store、地址生成或 cache
coherence。独立 `vsp_vector_memory_engine` 已实现 VRF LOAD/STORE parent 和
单飞行有序 `dmem_req/rsp`；`vsp_cluster_memory_wrapper` 已经由 shared VRF arbiter
把 memory engine 的 VRF subrequest 接到 cluster VRF state-read/write endpoint。
`dmem_*` 后端仍外置；更外层 `vsp_cluster_controller_wrapper` 已提供 single-active
class ordering 和统一 completion，但动态 owner/resource state 与 queue-head
sequencer 仍未实现。`cfg_*` 仍只是初始化/状态传输叶端。

**工作方向 `[候选]`**：地址状态和 DMA/local-memory request 位于 sequencer/controller
层，采用 decoupled request/response；以显式 ownership 和 buffer 同步开始，比在
group 内加入一致性更贴合当前 accelerator 形态。
vector memory engine 区分 execution context 与 opaque address context，并携带
`LOCAL/PHYSICAL/TRANSLATED` effective address；这为下游 adapter 留出边界，
不表示 MMU、TLB、PTW 或 cache 已实现。

数据控制动作、bulk data 与 RF 叶端 beat 的分层另见
[数据准备与 DMA 边界](../design/data-movement.md)。

**开放问题 `[开放问题]`**：与 CPU cache 的一致性、IOMMU/MMU 归属和共享
内存模型属于 SoC 集成层。architectural IFetch 若未来出现，是与
data-memory 分开的逻辑口，不因两者可能共享后端 PTW 就并成一个前端。

## AQ-010：什么时候讨论 pipeline、backpressure 和 bank conflict？

**当前观察 `[RTL事实]`**：裸 datapath 内仍是组合读/执行、时钟沿写回；group wrapper
已采用统一的 `O -> X -> RED/WB` 顺序流水，并为 VRF/ARF/MRF 提供覆盖 X 与 O 两项
有序 producer 的 masked RAW forwarding。dispatcher
有 group-ready 聚合。外层 `simd_group_wrapper` 已为单 group 增加 EXEC/state-write
transaction ready/valid、tagged child completion 和可背压 result buffer，但多 group
`simd_group_completion_tracker` 已独立实现乱序/同拍 child 聚合、无数据
command completion 和 expected-result 生命期。frontend、per-group ingress、
wrappers、tracker 与 RR result collector 已组成 `simd_cluster_exec`；主执行结果先进入
X，reduction 与有序写回位于其后。X 内部的进一步切分与物理 RF bank 仍未实现。

**工作顺序 `[里程碑基线]`**：transaction wrapper 和 EXEC cluster 已闭合
“一次接受、一次完成、返回可背压”的参考行为，并切开 RF lookup、主执行与
reduction/retirement。接下来用目标实现证据和 trace 判断 X 内部是否还需细分。
RF bank conflict 属物理化问题；逻辑 2R/1W 行为模型不保证能直接高效映射成 SRAM。

**重新评估**：目标工艺、频率、RF 容量或多周期单元出现后，以 timing/PPA 和冲突
trace 为证据，而不是继续为行为 testbench 增加假想 stall。

## AQ-011：拟浮点和 64-bit 算术处于什么状态？

**静态BFP8 `[RTL事实][负载证据]`**：当前格式为signed int8尾数与共享signed int8
指数，`x=m*2^(E-7)`。FFT64使用固定的六级缩放计划；程序通过physical VLOAD从
SRAM `0x1360`读取16份`Ein=-2`，由EXEC byte add计算`Eout=4`，再由physical
VSTORE经过D-cache写到SRAM `0x1370`。memory-system回归同时检查尾数FFT结果和
写回指数。这证明静态指数计划能够走通现有执行/存储路径，不证明数据相关的指数
选择已经实现。

**历史拟浮点方案 `[候选]`**：尾数group与指数group协同、补码、允许非规格化并
弱化IEEE-754特殊值，是早期动态方案探索；该候选仍缺少跨组headroom归约、动态
shift决策、指数同步、异常和溢出协议。其开放条件由
[动态块浮点与BF16执行缺口](../../issues/open/动态块浮点与BF16执行缺口-Codex-2026-09-04.md)
追踪。

**BF16 `[开放问题]`**：真正BF16是S1E8F7。当前没有逐元素解包、指数对齐、有效数
运算、规格化、舍入或特殊值传播实现；历史`math_fp16_add.uasm`不能执行且已从
验证构建排除。静态BFP8不是BF16实现，二者不能互相作为功能证据。

**64-bit `[开放问题]`**：当前首先需要回答负载是否需要 64-bit 运算；双 WORD 微码
或专用路径只是后续实现选项，不预先假定需求成立。

## AQ-012：测试通过会不会反过来把候选钉成架构？

会有这种风险。测试能证明实现与某个 oracle/假设一致，不能证明该假设是最佳
架构。当前测试的类别、非声明范围、替换和退役原则见
[验证 harness 与路径漂移](../verification/harness.md)。

工作规则是：候选被写入 Q&A、roadmap、testbench 或参考模型，都不会自动提高其
决策等级；架构比较要保留替代方案、反例和能改变结论的测量条件。

## 后续问题模板

新增问题时尽量保留下面几项，篇幅可以很短：

```text
Question:
Current RTL facts:
Correctness constraints:
Assumptions:
Options:
Working answer:
Non-decisions:
Evidence:
Counterexample / re-evaluation trigger:
```

只有 `Current RTL facts`、外部规范、数学推导、测量或明确的用户选择可以作为
证据；另一条候选 Q&A 只能提供线索，不能互相循环证明。
