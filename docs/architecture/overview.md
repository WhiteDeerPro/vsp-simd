# 架构范围工作稿

> 本页混合记录当前实现范围与仍可调整的架构工作模型。各节状态单独标注；
> “当前”只描述此版本，不意味着后续实现必须保持不变。

## 1. 项目对象 `[范围快照]`

当前对象不是完整 VSP 或独立 SIMD CPU，而是 SIMD4 执行 group 及其正在建立的
cluster 控制层：

\[
(op, mask, select, a, b, acc, merge)
\longrightarrow (result, wide, predicate, count)
\]

它只定义运算语义，不定义算法语义。ROI、像素价值、属性通道、分层模型以及是否进行稀疏计算，均由软件决定。

当前项目范围没有走独立处理器路线。操作、标量参数和控制由 sequencer 提供；
SIMD4 不实现取指、分支或异常系统。queue/uword decoder 属于上级内部控制层，
其中 `simd_cluster_exec` 已把 EXEC reference frontend、per-group
ingress、四个 transaction wrapper、completion tracker、reject buffer 和 result
collector 组成可运行的 full-decoded 参考闭环。`simd_issue_decode_stage` 已提供
每 issue slot 一项、可背压的 late-decode holding 边界，但其 decode hook 仍由参考
driver 提供；profile-v0 compact EXEC parser/expander 与 standalone uword bundle
framing/class predecoder 已实现；独立 program frontend 又提供 control-store 行为模型、
线性 byte PC 和跨 bundle assembler。admission legality/cached metadata、action-envelope
binding 与 queue-head 接入尚未实现，见
[指令交付](../design/instruction-delivery.md)。
`vsp_cluster_memory_wrapper` 已把 VRF-only blocking `vsp_vector_memory_engine` 经共享
VRF arbiter 接到 wrapper/cluster state-read/write endpoint，形成 decoded
LOAD→EXEC→STORE 参考闭环。它传递 effective address、address-space kind
和 address context，但 `dmem_*` 仍是逻辑边界；仓库中没有物理 local SRAM、
MMU、TLB、PTW、cache 或 DMA。它保留彼此独立的 decoded EXEC/MEMORY 入口，供
叶级集成测试使用。其外新增的 `vsp_cluster_controller_wrapper` 接收一个有序 action
流：profile-v0 encoded EXEC 在入口展开，decoded MEMORY 分派到 memory engine，
`CONTROL.END` 在内部执行队列、tracker、memory engine 与 VRF arbiter 静止后完成。
当前也没有 architectural IFetch；新增 PC 只为 controller 内部 uword stream 定位，
每个 32-bit base/extension/body 地址 `+4`。这条 control-store 交付与未来软件
instruction IFetch 是不同边界。

### 命名边界 `[当前约定]`

| 名称 | 含义 |
|---|---|
| `simd_*` | lane、group、cluster 等执行侧模块 |
| `vsp_*` | sequencer 可见的 engine、integration wrapper 或 VSP 子系统模块 |
| `VRF_ADDR_W/ARF_ADDR_W/MRF_ADDR_W` | 对应寄存器文件的 row index 宽度；不表示 virtual address |
| `eaddr` | translation/route 之前、位于所声明 address space 中的 effective address |
| `paddr` | 未来 translation/protection 之后的 physical address；当前 RTL 尚无此端口 |
| `exec_context` | 命令所有权、完成回送和调度身份 |
| `addr_context` | 地址服务使用的 opaque translation/domain handle |
| `dmem_*` | LOAD/STORE data-memory 逻辑口 |
| `ifetch_*` | 未来 architectural instruction fetch 逻辑口；当前没有对应 RTL；内部 uword program-source request 不使用该名称 |

`addr_space` 决定 `eaddr` 属于 `LOCAL`、`PHYSICAL` 或 `TRANSLATED`；不再使用
单独、可与 address-space 语义矛盾的 `translation_bypass` 控制位。

## 2. 正确性观察方法 `[方法]`

给定算法参考实现 `A_ref` 与映射到本执行单元的实现 `A_simd`，首先要求：

\[
d(A_{ref}(X), A_{simd}(X)) \leq \varepsilon
\]

然后才比较吞吐、延迟、面积、功耗和内存流量。算法是否发现某个目标不由硬件规定；硬件的责任是按照已定义的数值语义执行算法。

## 3. 数据形状与叶执行语义 `[RTL事实]`

下面的 `a/b/acc/mask/select/merge` 描述 `simd_exec` 叶执行语义。状态化
`simd_datapath` 在其外增加 RF 地址、立即数、route、reduction 和写回控制；完整
canonical bundle 见[数据通路](datapath.md)与
[指令交付](../design/instruction-delivery.md)。

- `LANES=4`：当前 cluster 工作模型以四条 physical lane 为一个调度 group；叶模块参数化不表示
  cluster 可以把 SIMD4 静默扩大成 SIMD8/16；
- `ELEM_W=8`：当前 RTL 的物理窄 slice 为 byte；逻辑元素可组合 1/2/4 个 slice；
- `ACC_W=32`：当前 controller profile 下，每条 physical lane 拥有一个乘法/乘加宽结果；
- `use_imm_i/imm_i`：通常用广播立即数替换 VRF-B；在三输入
  `WADD/WSUB` 中改作 A、B 共用的定点对齐量；
- `mask_i`：每 lane 执行掩码；
- `select_i`：`SELECT` 使用的每 lane 条件，与执行掩码独立；
- `merge_i`：未激活 lane 的窄结果；
- `acc_i`：乘加输入，也是未激活 lane 的宽结果；
- `result_o`：每 lane 的窄结果；
- `wide_o`：每 lane 的宽结果；
- `predicate_o`：比较操作产生的每 lane 谓词；
- 叶级 `illegal_o`：未定义操作码或非法 element mode；group 级还会合并
  writeback、route、reduction 与 capability legality，并统一禁止副作用。

掩码只决定是否提交 lane 结果。它不判断哪些像素重要，也不自动搜索 ROI。

## 4. 操作语义 `[RTL事实]`

首版包含：

- 回绕加减；
- BYTE/HALF/WORD 动态边界的回绕加减、逻辑/算术移位、整体最值和比较；
- 有符号/无符号饱和加减；
- 有符号/无符号最小值、最大值和比较；
- 无符号绝对差，以及有/无符号 round-to-nearest-up 二输入平均；
- 逻辑运算与移位；
- 有符号饱和绝对值；
- 有符号/无符号乘法与乘加；
- 条件选择；
- 有/无符号移位 widening，以及公共移位对齐的三输入
  `ARF + VRF-A ± VRF-B` 宽加减；
- 宽累加值的有/无符号舍入右移；
- 宽累加值逻辑右移后的直接窄位截取；
- 舍入右移、饱和与 narrow 的融合操作。
- MRF 驱动的组内稳定压缩/展开及 population count。
- MRF 的 AND/OR/XOR/NOT 条件组合，并可物化为 VRF 全一/全零元素。

乘法的窄结果是乘积低 `ELEM_W` 位，完整结果写入 `wide_o`。乘加在 `ACC_W` 位上回绕。普通窄操作的 `wide_o` 是窄结果的零扩展。普通定宽算术采用回绕语义；只有名称明确包含 `SAT` 或 `NCLIP` 的操作执行饱和，不产生整数溢出异常。舍入缩放采用 round-to-nearest-up，具体语义见[定点宽窄语义](fixed-point.md)。

## 5. 开放问题 `[开放问题]`

以下问题需要由代表性算法和测量结果驱动，不能从“VSP 应该是什么”倒推：

- SIMD4 group 数、跨组 gather 网络规模和上层向量长度；
- 是否值得为当前 byte-only 的饱和、平均、绝对差、绝对值、乘法和宽 ARF
  操作另行增加宽元素变体；当前控制契约不把它们解释为 HALF/WORD；
- 寄存器文件端口、流水级数、发射宽度和旁路；
- 当前 strict single-active common class ordering 之上的 per-context concurrency、
  resource-aware scheduling、多 outstanding、二维地址、物理局部 SRAM、DMA、
  地址空间/翻译 adapter 与系统集成；
- 跨 SIMD group 的任意 shuffle、gather/scatter，以及跨组压缩流拼接；
- 稀疏 mask 的存储方式及其调度成本；
- 是否增加其他定点舍入模式、异常和统计状态；
- 完整 ISA 编码与软件工具链。

当前内部信号名为 `op_i`/`exec_op_i`；其 6-bit `simd_op_e`
只是已展开 canonical `EXEC` 的 function，不是完整 opcode。
应区分 major dispatch class、未定义编码的 compact uword 和 canonical
operation 三层。当前既没有 32-bit 也没有 16-bit instruction；queue
的 32/16/16 默认宽度是 opaque 参数，不是格式。

## 6. 已完成验证与下一阶段

已经使用少量算法内核驱动硬件，而没有把算法名称固化成操作：

1. SAD/块匹配验证绝对差和 narrow reduction；
2. 单通道 Gaussian 验证 slide、连续 ARF MAC、tail mask 和 NCLIP；
3. compact/expand 与 MRF 穷举验证组内稀疏重排；
4. byte-convolution 参考模型验证 low-32 多 byte 乘法分解。

transaction wrapper、EXEC cluster execution integration、decode holding stage、VRF-only
vector memory engine、shared VRF arbiter、decoded cluster memory wrapper 与 strict ordered
action controller 及 standalone uword bundle predecoder 已完成参考实现。testbench 已在
`dmem_*` 外用 local-memory model 验证 decoded LOAD → profile-v0 encoded EXEC →
decoded STORE → `CONTROL.END`，包括
完成背压、owner/decode error、EXEC child reject、result staging 和 memory fault；
这不表示 local SRAM RTL、最终 MEMORY ISA 或完整 sequencer 已完成。当前工作
计划继续实现 program-record/action adapter、admission metadata/queue-head integration、
动态 owner/resource 状态和 loop/redirect；control-store/byte-PC/bundle assembler 已有
独立行为 reference。随后再根据结果决定物理 memory
hierarchy、DMA、跨组交换与
进一步 lane feature 的顺序。见
[实验路线](../design/development-roadmap.md)。

数据带宽不能只用一个“每周期向量数”概括；逻辑产生、存储写入、网络交付、唯一
输入、操作数读取和退休需要分开统计。二次幂 packet/bank 宽度是便于实验的常见
候选，非满数量可以通过 valid/mask 表达；它不是物理规格。具体方法见
[数据产生、交付、消费与退休](../explorations/data-lifecycle.md)。
