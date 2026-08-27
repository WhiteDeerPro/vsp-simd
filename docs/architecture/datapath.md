# 外部控制的数据通路壳 `[RTL事实]`

当前不考虑独立 SIMD 处理器。`simd_datapath` 没有标量寄存器、取指、译码、分支
和异常系统，直接接收寄存器地址、操作码、写回选择、mask 地址和 reduction 等
canonical decoded control。

当前接口不是 32-bit 指令字。执行操作码为 6 bit，其余寄存器地址、立即数、
写回和路由控制以并行信号提供。未来可以在 sequencer 内部用 32-bit 或其他宽度
编码常用微操作，再译成这些信号；当前里程碑尚未选择该编码。上层已有
GROUP_EXEC reference frontend，它保存 opaque entry，并实现 RR live-head、
locked shadow 和 dispatch；`simd_cluster_exec_shell` 已把 full-decoded canonical
control 送入多个 datapath wrapper，并闭合 completion/result。当前仍没有真实
predecoder、compact canonical expander 或 class router，边界与候选组织见
[指令交付](../design/instruction-delivery.md)。

## 状态文件

```text
VRF-N：16 × (LANES × ELEM_W)，2 个组合读端口，1 个 masked 写端口
ARF：   8 × (LANES × ACC_W)，1 个组合读端口，1 个 masked 写端口
MRF：   4 × LANES bit，2 个组合读端口，1 个 masked 写端口
```

这些数量均为参数化实验默认值，不是 ISA 承诺。寄存器内容不上电复位，必须由外部初始化或由有效运算写入。

## 周期边界

读取、可选的局部路由、执行和 reduction 保持组合：

```text
RF async read → optional source-A route → lane execute → optional reduction
                                      └→ mask compact/expand + count
                                         └────────────→ clock-edge masked writeback
```

寄存器写入是状态提交边界，不是执行单元内部流水。当前 group 内没有
ready/valid、停顿和旁路；外层 `simd_group_wrapper` 已为 canonical EXEC/state-write
增加事务握手和返回缓存，但不改变这条裸数据通路的组合执行。外部控制每周期对
每个 SIMD4 最多发射一个满足当前组合时序的微操作。多个 group 的发射工作模型见
[集群控制](../design/cluster-control.md)。

## 物理 lane 与逻辑元素

默认 `ELEM_W=8` 表示物理 byte slice。`elem_mode_i` 将相邻 slice 组合为：

```text
BYTE: 4 x 8-bit
HALF: 2 x 16-bit
WORD: 1 x 32-bit
```

lane 0 是最低 byte。VRF 不保存元素类型；模式只影响当前发射操作。现阶段
`ADD/SUB/SHL/SHR_U/SHR_S` 和 `MIN/MAX/CMPEQ/CMPGT` 已使用动态元素边界。
加减由一条 byte-slice carry chain 完成，模式只控制 carry 在哪里重置；移位由
一套五级可分区网络完成，每个逻辑元素可读取自己的 shift amount。比较链从低
byte 向高 byte 传播 equal/greater 状态：更高 byte 不等时覆盖低位关系，只有
元素最高 byte 使用有符号比较。因此 HALF/WORD 不需要并列的宽 comparator。

`MIN/MAX` 根据这一整元素关系选择完整的 A 或 B，不允许逐 byte 混合来源。
比较谓词复制到组成逻辑元素的全部物理 byte lane；例如一个 HALF 比较为真时，
对应 MRF 位是 `11`，从而与现有“宽元素必须整体 masked”规则一致。

route、bitwise 和 MRF 存储仍保持 byte/bit 物理粒度。饱和、平均、绝对差、
绝对值、现有 MUL/MAC 和宽 ARF 操作明确保留 BYTE 语义；它们不会因为设置
HALF/WORD 就变成宽算术。已经接入的 `simd_uop_legal` 会拒绝这种混合解释，并
以统一 illegal 门控禁止全部执行副作用。

## 局部路由

`route_enable_i` 可以让 VRF source A 先经过一份局部 lane crossbar。逐输出索引覆盖
permutation、gather 和 broadcast；slide 从抽象的
`route_lower_i/route_upper_i` boundary ports 接收数据。cluster 首版由已占用并
验证有效的 boundary staging/ingress 驱动这些端口，不把它们解释成无仲裁的邻组
RF 组合读。路由非法时禁止执行写回和 reduction 有效结果。

单独的数据移动由 `PASS_A + route_enable_i + write_vrf_i` 组成。路由后的 A 也可以直接参与普通二元运算，所以不必总是先写一个临时 VRF 寄存器。详见[局部数据路由](routing.md)。

## 立即数形式

通常，`use_imm_i=1` 时 `imm_i` 按当前逻辑元素宽度广播，并在执行单元入口替代
VRF-B：

```text
BYTE: exec_b = repeat(imm_i[7:0])
HALF: exec_b = repeat(imm_i[15:0])
WORD: exec_b = imm_i[31:0]
```

`imm_i` 是 sequencer 已经解码和扩展后的最多四个 byte，不等同于指令中的原始
立即数字段。相同 ALU function 因此自然具有寄存器形式和立即数形式，
例如 ADD、逻辑运算、比较、移位、MUL/MAC、WIDEN、NCLIP 和 NSLICE；不需要
为每种 `...I` 语义复制操作码。`use_imm_i=0` 时仍从 VRF-B 逐 lane 取值。

`WADD/WSUB` 是例外：它们同时读取 VRF-A、VRF-B 和 ARF，立即数不替代 B，
而是作为两个窄源共用的固定点左移对齐量：

```text
use_imm=0: align = 0
use_imm=1: align = imm_i[log2(ACC_W)-1:0]
```

因此 WADD/WSUB 的立即数形式仍然只广播一个标量，但不会牺牲第二个 VRF 数据源。

行为寄存器文件目前仍组合读出 VRF-B。物理实现可以在立即数形式下门控该读口；
它不是立即数操作的语义读取需求。

## Mask 行为

- `mask_enable_i=0` 时所有 lane 激活；
- `mask_enable_i=1` 时从 MRF 读取执行 mask；
- 普通 VRF/ARF/MRF 执行写回使用每 lane 写使能；
- 未激活 lane 不写，因此不需要读取旧目标作为 `merge` 操作数；
- `select_mask_addr_i` 独立读取第二个 MRF 端口，供 `SELECT` 使用；
- 比较结果可以通过 `write_mrf_i` 写回 MRF。

HALF/WORD 执行时，一个逻辑元素只有在其全部 byte mask 位均为一时才激活，随后
有效位复制到整个元素。这禁止部分写入一个宽元素。`COMPRESS` 因而仍能按 byte
网络移动完整元素；`compact_count_o` 返回的是物理 byte 数。

## MRF 布尔运算

`MAND/MOR/MXOR/MNOT` 直接组合 MRF 内容：

```text
MAND dst, a, b = MRF[a] & MRF[b]
MOR  dst, a, b = MRF[a] | MRF[b]
MXOR dst, a, b = MRF[a] ^ MRF[b]
MNOT dst, a    = ~MRF[a]
```

为避免增加当前发射接口，`exec_mask_addr_i` 在这些操作中是 MRF-A 地址，
`select_mask_addr_i` 是 MRF-B 地址；`MNOT` 忽略 B。两者此时是数据操作数，
因此 `mask_enable_i` 不参与运算或写回门控。MRF 目的必须整行覆盖，才能将旧的
真值清零。

结果从 `predicate_result_o` 输出并可由 `write_mrf_i` 提交。窄结果端同时把每个
谓词物化为全一或全零元素，所以也可选择写入 VRF。例如 8-bit lane 中，真为
`0xff`，假为 `0x00`。

## 组内压缩与展开

`COMPRESS` 和 `EXPAND` 是组级操作，不属于独立 lane ALU：

```text
COMPRESS: VRF-A=[a,b,c,d], MRF=1010 -> result=[b,d,0,0], predicate=0011
EXPAND:   VRF-A=[b,d,x,x], MRF=1010 -> result=[0,b,0,d], predicate=1010
```

两者都保持活动元素的原始相对顺序，并输出 mask 的 population count：
`compact_count_o` 给出 `0..LANES`，`compact_valid_o` 表明本周期确实发射了合法的
压缩族操作。空 mask 因此产生 `count=0, valid=1`，不会与“没有结果”混淆。

压缩族使用 `exec_mask_addr_i` 读取 MRF；`mask_enable_i=0` 等同全 lane 有效。
其 VRF 写回强制覆盖整行，使非有效位置成为定义良好的零。若同时置
`write_mrf_i`，`COMPRESS` 写入低 `count` 位为一的 packed-valid mask，
`EXPAND` 写回原展开 mask。当前实现只在一个 SIMD group 内工作，不跨 group
搬运稀疏流。

压缩族和 MRF 布尔操作是普通 masked-write 规则的明确例外：它们在选择写回时
覆盖完整 VRF/MRF 目的行，因为零本身也是操作结果。

## 外部配置端口

`cfg_*` 端口用于初始化、状态传输和测试。裸 `simd_datapath` 中，配置写与执行写
同周期命中同一文件时由配置写优先。这只是叶模块仲裁行为；transaction wrapper
现在把 cfg 侧提升成带 `context+tag` 的 state-write 子事务，并与 EXEC 完全串行接受，
禁止已经 accepted 的执行写被静默覆盖。已有独立 `vsp_vrf_span_engine`
可以把 local SRAM/DMA 数据作为 VRF state-write beat 送入该 endpoint，并通过
export child 读回 VRF；它尚未与 wrapper 接通。地址推进和 program-level
completion 不在 wrapper 内。

## Reduction

窄执行结果可在同一组合路径上进入 reduction tree。裸 datapath 给出组合
value/index/valid，不写入内部标量寄存器；当前 group 事务边界由 wrapper 在接受沿
捕获进可背压 result buffer。现已能用一条外部微操作组合出
`ABSDIFF_U + REDUCE_SUM_U` 的 masked SAD。

## 尚未包含

- 跨整个 VSP 的任意 permutation/gather 网络；
- 标量寄存器到向量的广播路径（立即数广播已经存在）；
- 宽 ARF 输入的 reduction；
- 裸 datapath 内的 load/store、DMA 与二维地址生成；独立 VRF span
  engine 已实现，但未接到本 datapath/wrapper；
- 裸 datapath 内部的 ready/valid 和多周期单元；外层 group wrapper 已有事务握手；
- compact-uword predecoder、canonical expander 与 decoded group holding/path；cluster 层
  已有 queue、RR live-head 和 opaque locked shadow 组成的 GROUP_EXEC frontend；
- bank conflict、旁路及物理 SRAM 映射。
