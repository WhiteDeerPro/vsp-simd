# VSP 术语表

> 本页是项目术语的统一入口。它区分编程语义、微架构、控制协议和 RTL 命名；
> 这些名称描述当前设计，不冻结最终 ISA、模块层级或物理实现。

## 1. 使用原则

- 在语义确实相同的地方采用 RISC-V Vector Extension（RVV）的通用词汇，例如
  vector operation、vector register、element、element width、mask 和 load/store。
  gather、slide、reduction、compress 等当前按 byte lane 工作的原语必须带粒度限定。
- `SIMD group`、`execution cluster` 和 physical lane 描述 VSP 的物理组织；它们不是
  RVV ISA 状态，也不应为了形式相似而改称 Vector Unit。
- 网络拓扑只出现在实现层。编程语义写 gather、slide、broadcast 或 permutation，
  不把 crossbar、Omega 或 Bênes 写成操作语义。
- 尚未实现的 RVV 状态或能力不借用其名称。目前没有 RVV-compatible `vl`/`vtype`/
  `LMUL` programming model，也没有对 RVV implementation-defined `VLEN` 的架构暴露；
  VSP 的 RF 宽度仍只是实现参数。

## 2. 架构与编程语义

| 首选名称 | 当前含义 |
|---|---|
| VSP | 项目和未来子系统的名称；当前不强行展开缩写，也不等同于一颗自行取指的 CPU |
| vector operation | 对向量数据执行的一项操作。最终指令编码未定义时，优先于“vector instruction” |
| vector operand / result | 操作读入或产生的逻辑向量值 |
| vector register file (`VRF`) | 保存窄向量状态的寄存器文件 |
| element | 一项逻辑数据；当前由 1、2 或 4 个相邻 8-bit physical lane 组成 |
| element width | 每项操作选择的 BYTE/HALF/WORD 宽度。它与 RVV 的 SEW 概念相近，但随 VSP action 直接携带，不是 `vtype` CSR 状态 |
| mask / predicate | 决定哪些数据位置参与操作的条件。当前 MRF 按 physical byte lane 保存一位，不等同于 RVV 每 logical element 一位的 v0 mask |
| vector load / store | 在 memory boundary 与 VRF 之间传输向量数据。当前实现是 blocking、顺序 beat，不表示已支持 RVV constant-stride 或 indexed memory operation |
| lane gather | `DR[i] = SR[IR[i]]`；当前 `i` 是 physical byte lane，重复索引表达 broadcast/multicast，不是 memory gather |
| lane slide | 按相邻 physical byte lane 移动数据，并从边界输入或零补入 |
| lane reduction | 将多个活动 physical byte lane 合成为 32-bit scalar result |
| lane compress | 按 MRF 的 base-lane mask 稳定收集 physical byte lane |

RVV 中的 `vector register group` 是由 LMUL/EMUL 组合的一组架构寄存器。它与本项目的
physical `SIMD group` 没有对应关系；文档不得把两者简称为同一个“group”。RVV 的
indexed load/store 也不能用“连续 LOAD 后再做 register gather”一般性替代。
RVV 的 `vrgather`、`vslide`、reduction 和 `vcompress` 按当前 SEW 的 logical element
工作；VSP 当前这些 route/compact/reduction 原语按 8-bit physical lane 工作。
HALF/WORD 的 element-level 语义需要由微码组合或后续 action 定义，不能仅靠同名
宣称兼容。

## 3. 微架构

| 首选名称 | 当前含义 |
|---|---|
| physical lane | 最小 8-bit 数据通路 slice。HALF/WORD 是多个 slice 组成的 element，不是新增 lane |
| SIMD group | 默认由 4 个 physical lane、group-local RF state 和执行路径组成的调度颗粒 |
| execution cluster | 多个 SIMD group 的发射、所有权、共享资源和完成集成域；当前参考 profile 是四组，不是固定架构上限 |
| Vector ALU / execution path | 执行逐元素算术、逻辑、局部 route 和 lane reduction 的路径 |
| VRF row | 一个 SIMD group 内的 4×8-bit 物理寄存器片段，不等同于一个完整 RVV vector register |
| accumulator register file (`ARF`) | VSP 特有的宽累加状态；当前每个 physical lane 保存一个 32-bit accumulator |
| mask register file (`MRF`) | VSP 特有的 base-lane-granular predicate state；不是 RVV 的独立 mask register file |
| vector memory engine | 把一项 vector load/store command 分解成 memory beat 与 group-local VRF subrequest |
| VRF arbiter | 在多个 client 和 cluster VRF endpoint 之间选择 request 并保持返回归属 |
| sequencer | 提供 action、循环状态和标量参数的上级控制单元；SIMD group 不自行取指 |

`Group` 和 `Cluster` 只在已经给出上述限定的局部上下文中简写。面向软件的描述优先谈
vector operation、element 和 register，不暴露不必要的物理分组。

## 4. 控制与事务协议

| 首选名称 | 当前含义 |
|---|---|
| action | sequencer 交付的一项工作；跨 dispatch class 的顺序接受和退休仍是待实现的 controller 责任 |
| dispatch class | **internal action dispatch category**；只决定 action 进入哪个执行路径，不属于编程模型 |
| `EXEC` | 进入 SIMD group execution path 的 dispatch class，可包含 ALU、route、reduction 等操作 |
| `MEMORY` | 进入 vector memory engine 的 dispatch class |
| `CONTROL` | 计划进入 barrier/admin/controller path 的 dispatch class；当前尚无对应 RTL |
| sequencer/control word (`uword`) | 候选的紧凑内部控制存储格式；不是已定义的 16/32-bit ISA instruction |
| micro-op (`uop`) | 已译码或部分译码、可供调度和执行消费的内部操作 |
| function ID | canonical EXEC bundle 中的 `simd_op_e`；不是完整 opcode |
| execution context | 顺序、所有权、调度和完成回送身份；当前不是 hardware thread，也没有独立 architectural PC |
| address context | 交给未来 translation/protection adapter 的 opaque domain handle |
| request / response / completion | decoupled 协议中的请求、带数据返回和事务完成通知 |
| subrequest / beat | 一个 command 向 group endpoint 或 memory endpoint 拆出的原子传输 |

协议细节中可以在首次定义后使用 parent command / child request 来说明层级，但概览和
编程语义优先使用 command、subrequest、beat、client 和 endpoint，避免把实现树当成
架构对象。

## 5. RTL 命名

| 名称 | 用法 |
|---|---|
| `simd_*` | lane、SIMD group、execution cluster 等执行侧模块 |
| `vsp_*` | sequencer 可见的 engine、integration wrapper 或 VSP 子系统模块 |
| `*_engine` / `*_unit` | 保存并推进某类操作的功能模块 |
| `*_arbiter` | 竞争请求选择和返回归属保持 |
| `*_stage` | 流水或 elastic holding stage |
| `*_wrapper` | 组合既有模块并暴露参考集成边界；不表示完整 VSP |

新名称不再使用 `Actor`、`Service` 或 `Shell`：硬件功能体写 engine/unit，接口使用方写
client，选择逻辑写 arbiter，集成边界写 wrapper，保存级写 stage。历史提交中的旧名称
只是设计演进记录。

## 6. RVV 对齐边界

对照采用 RISC-V International 的
[Vector Extension 规范](https://docs.riscv.org/reference/isa/v20260120/unpriv/v-st-ext.html)
和[官方规范源文件](https://github.com/riscv/riscv-isa-manual/blob/main/src/unpriv/vector-common.adoc)。
对齐发生在 element、register、mask、load/store 和 permutation 等语义层，不声明
binary compatibility：

- RVV 的 VLEN 是 implementation-defined 常量，运行时活动长度是 `vl`；VSP 当前没有
  与之兼容的 programming model，但已有自身的参数化物理 RF 宽度；
- RVV mask bit 对应 logical element，VSP MRF 当前对应 physical byte lane；
- RVV mask 位于普通 vector register（通常由 v0 提供），VSP 具有独立 MRF；
- RVV 的 widening/narrowing 通过 EEW/EMUL 约束 vector register operands，VSP 具有
  独立 ARF 与显式 wide/narrow 数据通路；
- RVV unit-stride、constant-stride 和 indexed memory operation 是架构访存语义；
  当前 vector memory engine 只实现顺序、blocking 的 VRF transfer profile。
