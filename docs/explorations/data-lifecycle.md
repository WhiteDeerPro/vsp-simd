# 数据产生、交付、消费与退休 `[分析方法]`

## 1. 讨论边界

本页记录 SIMD/VSP 数据流的计量方法和若干设计启发，不规定最终端口数、packet
宽度或 buffer 深度。解析计数与 trace 都是证据来源；何时使用哪一种取决于 burst、
复用和可变速率的复杂度。

“产生一个值”“通过网络复制一个值”“写入一个存储位置”不是同一件事。为避免速率
数字失去含义，记录时同时注明：

- 观察边界，例如执行单元、SIMD group、VSP 或外部存储；
- 数据单位，例如 element、lane delivery、row/beat、逻辑 vector 或 bit；
- 时间单位，例如单周期峰值、连续 burst 或整个 tile/frame 的平均值。

## 2. 六类基础速率

### 新值产生率

每周期产生多少个新的逻辑值或版本。它描述数据依赖图，不直接等于物理写端口数量。

### 存储写入率

每周期分别向 VRF、ARF、MRF、局部 SRAM 和输出队列写入多少 row/beat 及多少 bit。不同存储文件的写入可以并行发生，不能只相加为一个模糊的“向量写入数”。

### 网络交付率

crossbar、广播树或 NoC 每周期向多少目的端交付数据。一次源读取可以产生多次交付。

### 唯一输入摄入率

每周期真正从上游、DMA 或局部存储引入多少不同数据。局部复用和 broadcast 可以使操作数交付率大于唯一摄入率。

### 操作数读取率

执行单元每周期读取多少操作数。同一个寄存器可以被多条指令和多个 lane 重复读取；读取不表示数据立即消失。

### 数据退休率

每周期有多少存储位置完成最后一次使用，可以重新分配或覆盖。退休通常只是 liveness/valid 元数据变化，不需要把数据写零。

## 3. 产生、复制与物化

以 SIMD4 route 输出 `[A, A, B, B]` 为例：

```text
不同源值：          2
crossbar 源读取：   2
lane delivery：     4
SIMD4 输出 row：    1
写回本地 VRF：      至多 1 row
```

因此 lane broadcast 放大的是 fanout 和交付率，并不自动增加本地 VRF 的 row 写入率。如果同一个值被送往四个 SIMD group 并分别存入它们的本地 VRF，则源端仍可只读取一次，但 VSP 范围内会发生四次分布式目的写入。

公共系数、阈值和控制量可以优先评估使用时广播，以避免提前物化许多相同的 VRF
副本；若广播扇出或时序代价更高，也可以选择分层缓存。

## 4. 物理宽度与逻辑数量

`1/2/4/8/...` 是物理接口、bank 数和 packet 宽度的常见候选，因为它们便于二进制
地址拆分、bank 选择、burst 对齐和控制编码；这不是排除非二次幂组织的接口约束。

逻辑负载仍然可以包含任意数量的数据。例如逻辑上需要三条 row 时，通常使用 4-wide 物理传输并携带有效信息：

```text
packet_data  = {row3, row2, row1, row0}
packet_valid = 4'b0111
```

也可以分解成 `2+1` 两次传输。逻辑数量为 3 是正常情况；没有必要因此制造一个专用 3-wide 端口或三个对称 bank。

当前默认 `LANES=4、ELEM_W=8`，一个窄 VRF row 为 32 bit。若实验性 ingress packet 取 128 bit，它正好携带四个窄 row；但可以先进入 staging FIFO，再通过较窄的 VRF 写口逐条展开。总线 packet 宽度与寄存器文件单周期写地址数不必相同。

## 5. 运算的典型速率

| 运算 | 逻辑输入 | 逻辑输出 | 备注 |
|---|---:|---:|---|
| 一元逐元素 | 1 vector | 1 vector | live 数据量通常不变 |
| 二元逐元素 | 2 vector | 1 vector | 无复用时可能要求两条输入 row/周期 |
| MAC | 2 narrow + 1 accumulator | 1 accumulator | 跨 VRF/ARF 发生读写 |
| WADD/WSUB | 2 narrow + 1 accumulator + 1 shared align | 1 accumulator | 三输入 compressor 后单 ARF 写回 |
| SELECT | 2 vector + 1 mask | 1 vector | mask 是独立输入域 |
| broadcast | 1 source | 多个 delivery | 是否产生多个存储写取决于是否物化副本 |
| FFT butterfly | 2 complex | 2 complex | 专用单元可多结果；微操作实现可分周期写回 |
| reduction | 多个元素或部分结果 | 1 scalar/vector | 产生率低而退休率高 |
| compress | 1 vector + mask | 可变数量元素 | 可能产生 burst，需要 count/valid 与队列 |
| widen | 1 narrow vector | 1 wide vector | token 数不变，但 bit 写入量增加 |
| unzip/segment load | 1 次操作 | 多个 vector | 可串行化，也可要求多目的写入 |

读取数不等于退休数。卷积窗口、FFT twiddle、阈值和模型参数可以被重复使用；只有最后一次读取完成后，相应位置才退休。

## 6. 最坏情况包含 burst

只统计整段平均值不能确定端口和 buffer。最坏情况至少包含：

- 单周期最大产生、交付、写入和退休数量；
- 峰值能够连续保持多少周期；
- burst 之间的最短间隔；
- 多个源或多个 SIMD group 的 burst 是否可能重叠；
- 上游是否允许 backpressure。

对一个队列，可以用以下关系检查 occupancy：

```text
Q(t+1) = Q(t) + produced(t) - consumed(t)
```

最大累计差决定所需 buffer 深度。若上游可停顿，超过持续能力的合法 burst 可以通过 ready/valid、排队或分周期提交保持正确性；若传感器输入不可停顿，则必须由足够的行缓冲、tile buffer 或帧存储吸收最坏 burst，并保证长期处理率满足输入率。

应分别考察单周期、短窗口、tile 和整帧尺度，而不是把平均值或瞬时峰值单独当成完整结论。

## 7. 当前数据通路的基线

当前 `simd_datapath` 是单发射、无内部流水的行为模型：

- 每周期对 VRF 最多提交一个 row；
- 每周期对 ARF 最多提交一个 row；
- 每周期对 MRF 最多提交一个 row；
- 三个文件相互独立，因此外部控制可以让不同文件同周期写入；
- reduction 结果通过独立标量出口返回；
- 裸 datapath 中配置写与同一文件的执行写共用写口，配置写优先；已实现的
  `simd_group_wrapper` 把它提升成 state-write 子事务，并与 EXEC 完全串行接受；
- route 的 lane broadcast 可以产生多个 delivery，但仍只形成一个本地窄结果 row；
- 多个 SIMD group 同时工作时，VSP 聚合写入和交付率按活跃 group 数增长。

该基线不表示所有未来操作必须只有一个逻辑结果。FFT butterfly、unzip、segment load 等多结果操作可以先拆为多条微操作；只有在代表性负载证明串行化成为瓶颈后，才考虑增加同一文件的写端口或专用结果队列。

## 8. Ping-pong 与退休

若整个窗口按块经历 `FILL → READY → EXECUTE → DRAIN`，两个窗口交替所有权，这是 block-level ping-pong。双缓冲能够无停顿工作的条件近似为：

```text
inactive window 的 drain 时间 + refill 时间 <= active window 的计算时间
```

若计算过程中逐条退休寄存器并立即滚动填入新数据，则更接近 circular buffer 或 sliding register window，需要逐项 valid、最后使用信息或 producer/consumer credit，不能只依靠一个全局 ping/pong bit。

## 9. 后续评估方法

在决定端口数前，可以先为代表性内核手工列出每次迭代或每个 butterfly 的：

- 唯一输入 row；
- VRF/ARF/MRF 读取与写入；
- 网络 delivery 和 fanout；
- 可复用数据及复用周期；
- 产生和退休的临时值；
- 最大连续 burst；
- ingress、egress 和计算周期的重叠关系。

至少覆盖二元逐元素运算、滑窗滤波、FFT64、reduction、compress 和跨 group broadcast。若这些表格无法可靠推导 buffer occupancy 或不同内核组合后的 burst，再增加 trace 驱动的统计工具；当前不把 trace 模型列为立即实现项。

首个滑窗实例已经建立，见[单通道 3×3 高斯驱动](../workloads/gaussian3x3.md)。
它把四个相邻输出映射到 SIMD4，在每个完整输出块中区分了 18 个唯一输入像素、
36 次像素 lane delivery、VRF/ARF row 读取和写入，以及六个相邻 group 边界
element delivery。

端口速率只能说明聚合服务能力，不能单独证明不存在 bank conflict。物理化分析还必须为每个微操作记录寄存器地址、`bank(address)` 和每个 bank 的单周期访问数。高斯驱动已用广播立即数替代 coefficient row，因此它的 MAC 只语义读取一条 pixel VRF row；二元 VRF 操作仍可能需要复制、广播、重排、分拍或停顿。
