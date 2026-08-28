# 文档导航

文档按内容性质收集，目录名不表示决策等级：

```text
architecture/   当前可观察行为、数值语义和架构范围工作稿
design/         controller、发射和实施顺序的暂行设计
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
| [数据通路](architecture/datapath.md) | RTL 事实 | VRF/ARF/MRF、并行控制、mask、立即数与提交 |
| [微架构图](architecture/microarchitecture.md) | RTL 事实 | 单个 SIMD4 的读取、执行、合法性和写回 |
| [寄存器文件](architecture/register-file.md) | RTL 事实 + 物理候选 | 逻辑端口、masked write 与 bank/SRAM 问题 |
| [局部与跨组路由](architecture/routing.md) | RTL 事实 + 上层候选 | local crossbar、broadcast、slide、compact 与跨组 gather 候选 |
| [定点宽窄语义](architecture/fixed-point.md) | RTL 事实 | AVG、WIDEN/WADD/WSUB、NSLICE/NCLIP |
| [乘法语义与映射](architecture/arithmetic.md) | RTL 事实 + 候选 | byte MUL/MAC 与多 byte 映射触发条件 |

Graphviz 源与生成图和说明文档放在一起：

- [SIMD4 微架构源](architecture/microarchitecture.dot) /
  [SVG](architecture/microarchitecture.svg)
- [宽窄数据流源](architecture/wide-narrow-dataflow.dot) /
  [SVG](architecture/wide-narrow-dataflow.svg)

## 2. 控制设计与计划

| 文档 | 状态 | 内容 |
|---|---|---|
| [集群控制工作稿](design/cluster-control.md) | EXEC/MEMORY decoded reference RTL 事实 + 候选 controller | frontend、ingress、group wrapper、VRF subrequest 仲裁、completion/result、owner 与 multicast |
| [队列与译码候选](design/instruction-delivery.md) | decode holding 已实现，真实译码/展开待实现 | queue、live-head、locked shadow、predecode、expander 与 CPU decoder 差异 |
| [数据准备与 DMA 边界](design/data-movement.md) | decoded VRF LOAD/STORE cluster 闭环已实现，物理 memory 集成待办 | MEMORY LOAD/STORE、shared VRF arbiter、data-memory 逻辑口、local SRAM 与 DMA |
| [集群实验路线](design/development-roadmap.md) | EXEC integration、decode holding、vector memory engine/VRF arbiter、decoded memory wrapper 已实现 + 控制集成计划 | wrapper、cluster、controller、跨组 gather、DMA |

这里的 decoder 属于 sequencer 到执行 group 之间的内部控制层，不意味着 SIMD4
获得取指、分支或异常能力。

## 3. 探索与 Q&A

| 文档 | 性质 | 内容 |
|---|---|---|
| [架构问题集](explorations/architecture-qa.md) | 非约束 Q&A | 标量侧、ARF/VRF、内积、路由、调度、内存、拟浮点等 |
| [数据生命周期](explorations/data-lifecycle.md) | 分析方法 | 产生、交付、读取、写入、退休与 burst 的计量 |
| [32-bit byte 卷积](explorations/mul32-byte-convolution.md) | 参考模型 | low-32 乘法候选映射，不是现有 RTL 指令 |

## 4. 负载与验证方法

| 文档 | 性质 | 内容 |
|---|---|---|
| [单通道 3×3 Gaussian](workloads/gaussian3x3.md) | 工作负载证据 | slide、连续 ARF MAC、tail mask 与 NCLIP |
| [验证 harness 与路径漂移](verification/harness.md) | 方法工作稿 | 测试分类、非声明范围、准入、替换与退役 |

SAD、动态 ALU、local route、Bênes、compact、MRF、reduction、
issue/decode frontend、dispatcher、cluster execution integration、result collector、completion
tracker、VRF vector memory engine、cluster VRF arbiter、decoded memory wrapper 与 legality 的
具体覆盖仍由 `sim/` 中的自检 testbench 记录。

## 5. 证据关系与维护

- 设计文档表达当前意图，RTL 是当前实现，testbench 是带假设的证据；
- 三者冲突时登记为实现缺陷、测试过期、文档歧义、架构变化或开放问题之一，
  不让 RTL 或测试自动定义未来架构；
- 强措辞保留给已明确作用域的数值语义和事务正确性，例如 no-side-effect、
  no-partial-multicast、no-drop/no-duplicate；
- 参数化 lint/test 说明实现稳健性，不等同于接受对应架构 profile；
- 修改 `.dot` 后同步生成对应 `.svg`；
- 迁移或重命名文档后运行本地链接检查。
