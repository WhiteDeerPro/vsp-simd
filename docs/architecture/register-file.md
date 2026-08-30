# 寄存器文件行为与物理化问题

## 当前边界

当前 RTL 定义了寄存器文件的可观察行为；bank、SRAM 类型、端口复制和流水仍是
物理实现变量。

寄存器文件本身不必然是一级流水。若采用触发器阵列、组合读、时钟沿写，它是执行路径前的组合存储和周期状态边界；若采用同步读 SRAM，读地址与读数据之间会自然引入一个周期，此时才形成明确的流水级。

当前执行单元保持无内部流水。VRF、ARF 和 MRF 的组合读、时钟沿 masked-write
行为模型已经接入 `simd_datapath`；尚待选择的是 bank、SRAM 类型、端口复制和
流水等物理实现。

## 当前逻辑组织 `[RTL事实]`

当前行为模型分成三类文件：

```text
向量寄存器文件 VRF
  - 物理 row 保存 4×8-bit；当前操作可解释为 4×8、2×16 或 1×32
  - 逻辑需求约为 2 read + 1 masked write

宽累加寄存器 ARF
  - 每个 physical byte lane 保存一个 32-bit 累加值
  - MAC 使用 1 read + 1 write

掩码寄存器 MRF
  - 每向量一位/lane
  - 独立于普通数据端口
```

这种分离使一次 MAC 的数据需求成为“两次窄读 + 一次宽读 + 一次宽写”，避免让普通窄 VRF 同时提供第三读口和异宽写口。

## lane 分布 `[物理候选]`

若处理器最终包含多个 lane，可以优先比较每 lane 持有向量寄存器一部分的分布式
方案与集中式宽寄存器文件：

```text
vector register vN
  lane 0 owns elements 0, L, 2L, ...
  lane 1 owns elements 1, L+1, 2L+1, ...
  ...
```

普通逐元素运算因此保持 lane-local；只有 permute、slide、压缩和某些 widening/narrowing 操作经过跨 lane 网络。Ara 也采用 lane-local、分 bank 的 VRF，并以单端口 bank、仲裁和 operand queue 处理并发访问，这说明“逻辑多端口”不必等于“物理多端口 SRAM”。

## mask 写入与 `merge_i`

当前独立执行单元通过 `merge_i` 返回未激活 lane 的旧值。接入寄存器文件后，更合适的做法是把 `mask` 转换成每 lane/每字节写使能：

- 激活 lane 写入新结果；
- 未激活 lane 不写，原值自然保留。

这样普通二元 ALU 不需要为了 merge 再读一次目标寄存器。`merge_i` 可以继续存在于执行单元测试接口中，但不必成为物理 VRF 的第三个窄读端口。

`COMPRESS/EXPAND` 和 MRF 布尔运算需要覆盖完整目的行：前者定义零填充，后者
必须能把旧谓词位从一清为零。因此“未激活 lane 保留”只属于普通执行 mask
语义，不能套用到把 mask 当作数据的操作。

MRF 的两个读口在普通操作中分别提供 execution mask 和 `SELECT` 条件；在
`MAND/MOR/MXOR/MNOT` 中复用为两个等价的 MRF 数据源。这是发射控制的语义
复用，不要求增加第三个 MRF 读口。

## 当前行为模型

当前 RTL 采用以下实验配置；寄存器数量仍不是 ISA 承诺：

- 16 个窄向量寄存器；
- 8 个宽累加寄存器；
- 4 个 mask 寄存器；
- 组合读、时钟沿 masked write；
- 每个 SIMD4 单发射、顺序提交；
- 每个文件同周期最多提交一个 row；VRF、ARF、MRF 的独立写口可以并行提交。

当前行为模型等价于小型触发器阵列。寄存器容量或 SIMD4 group 数增长后，再比较
多 bank 1RW SRAM、复制读 bank、时间复用和 operand queue 的 PPA。

## 标量状态是否需要

算法和处理器级控制明确需要标量状态，但当前组合执行子单元不需要内建标量寄存器文件。

标量通常承载：

- 内存基地址、二维 stride、tile 宽高和循环计数；
- 阈值、卷积系数、定点 shift、颜色变换参数；
- 要广播到所有 lane 的常数；
- reduction 的总和、最值、索引和 `popcount` 结果；
- 向量长度、元素类型和 mask/置换相关配置；
- 分支条件、状态指针和调度信息。

这里需要区分两种集成方式：

```text
SIMD 执行子单元 / 协处理器：
  标量寄存器属于外部 sequencer 或宿主核；本单元只接收标量操作数和控制。

独立 SIMD 处理器：
  需要自己的小型 SRF、标量 ALU、地址生成和控制流。
```

当前动态索引不在 VRF-to-VRF 路径中实现。`INDEX_U8` MEMORY action 从分布式 index
VRF row 读取每 lane 的 unsigned byte offset，并对
`base_eaddr + signed_offset + index[lane]` 发出 gather/scatter 请求。当前 4-group 实例
一次选择 16 byte，16-group profile bound 一次选择 64 byte，二者都在 256-byte 地址
window 内工作。旧 word-first/four-pass snapshot、16×16 crossbar 与 register-route engine
仅是 standalone experimental RTL，没有连接当前 PC、action adapter 或产品 wrapper。

## 局部路由网络的位置

当前每个 SIMD4 已经选择在 VRF source A 后放置一份 group-local 4×4 直接 crossbar，
并以旁路 mux 控制是否使用。它支持重复源索引，因此能统一表达 SIMD group 内的 permutation、
gather 和 lane broadcast；slide 读取抽象 boundary ports，cluster 首版由 staging
提供。source B 不复制第二份网络。

Bênes 网络继续保留为较大端口数的一一置换研究模块，不接入当前产品数据通路。当前
baseline 避免把它无条件串在每条普通 ALU 路径上；若未来 workload 重新证明寄存器
全域交换有价值，应按新的单 PC 资源合同评估，而不是恢复旧 route-wave 调度。

对于 `N=2^k、N>=2` 个端口，二进制 Bênes 网络包含 `2*log2(N)-1` 级，每级 `N/2`
个 2×2 switch。它能实现任意排列，但有两个性质使它不适合承载动态 gather：控制字
不是"每个输出选择哪个输入"，需要由目标排列反求合法路由；普通交换单元也不提供
复制语义。Omega/Bênes 仍只是拓扑研究对象；当前没有选择 Omega 作为跨组实现，也没有
产品 `dst[i]=src[index[i]]` register instruction。跨 group 的数据相关选择由上述
indexed-memory gather/scatter 表达；边界和 trade-off 见[路由](routing.md)。

## 尚未决定

- 每个 group 最终采用多少 VRF/ARF/MRF row；
- VRF 采用组合读还是同步 SRAM 读；
- 多 group 的 RF 是否完全私有，还是共享一层 operand/staging storage；
- ARF 在外部编程模型中直接可见，还是只对 sequencer/compiler 可见；
- bank conflict 是停顿、排队还是微操作拆分。

## 参考实现

- [RISC-V Vector Extension](https://docs.riscv.org/reference/isa/unpriv/v-st-ext)
- [Ara vector register file documentation](https://pulp-platform.github.io/ara/modules/lane/vrf.html)
- [Ara paper](https://arxiv.org/abs/1906.00478)
