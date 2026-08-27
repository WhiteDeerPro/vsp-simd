# 定点宽窄转换语义 `[RTL事实]`

本文件定义执行单元当前采用的行为语义。6-bit 操作码只是内部验证编码，不代表
已经确定的 ISA 格式。

## 二输入平均

`AVG_U/S` 都先在 `ELEM_W+1` 位域中计算 A+B，再除以 2，并采用
round-to-nearest-up。无符号和有符号输入分别解释为：

\[
AVG_U(a,b)=\left\lceil\frac{unsigned(a)+unsigned(b)}{2}\right\rceil
\]

\[
AVG_S(a,b)=\left\lceil\frac{signed(a)+signed(b)}{2}\right\rceil
\]

因此负的半整数向正无穷方向取整，例如 `AVG_S(-1,0)=0`。平均值始终落在
两个输入之间，不需要饱和。多项平均仍由 sequencer 使用 route 和 AVG 组成
分层平均树；逐层舍入与先完整求和、最后只舍入一次并非同一数值语义。

## 独立条件选择

`SELECT` 对每个已激活 lane 执行：

\[
result = select ? a : b
\]

`mask_i` 决定 lane 是否提交结果，`select_i` 决定在 `a` 和 `b` 之间选择哪个值。二者不可混用。

专用 `SELECT` 的最终去留仍取决于寄存器文件端口：它也可以由普通 move 加 masked move 组合实现。

## 宽结果操作

当前支持：

| 操作 | 宽结果 |
|---|---|
| `WIDEN_U` | `zero_extend(a) << shift` |
| `WIDEN_S` | `sign_extend(a) << shift` |
| `WADD_U` | `acc + (zero_extend(a) << align) + (zero_extend(b) << align)` |
| `WADD_S` | `acc + (sign_extend(a) << align) + (sign_extend(b) << align)` |
| `WSUB_U` | `acc + (zero_extend(a) << align) - (zero_extend(b) << align)` |
| `WSUB_S` | `acc + (sign_extend(a) << align) - (sign_extend(b) << align)` |

`MUL_U/MUL_S` 已经产生 `2*ELEM_W` 位乘积，`MAC_U/MAC_S` 使用 `ACC_W` 位累加输入。

`WIDEN_U/S` 先把 VRF-A 扩展到 `ACC_W`，再在宽域左移。移位量来自
VRF-B 或广播立即数的低 `log2(ACC_W)` 位；移位量为零时就是原先的普通
widening。它与 `NSLICE` 可以组成明确的 VRF → ARF → VRF 位域往返：

```text
ARF  = WIDEN_U(VRF, shift=8)
VRF' = NSLICE(ARF, shift=8)
```

`WADD_U/S` 使用两个 VRF 读源作为数据。A、B 分别扩展到 `ACC_W`，使用同一个
广播标量 `align` 左移，然后与旧 ARF 一起进入三输入宽加法器：

```text
aligned_a = extend(VRF-A) << align
aligned_b = extend(VRF-B) << align
ARFdst    = ARFsrc + aligned_a + aligned_b
```

`use_imm=1` 时立即数在本指令族中表示公共 `align`，不会替代 VRF-B；
`use_imm=0` 时 `align=0`。这使一个 ARF 读口、两个 VRF 读口恰好形成
`ACC+A+B` 三个数据输入。逐 lane 可变 shift 仍由 WIDEN、移位和宽窄转换操作
保留，不再占用 WADD/WSUB 的第二个数据源。

`WSUB_U/S` 使用完全相同的三个输入和公共对齐量：

```text
ARFdst = ARFsrc + aligned_a - aligned_b
```

硬件用一级 3:2 compressor 把三个 `ACC_W` 操作数压成 sum/carry，再经过一次
进位传播加法产生单个 ARF 结果。WSUB 对 B 取反并在最低位注入 1，实现二补码
减法。compressor 的 sum/carry 只是内部信号，不形成双目的寄存器写回。

`WADD_S` 配合负的 signed B 已经可以表达减法，但仍保留 `WSUB_S`，使 U/S 和
ADD/SUB 组合保持对称，也避免软件先构造负数。

## 定宽算术策略

普通 `ELEM_W` 和 `ACC_W` 算术遵循定宽回绕语义。硬件不为普通整数溢出产生异常，也不自动扩展目标宽度；需要饱和时必须显式使用带 `SAT` 或 `NCLIP` 语义的操作。

这一约定使每条微操作的结果宽度固定，sequencer 不需要处理隐式整数异常。算法和编程层根据所需数值语义选择普通回绕操作或显式饱和操作。

## 舍入数值缩放

`RSHIFT_RND_U/S` 从 `acc_i` 读取宽值，移位量取自 `b_i` 的低 `log2(ACC_W)` 位。

令移位量为 `s`。当 `s=0` 时结果保持不变；当 `s>0` 时：

\[
rounded=(value\;\mathrm{shift}\;s)+bit(value,s-1)
\]

无符号操作使用逻辑右移，有符号操作使用算术右移。这对应 round-to-nearest-up：最高被丢弃位为 1 时，向已经右移的结果加一。

这一操作调整的是定点数值比例，不是图像空间尺寸。

## 直接窄位截取

`NSLICE` 从 `acc_i` 读取宽值，移位量与其他缩放操作相同，取自 `b_i` 的低 `log2(ACC_W)` 位。它执行逻辑右移，然后直接返回低 `ELEM_W` 位：

\[
NSLICE(x,s)=(x \mathbin{\mathrm{>>}} s)\bmod 2^{ELEM_W}
\]

`NSLICE` 不舍入、不饱和，也不区分 signed/unsigned。默认 `ELEM_W=8、ACC_W=32` 时：

```text
NSLICE(0x123456f0,  0) = 0xf0
NSLICE(0x123456f0,  8) = 0x56
NSLICE(0x123456f0, 16) = 0x34
NSLICE(0x123456f0, 24) = 0x12
```

它与 `NCLIP` 共享“从宽累加值按移位量产生窄结果”的接口，但绕过 round 和 saturation。典型用途包括定点 bit slice、byte-plane 提取以及由微码组成的多周期宽数据操作。结果写入 `result_o`，在状态化数据通路中预期写回 VRF；源 ARF 不原位修改。

## 饱和 Narrow

`NCLIP_U/S` 复用上述舍入右移，然后限制到目标元素范围：

\[
NCLIP_U(x,s)=\operatorname{sat}_{[0,2^{ELEM_W}-1]}
(\operatorname{rshift\_rnd}_U(x,s))
\]

\[
NCLIP_S(x,s)=\operatorname{sat}_{[-2^{ELEM_W-1},2^{ELEM_W-1}-1]}
(\operatorname{rshift\_rnd}_S(x,s))
\]

最后写入 `result_o`。例如 `ELEM_W=8` 时：

```text
NCLIP_U(300, 0) = 255
NCLIP_U(300, 1) = 150
NCLIP_S(200, 0) = 127
NCLIP_S(-180, 0) = -128
```

这条路径可表达颜色矩阵、卷积输出、插值、置信度加权和多帧融合中常见的“宽累加 → 定点缩放 → 8-bit 输出”。

## 尚未决定

- 是否增加 ties-to-even、向零、向负无穷和 round-to-odd；
- 未来编码中如何分配立即数字段，以及是否再加入标量寄存器源；
- 最终 compact uword 如何编码立即数和 shared align；
- narrow 是否与 cluster exchange/pack 融合；
- `SELECT` 使用三源读，还是由 masked move 合成。
