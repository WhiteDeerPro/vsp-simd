# 文档导航

文档按内容性质收集，目录名不表示决策等级：

```text
architecture/   当前可观察行为、数值语义和架构范围工作稿
design/         controller、发射和实施顺序的暂行设计
integration/    跨仓 IP 的实际接线、依赖基线和产品闭环状态
explorations/   Q&A、分析方法和候选模型
workloads/      代表性负载映射
verification/   如何解释和维护验证证据
```

建议先读[统一术语表](architecture/terminology.md)、架构范围和当前数据通路，再看
问题集。这样能区分“现在是什么”“下一步想试什么”和“仍在问什么”。

## 状态标签

关键段落使用以下标签，而不再把整份文档统称为“当前决定”：

| 标签 | 含义 |
|---|---|
| `[RTL事实]` | 当前源码可直接观察到；修改实现后可以变化 |
| `[正确性约束]` | 在所述接口下，违反会造成丢失、重复、乱序或错误提交 |
| `[里程碑基线]` | 为闭合一个阶段采用的参考实现，可被实验替换 |
| `[候选]` / `[暂行模型]` | 值得比较的方案之一，尚未成为长期约束 |
| `[开放问题]` | 当前证据不足 |
| `[负载证据]` | 证明某种组合可行，不证明映射或硬件最优 |

文档被重复引用、进入 roadmap 或已有 testbench，不会自动提高其状态。若以后需要
长期约束，应显式记录作用范围、替代方案、接受者和重新打开条件；当前没有用
Q&A 代替这类记录。

## 1. 架构与当前行为

| 文档 | 主要性质 | 内容 |
|---|---|---|
| [统一术语表](architecture/terminology.md) | 当前命名约定 | RVV 对齐边界、物理拓扑、dispatch class、协议与 RTL 命名 |
| [架构范围工作稿](architecture/overview.md) | 范围快照 + RTL 事实 + 开放问题 | VSP/SIMD4 边界、数据形状和当前能力 |
| [当前控制与内存集成状态](architecture/current-integration.md) | RTL 接线事实 + 后续边界 | PC bundle、external IFetch、strict action、I/D cache/MMU/fabric 与仍外置的 SoC 边界 |
| [I-side / D-side 内存模型边界](architecture/memory-hierarchy.md) | I/D RTL 事实 + SoC 候选分层 | program fetch、dmem、当前 I/D cache、共享 MMU/fabric 与地址状态 |
| [数据通路](architecture/datapath.md) | RTL 事实 | VRF/ARF/MRF、并行控制、mask、立即数与提交 |
| [微架构图](architecture/microarchitecture.md) | RTL 事实 | 单个 SIMD4 的读取、执行、合法性和写回 |
| [寄存器文件](architecture/register-file.md) | RTL 事实 + 物理候选 | 逻辑端口、masked write 与 bank/SRAM 问题 |
| [Indexed memory 与路由边界](architecture/routing.md) | 当前 MEMORY 语义 + 实验网络边界 | UNIT_STRIDE/INDEX_U8、VGATHER/VSCATTER、16B 实装/64B 上限及退役 register-route 实验 |
| [定点宽窄语义](architecture/fixed-point.md) | RTL 事实 | AVG、WIDEN/WADD/WSUB、NSLICE/NCLIP |
| [乘法语义与映射](architecture/arithmetic.md) | RTL 事实 + 候选 | byte MUL/MAC 与多 byte 映射触发条件 |

Graphviz 源与生成图和说明文档放在一起：

- [SIMD4 微架构源](architecture/microarchitecture.dot) /
  [SVG](architecture/microarchitecture.svg)
- [控制与内存集成源](architecture/current-integration.dot) /
  [SVG](architecture/current-integration.svg)
- [I-side / D-side 内存分层源](architecture/memory-hierarchy.dot) /
  [SVG](architecture/memory-hierarchy.svg)
- [宽窄数据流源](architecture/wide-narrow-dataflow.dot) /
  [SVG](architecture/wide-narrow-dataflow.svg)

## 2. 跨 IP 集成

| 文档 | 状态 | 内容 |
|---|---|---|
| [Memory subsystem integration](integration/memory-subsystem.md) | I/D 产品接线 + 依赖基线 | external IFetch、LSU、共享 MMU/PTW、独立 I/D region/cache、physical fabric、统一维护及 SoC/fault 后续边界 |

## 3. 控制设计与计划

| 文档 | 状态 | 内容 |
|---|---|---|
| [集群控制工作稿](design/cluster-control.md) | EXEC/MEMORY leaf integration + strict ordered action controller 参考 RTL | frontend、class routing、ingress、group wrapper、VRF subrequest 仲裁、completion/result、owner 与 END |
| [队列与译码候选](design/instruction-delivery.md) | byte-PC/multi-framer、behavioral/external provider、CONTROL-state/MEMORY semantic decoder 与 strict slot-0 closure 已接 | uword bundle、PC `+4`、queue、live-head、predecode、expander 与 CPU decoder 差异 |
| [Internal EXEC uword profile v0](design/exec-uword-profile-v0.md) | 内部实验编码 + RTL 映射 | 32-bit base、optional immediate extension、canonical EXEC 与非法 cause |
| [数据准备与 DMA 边界](design/data-movement.md) | encoded unit-stride/indexed strict closure 已实现，物理 memory 集成待办 | VLOAD/VSTORE/VGATHER/VSCATTER、VRF arbiter、data-memory 逻辑口、local SRAM 与 DMA |
| [Sequencer 标量/地址状态](design/sequencer-state.md) | 地址状态、比较 branch 与 loop/redirect 已接 strict closure | 最小 scalar/address state、寻址裁剪、MEMORY base 与后续调用/回写边界 |
| [集群实验路线](design/development-roadmap.md) | 单 PC/单 slot 与 PHYSICAL I/D 动态基线已实现，translated/fault/SoC/测量待办 | wrapper、cluster、indexed memory、地址层、规模与物理化 |

这里的 decoder 属于 sequencer 到执行 group 之间的内部控制层，不意味着 SIMD4
获得取指、分支或异常能力。

## 4. 探索与 Q&A

| 文档 | 性质 | 内容 |
|---|---|---|
| [架构问题集](explorations/architecture-qa.md) | 非约束 Q&A | 标量侧、ARF/VRF、内积、路由、调度、内存、拟浮点等 |
| [数据生命周期](explorations/data-lifecycle.md) | 分析方法 | 产生、交付、读取、写入、退休与 burst 的计量 |
| [32-bit byte 卷积](explorations/mul32-byte-convolution.md) | 参考模型 | low-32 乘法候选映射，不是现有 RTL 指令 |

## 5. 负载与验证方法

| 文档 | 性质 | 内容 |
|---|---|---|
| [单通道 3×3 Gaussian](workloads/gaussian3x3.md) | 工作负载证据 | slide、连续 ARF MAC、tail mask 与 NCLIP |
| [单通道 3×3 Sobel](workloads/sobel3x3.md) | 工作负载证据 | WSUB 宽有符号累加、共享 align 系数、NCLIP_S 与幅值合成，附微操作计量对比 |
| [可分离 Gaussian 与两次舍入代价](workloads/gaussian3x3-separable.md) | 工作负载证据 + 比较集合 | 两 pass 8-bit 映射、按内容分类的偏差统计、行缓冲前提与对 HALF 支持的判断 |
| [单通道 3×3 Median](workloads/median3x3.md) | 工作负载证据 | 19-comparator selection network、单写口三指令 compare-exchange，以及 lane reduction 不适用该布局的原因 |
| [验证 harness 与路径漂移](verification/harness.md) | 方法工作稿 | 测试分类、非声明范围、准入、替换与退役 |

SAD、动态 ALU、local route、compact、MRF、reduction、
issue/decode frontend、uword bundle predecoder/program frontend、EXEC uword expander、strict action controller、dispatcher、cluster execution integration、result collector、completion
tracker、VRF vector memory engine、cluster VRF arbiter、decoded memory wrapper、controller wrapper 与 legality 的
具体覆盖仍由 `sim/` 中的自检 testbench 记录。Bênes/route-wave 等退役跨组路由实验
改由可选 experimental-routing 目标维护，不属于默认产品回归。

## 6. 证据关系与维护

- 设计文档表达当前意图，RTL 是当前实现，testbench 是带假设的证据；
- 三者冲突时登记为实现缺陷、测试过期、文档歧义、架构变化或开放问题之一，
  不让 RTL 或测试自动定义未来架构；
- 强措辞保留给已明确作用域的数值语义和事务正确性，例如 no-side-effect、
  no-partial-multicast、no-drop/no-duplicate；
- 参数化 lint/test 说明实现稳健性，不等同于接受对应架构 profile；
- 修改 `.dot` 后同步生成对应 `.svg`；
- 迁移或重命名文档后运行本地链接检查。
