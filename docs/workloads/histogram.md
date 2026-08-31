# 8-bit 图像直方图：当前基线与 256-bin 映射缺口 `[工作负载探索]`

## 1. 当前结论

当前能够直接证明的是 **4-bin predicate/reduction 基线**：
[`histogram_4bin_test.uasm`](../../examples/uword/histogram_4bin_test.uasm)
可被现有 uword assembler 接受。它把一个 8-bit 像素映射到四个区间之一，逐 lane
构造相等谓词，再对每个 SIMD4 group 做求和规约。

当前尚不能据此声称已经得到可独立运行的 256-bin 直方图程序。现有
`VGATHER/VSCATTER` 提供了 indexed byte memory access，但没有提供原子递增；当前
group 地址生成、HALF 数据布局和 reduction 结果通路也不足以直接落实此前设想的
“四组私有 16-bit bins + 最终合并”。

因此本文件的性质是负载探索与缺口清单，不是完成报告，也不据此决定必须增加哪一种
专用硬件。

## 2. 已闭环的 4-bin 基线

### 2.1 映射

对于每个 byte lane，现有示例计算：

```text
bin_id = pixel >> 6
diff   = absdiff(bin_id, k)
neq    = min(diff, 1)
eq     = 1 - neq
```

其中 `k=0..3`。随后四次 `EXEC_REDUCE sum_u` 分别产生四个 bin 的 group-local
计数。一个 SIMD4 group 每次贡献 `0..4`；当启动 mask 选择四个 group 时，一次
16-byte `VLOAD` 把连续的四个 byte 分配给每个 group。

### 2.2 证明范围

这条基线证明了：

- `VLOAD` 可以把连续 byte 数据送入当前四组执行阵列；
- `SHR_U/ABSDIFF_U/MIN_U/SUB` 可以构造精确的 byte 谓词；
- `EXEC_REDUCE sum_u` 可以得到每个 SIMD4 group 的命中数；
- 当前 assembler 能表达并检查这段序列。

它没有证明：

- 在程序内部把各 group、各 tile 的 reduction 结果累加成全局计数；
- 把最终计数写入数据内存；
- 完成图像遍历、tail 处理及 256 个精确 bin；
- indexed scatter 可以承担原子 histogram increment。

当前可以用以下命令检查该基线的编码：

```bash
python3 tools/vsp_uword_asm.py \
  examples/uword/histogram_4bin_test.uasm \
  -o /tmp/histogram_4bin.hex
```

## 3. 与本负载有关的现有硬件语义

### 3.1 Indexed memory

当前语义为：

```text
VGATHER:  vd[lane] = MEM[state[sbase] + simm16 + u8(vi[lane])]
VSCATTER: MEM[state[sbase] + simm16 + u8(vi[lane])] = vs[lane]
```

一个 indexed command 对每个 selected group 的四个 lane 都生效；尚无 indexed
memory 的独立 byte predicate。参考 memory engine 按 `(group, lane)` 顺序发出访问，
因此重复 gather index 可以读出相同 byte，重复 scatter index 则是确定性的
later-lane-wins。后者不是 read-modify-write，也不等价于原子加。

一个 command 只有一个 `sbase` 和一个 signed offset。它们被所有 selected group
共享；当前没有隐含的 `group_id * private_stride` 地址项。

详见 [Indexed gather/scatter guide](../scatter_operations_guide.md)。

### 3.2 Unit-stride memory 与 group mask

程序启动时确定 active group mask，当前 encoded program 不在每条指令中更换它。
对于显式 unit-stride span，memory engine 要求：

```text
ceil(span_bytes / 4) == popcount(active_group_mask)
```

例如四组启动时，`span=16` 是匹配的；同一程序中的 `span=4` 不会自动只选择第一组。
这会影响算法的 tile 宽度、清零过程和 tail 方案。

### 3.3 HALF element

SIMD4 的物理 row 是四个 byte。`mode=half` 将相邻 lane 组成两个 16-bit element：

```text
byte lane:   [3] [2] [1] [0]
half elem:   [  elem1 ] [  elem0 ]
```

所以一个 group 的一条 VRF row 只能同时保存两个 16-bit counter。若 low bytes 与
high bytes 分别位于两条 VRF row，直接对两条 row 做 `SHL mode=half` 与
`OR mode=half`，不会得到四个逐 lane 的 16-bit counter；它只会按各自 row 内的
相邻 byte 配对。

### 3.4 Reduction 结果

当前 reduction completion 带有 group-local scalar result，适合由 testbench、host
或上级 sequencer 收集。encoded program 目前没有把该 result 直接写回 state RF、
VRF 或 data memory 的通路。因此“逐 tile reduction”还不能独自在程序内部形成最终
直方图。

## 4. 256-bin standalone 映射的主要缺口

### 4.1 同组重复 index

假设四个 lane 的像素均为 `x`：

```text
gather  -> [old, old, old, old]
add 1   -> [old+1, old+1, old+1, old+1]
scatter -> later-lane-wins -> old+1
```

正确结果应为 `old+4`。因此“每个 group 一份私有直方图”只可能消除 group 之间的
竞争，不能消除一个 SIMD4 group 内的重复 index。精确实现至少需要以下路线之一：

- 在 scatter 前识别并合并同值 lane，再只提交唯一 index；
- 给 lane 或更小的 conflict domain 分配私有 bins，再做归并；
- 提供具有明确顺序、fault 和 cache 语义的 atomic increment；
- 避开 scatter，改用逐 bin predicate/reduction 算法。

前三种路线都尚未在当前 encoded program path 中闭环。

### 4.2 Group-specific private base

四个 group 并行维护四份 512-byte 直方图，需要每个 group 使用不同的有效基址。
当前一个 memory command 向所有 selected group 广播同一 `state[sbase]+offset`，
`INDEX_U8` 也只有 256-byte index 范围。因此下列布局不能仅靠一条当前指令并行寻址：

```text
group 0 -> hist_base + 0x000
group 1 -> hist_base + 0x200
group 2 -> hist_base + 0x400
group 3 -> hist_base + 0x600
```

可能的闭环方式包括 group-relative address term、按 group 分开发射/启动，或改变
私有数据布局；尚未选定其中一种。

### 4.3 16-bit counter layout

两种自然布局各有不同缺口：

| 布局 | 地址形式 | 当前优点 | 当前缺口 |
|---|---|---|---|
| packed/AoS | `2*bin + {0,1}` | 连续 `VLOAD` 后可直接用 HALF 运算 | `INDEX_U8` 不会计算 `2*index`，完整表跨 512 bytes |
| planar/SoA | low 在 `bin`，high 在 `256+bin` | 两次 indexed byte access 可取得高低 byte | 两条 row 不能直接重组为四个逐 lane HALF element；递增还需要 byte carry 路径 |

在选定布局前，软件参考文件也必须明确是 packed little-endian 还是 planar；两者不能
直接逐 byte 比较。

### 4.4 Reduction 写回与归并

逐 bin predicate/reduction 可以完全避免 scatter collision，但它需要把每个 group、
每个 tile 的 scalar result 累加并存储。当前 result 只出现在 completion channel，
所以可由 host 驱动完成，却尚不是 standalone encoded program。需要先决定：

- reduction result 是否写入 state RF；
- 是否提供 scalar store，或经广播写入 VRF 后再 `VSTORE`；
- group-local results 由硬件、sequencer 还是软件归并。

### 4.5 Tail 与有效 lane

Indexed memory 当前按整组四 lane 工作，没有独立的 byte predicate。图像长度不是
active lane 数整数倍时，不能仅用 EXEC mask 阻止越界 memory side effect。需要由
padding、单独的尾部启动/命令，或未来的 memory predicate 明确定义尾部行为。

## 5. 候选推进路线

### 路线 A：先闭环 predicate/reduction

把现有 4-bin 基线扩展成 256 次 bin 扫描：每次对一个 `k` 构造相等谓词并规约。
它访存和执行次数较多，但没有重复-index 写冲突，适合作为正确性基线。其首要缺口是
reduction result 的程序内累加和存储，随后还需按第 6 节闭环循环与 tail。

### 路线 B：冲突感知的 indexed update

保留一次扫描图像的目标，在 SIMD4 内对重复 index 做合并，并让每个唯一 index 只
更新一次。该路线需要 lane equality、winner/count 生成以及 indexed memory predicate
协同，是否值得形成硬件 feature 需要用负载测量决定。

### 路线 C：真正的私有 bins

把 private domain 收缩到不会发生并发冲突的颗粒，再做分层归并。该路线需要同时解决
private base、存储容量、16-bit layout 和归并带宽，不能只通过把内存划成四段完成。

当前不在这三条路线之间提前作架构决定。路线 A 最适合先建立精确、可回归的程序基线；
路线 B/C 可在基线存在后比较吞吐、存储和控制成本。

## 6. 后续验收条件

256-bin standalone 版本只有同时满足以下条件，才应称为“实现完成”：

1. 源码可由当前 assembler 接受，并包含实际的初始化、循环、tail 与 `END`；
2. 在 program wrapper 与 memory model 上执行，而不是只验证 host reference；
3. 明确并统一 counter memory layout；
4. 覆盖同组重复 index、跨组重复 index、全部 index 唯一三类输入；
5. 覆盖 `0x00ff -> 0x0100` carry、bin 0、bin 255 和非整 tile 尾部；
6. 输出逐 bin 等于独立软件参考，并满足所有 bin 之和等于输入像素数；
7. 文档中的 action 数按“每条 cluster command、每个 group operation、每个 lane
   memory request”分别计量，避免混用 SIMD4 与四组 cluster 的吞吐口径。

相关边界还可参阅 [Sequencer state](../design/sequencer-state.md)、
[EXEC uword profile v0](../design/exec-uword-profile-v0.md) 与
[Routing architecture](../architecture/routing.md)。
