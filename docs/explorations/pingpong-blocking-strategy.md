# Ping-pong VRF 双缓冲：顺序基线与重叠候选

> 状态：探索与 workload 基线。当前产品路径按 program order 严格串行执行，
> 本文中的 ping-pong 只表示两组互不覆盖的 VRF row 布局；计算/访存重叠尚未实现。

## 1. 当前可以验证什么

当前 4-group profile 中，每个 group 有 4 个 byte lane。launch 使用完整
`group_mask=4'b1111` 时，一条 `span=16` 的 `VLOAD/VSTORE` 在一个 VRF row 上搬运
16 byte：每个 group 各 4 byte。

当前可执行路径还具有以下边界：

- sequencer state RF 默认是 32 个 32-bit register，能够保存 input/output base；
- unit-stride `VLOAD/VSTORE` 使用 `state[sbase] + signed_offset`；
- controller 是 global single-active，一项 action 完成后才接纳下一项；
- vector memory engine 每次只有一个 active parent 和一个 outstanding D-side beat；
- `LOCAL` 是当前 D-side 合同中的逻辑地址空间，仿真可由 dmem model 承接，但不代表
  已经实例化物理 local SRAM；
- dmem model 可配置 response latency，但增加 latency 只会拉长当前串行执行时间。

`INDEX_U8` gather/scatter 的 8-bit index 可以在 base 后的 256-byte 地址窗口中选点，
但单条指令只搬运被选 group 的 lane：当前 full-mask 实例是 16 byte，参数化上限是
16 group/64 byte。这个 256-byte 地址覆盖范围不是 unit-stride block size，也不是一次
传输 256 byte。

## 2. 双 VRF bank 布局

示例 [`pingpong_buffer_test.uasm`](../../examples/uword/pingpong_buffer_test.uasm)
处理两个 64-byte block，假定每个 group 有 16 个 VRF row：

| 用途 | block 0 | block 1 | 容量 |
|---|---|---|---:|
| input rows | VRF 0..3 | VRF 4..7 | 每组 64 byte |
| output rows | VRF 8..11 | VRF 12..15 | 每组 64 byte |

这里的 bank 是软件分配的 row 集合，不是新增的物理 RF bank 或 local-memory buffer。
16 个 row 被全部占用，因此该布局没有额外 temporary row；更复杂的 kernel 应缩小 block、
复用已经 store 的 row，或者重新分配 input/output/temp 的 row 比例。

当前实际顺序为：

```text
LOAD block 0  -> rows 0..3
EXEC block 0  -> rows 8..11
LOAD block 1  -> rows 4..7
STORE block 0 <- rows 8..11
EXEC block 1  -> rows 12..15
STORE block 1 <- rows 12..15
END
```

block 1 的输入与 block 0 的输出可以同时驻留在 VRF 中，但这些 action 不会同时运行。
这种静态分区的价值是先验证 row 生命周期、地址推进和结果正确性，也为未来并发实现提供
一个没有 VRF row 冲突的定向 workload。

## 3. 当前示例合同

示例使用默认 4 KiB dmem model 可覆盖的地址：

```text
0x0100..0x017f  input：两个连续的 64-byte block
0x0200..0x027f  output：两个连续的 64-byte block
```

launch 必须提供完整四组 mask。`span=16` 要求
`ceil(span/4) == popcount(group_mask)`；若只选择部分 group，命令会被判为非法，不能把
未选 group 当作隐式填零。

每个 byte 执行：

```text
output = (input + 1) * 2 mod 256
```

程序固定展开两个 block，不依赖 loop。当前 sequencer 已支持 `J` 以及
`BEQ/BNE/BLT/BGE/BLTU/BGEU`；这里保留展开形式，是因为 VRF row 编号编码在 memory/EXEC
action 中。以后若要循环使用两套 row，可写两个静态 phase，再由 branch 在 phase 边界回跳。

该程序共 61 个 32-bit stream word，能够放入当前默认的 64-word control store。

## 4. 正确的传输与延迟计量

full-mask 下，一条 16-byte unit-stride command 在 memory engine 内分解为 4 个 4-byte
D-side beat。因而一个 64-byte block 是：

```text
4 commands/block * 4 beats/command = 16 D-side beats/block
```

STORE 还需要相应的 VRF read child，LOAD 返回后需要 VRF write child。不能用
“4 条 VLOAD × 一次 memory latency”估计完整 block 延迟。

当前串行基线的总时间应按求和理解：

```text
T_total = T_load0 + T_exec0 + T_load1 + T_store0 + T_exec1 + T_store1
```

调高 dmem response latency 可以验证 backpressure 和串行等待，但不能测出 latency hiding。

## 5. 未来怎样形成真实 overlap

静态双 row 集合本身不等于预取。要让 `LOAD block N+1` 与 `EXEC block N` 真正并行，至少
还需要：

1. controller 允许 EXEC 与 MEMORY action 同时 active，并仍能按定义退休和报告错误；
2. admission 能识别 source/destination VRF row，阻止 RAW/WAR/WAW 冲突；
3. shared VRF port、memory child traffic 和 result completion 有明确仲裁与背压合同；
4. trace 证明重叠收益足以覆盖新增状态和端口成本。

多个 D-side outstanding request 可以进一步提高 memory throughput，但它不是建立第一版
EXEC/MEMORY overlap 的唯一前提；即使 memory engine 仍单 parent，也可以先研究一项 memory
action 与一项无冲突 EXEC action 的并行。

只有上述条件成立后，稳态 block 时间才可能接近：

```text
T_block ~= max(T_compute, T_memory)
```

## 6. 验证路线

1. assembler smoke：示例必须由当前 `vsp_uword_asm.py` 无错误生成 61 words；
2. 顺序功能测试：初始化 128-byte input，以 `group_mask=0xf` launch，检查 128-byte output；
3. latency scan：改变 dmem response latency，记录当前串行基线，而不称其为重叠收益；
4. controller 将来支持受约束的 EXEC/MEMORY concurrency 后，复用相同 row 布局比较周期数；
5. 再映射卷积、FFT 蝶形等具有足够计算密度的 block kernel。
