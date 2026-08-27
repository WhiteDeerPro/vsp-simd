# 单通道 3×3 高斯驱动 `[工作负载证据]`

## 1. 目的与边界

本驱动是第一个以乘法和 ARF 生命周期为中心的代表性负载。它不增加专用高斯 RTL，也不把算法名称固化进执行单元；C++ 测试程序充当外部 sequencer，向现有 `simd_datapath` 发出微操作。

输入和输出均为单通道 unsigned 8-bit 图像。边界采用 zero padding，卷积核为：

```text
1 2 1
2 4 2  × 1/16
1 2 1
```

参考结果采用一次最终舍入：

```text
output = (weighted_sum + 8) >> 4
```

卷积最大累加值是 `255 × 16 = 4080`，当前 32-bit ARF 足够保存完整结果。该算法是有限窗口 FIR；ARF 的逐 tap 累加是微操作层的递推，不是递归/IIR 高斯滤波。

## 2. lane 映射

默认 SIMD4 的每个 lane 对应一个相邻输出像素：

```text
lane 0 → output[x+0]
lane 1 → output[x+1]
lane 2 → output[x+2]
lane 3 → output[x+3]
```

同一条微操作处理四个输出的同一个 tap。相比让四个 lane 合作计算一个点，这种映射不要求宽乘积的跨 lane reduction，并能利用相邻输出窗口之间的输入复用。

对一行中心向量：

```text
center          = [p[x],   p[x+1], p[x+2], p[x+3]]
SLIDE_UP(1)     = [p[x-1], p[x],   p[x+1], p[x+2]]
SLIDE_DOWN(1)   = [p[x+1], p[x+2], p[x+3], p[x+4]]
```

`p[x-1]` 和 `p[x+4]` 分别由 `route_lower_i` 和 `route_upper_i` 交付。图像首尾之外的数据由驱动置零。图像宽度不是四的倍数时，MRF tail mask 禁止无效 lane 提交 ARF 和 VRF 结果。

## 3. 微操作序列

测试使用以下临时分配；地址只属于驱动，不是架构约定：

| 状态 | 地址 | 内容 |
|---|---:|---|
| VRF | `v0/v1/v2` | 上一行、当前行、下一行的中心向量 |
| VRF | `v11` | 四个输出像素 |
| ARF | `a0` | 四个独立的完整精度累加值 |
| MRF | `m0` | 最后一个向量块的有效 lane |

卷积系数 `1/2/4` 和最终右移量 `4` 由立即数字段广播，不再占用 VRF row。

每个输出块发出十条执行微操作：

| 次序 | 行与列 | 系数 | 操作与写回 |
|---:|---|---:|---|
| 1 | 上一行，左邻 | 1 | `MUL_U imm → a0` |
| 2 | 上一行，中心 | 2 | `MAC_U imm, a0 → a0` |
| 3 | 上一行，右邻 | 1 | `MAC_U imm, a0 → a0` |
| 4 | 当前行，左邻 | 2 | `MAC_U imm, a0 → a0` |
| 5 | 当前行，中心 | 4 | `MAC_U imm, a0 → a0` |
| 6 | 当前行，右邻 | 2 | `MAC_U imm, a0 → a0` |
| 7 | 下一行，左邻 | 1 | `MAC_U imm, a0 → a0` |
| 8 | 下一行，中心 | 2 | `MAC_U imm, a0 → a0` |
| 9 | 下一行，右邻 | 1 | `MAC_U imm, a0 → a0` |
| 10 | `a0` | shift 4 | `NCLIP_U imm → v11` |

第一项 `MUL_U` 覆盖所有激活 ARF lane，因此不需要单独的 accumulator 清零操作。最后的 `NCLIP_U` 完成 round-to-nearest-up、右移四位和 8-bit unsigned saturation。

## 4. 每个完整 SIMD4 块的数据计量

四个相邻输出的联合输入窗口覆盖三行、每行六个位置，因此最多只引入 18 个不同像素，但向九个 tap 操作交付 36 个像素 lane operand：

| 类别 | 数量 | 说明 |
|---|---:|---|
| 唯一输入像素 | 18 element | `3 rows × 6 columns`，不计 padding 去重 |
| 像素 operand delivery | 36 lane | `9 taps × 4 lanes` |
| 系数立即数 delivery | 36 lane | 九个标量立即数各广播至四个 lane |
| shift 立即数 delivery | 4 lane | 最终右移量 4 广播至四个 lane |
| slide 边界交付 | 6 element | 三行各一个左边界和一个右边界 |
| 语义 VRF 窄读取 | 9 row | 每个 tap 只读取一条像素 row |
| 语义 ARF 读取 | 9 row | 八次 MAC 和一次 NCLIP；首个 MUL 不使用旧 ARF |
| 语义 MRF 读取 | 10 row | 每条执行微操作读取同一 tail mask |
| ARF 写入 | 9 row | 一次 MUL 和八次 MAC |
| 输出 VRF 写入 | 1 row | 最终四个或 tail-mask 后的有效像素 |
| 执行微操作 | 10 | 不含驱动串行进行的状态装载 |

当前行为模型始终组合读取 VRF 的两个端口和 MRF 的两个端口，即使某条操作在语义上不使用全部输入。物理实现应根据操作数使用信息门控无效读取，不能直接把行为模型的所有组合活动当作必要带宽。

立即数广播消除了三个系数 VRF row 及其读访问，但不会消除执行单元收到的
36 次系数 lane delivery；它改变的是系数来源和寄存器文件压力。

## 5. 对寄存器文件物理化的约束

九条乘法类微操作每周期语义上需要：

```text
1 × pixel VRF row read
1 × broadcast immediate
1 × ARF row write
```

后八条 MAC 还要求同周期读取旧的 `a0`。若 ARF 映射成不支持同周期读写的单端口 SRAM，就不能维持每周期一条 MAC；可以选择 1R1W、读写分级、累加器旁路或降低发射率。

`a0` 形成连续的 read-after-write 依赖链。当前组合读、时钟沿写模型允许下一周期看到刚提交的值；插入 MAC 流水线后必须传递目的地址和 mask，并定义 forwarding 或由 sequencer 插入依赖间隔。

使用立即数后，Gaussian 的 pixel/coefficient VRF bank conflict 不再存在；每条
乘法类微操作在语义上只读取一条 pixel row。其他真正使用两个 VRF 源的操作仍
需要单独分析 bank conflict。

## 6. sequencer 最小需求

该负载不要求数据相关分支。一个硬件 sequencer 至少需要表达：

- 图像行、四像素块和九个 tap 的循环状态；
- 当前三行的本地寄存器或 buffer 选择；
- 系数选择和 source-A route 模式；
- ARF 首次覆盖与后续 MAC 写回；
- tail mask；
- 最终 NCLIP 和输出提交；
- 与上游行/tile buffer 的数据可用事件。

测试驱动目前用配置写串行装载三条中心 row，并直接驱动相邻 group 边界输入。正式 VSP 可以让 line buffer、DMA 或相邻 SIMD group 交付这些数据，并与已有块的 ARF 计算重叠。

## 7. 后续映射

### 可分离 Gaussian

该核可以拆成水平和垂直两个 `[1,2,1]` pass，把每个输出的 tap 数从九个降到六个。但水平中间值最大为 1020，需要 10 bit。默认 8-bit VRF 无法无损保存它，ARF 又不能作为下一 pass 的窄乘法源。后续需要在以下方案中测量取舍：

- 每个 pass 都缩回 8 bit，接受两次舍入；
- 未来增加 HALF MUL/MAC 后，用 16-bit element 执行整个内核；当前 MUL/MAC
  明确是 byte-only，现有 RTL 不能直接采用此方案；
- 增加混合宽度 intermediate VRF 或宽输入 MAC 路径。

### 四 lane 合作一个输出

将九个 tap 分成 `4+4+1` 可以形成 dot-product 映射，但需要完整乘积的宽 reduction 和跨批次标量/宽累加。当前 `simd_reduce` 只接收窄执行结果，因此该映射暂不闭合。它适合作为后续比较负载，用来判断 `DOT4` 或独立 ARF wide reduction 是否值得增加。

## 8. 验证

`sim/gaussian3x3_tb.cpp` 使用现有状态化数据通路执行全部微操作，并与 C++ 零填充
参考模型逐像素比较；这里的路径和下方命令都从仓库根目录解释。覆盖内容包括：

- 全零、全 255、单点脉冲和确定性 ramp 图像；
- 随机宽高和随机像素；
- 宽度小于四及非四倍数的 tail mask；
- 上下左右图像边界；
- `SLIDE_UP/DOWN` 的相邻 group 边界 lane 标记；
- 完整乘积保存、连续 ARF MAC 和最终舍入窄化。

运行：

```bash
make test
```
