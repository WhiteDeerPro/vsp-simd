# 32-bit byte 卷积乘法微码参考模型

> 当前状态：仅保留数值与调度参考模型，不属于 RTL 操作族，也不占用操作码。
> 文中的 `PMAC8` 是“一次 byte 部分积累加步骤”的建模记号，不承诺最终硬件
> 必须以同名、同粒度的指令实现。

## 数值语义

本模型的目标语义是 32-bit `MUL` 保存乘积低 32 bit；参考映射只使用 8×8
部分积，不要求 16×16、32×32 或 64-bit 结果寄存器。其他硬件映射没有因此被
排除。

令 byte 0 为最低 byte：

```text
A = [a3 a2 a1 a0]
B = [b3 b2 b1 b0]
```

低 32-bit 结果只需要卷积的前四条对角线：

```text
q0 = a0*b0
q1 = a0*b1 + a1*b0
q2 = a0*b2 + a1*b1 + a2*b0
q3 = a0*b3 + a1*b2 + a2*b1 + a3*b0

result = q0 + (q1 << 8) + (q2 << 16) + (q3 << 24) mod 2^32
```

更高的 `q4..q6` 只影响完整 64-bit 乘积，当前不计算。有符号与无符号
32-bit 二补码相乘的低 32-bit pattern 相同，因此 WORD 模式不需要两套卷积。

## 无部分积压缩器的基线微码

先用一个窄微码步骤描述计算，而不是指定大乘法器。参考记号带一个初始化
modifier：

```text
PMAC8 init, ARFacc, A.byte[i], B.byte[j], align
    partial = (u8(A[i]) * u8(B[j])) << align
    init=1: ARFacc = partial mod 2^32
    init=0: ARFacc = ARFacc + partial mod 2^32
```

如果以后将该步骤映射到硬件，它只需要 byte selector、一个 8×8 multiplier、
8-bit 倍数对齐和现有 32-bit 累加链。参考模型中的 WORD 乘法展开为十步：

| 次序 | init | A byte | B byte | align |
|---:|---:|---:|---:|---:|
| 0 | 1 | 0 | 0 | 0 |
| 1 | 0 | 0 | 1 | 8 |
| 2 | 0 | 1 | 0 | 8 |
| 3 | 0 | 0 | 2 | 16 |
| 4 | 0 | 1 | 1 | 16 |
| 5 | 0 | 2 | 0 | 16 |
| 6 | 0 | 0 | 3 | 24 |
| 7 | 0 | 1 | 2 | 24 |
| 8 | 0 | 2 | 1 | 24 |
| 9 | 0 | 3 | 0 | 24 |

第 0 条用 `init=1` 覆盖目的 ARF，后续九条累加。如果未来候选硬件不提供该
modifier，就必须先显式清零 ARF，总序列成为十一条；不能同时把纯累加 PMAC8 和
“首条自动覆盖”当成同一语义。这里没有隐藏的多周期状态，ARF 是微码可见的
中间状态。

当前 RTL 不加入 `PMAC8` 的 byte-pair selector、product alignment 或操作码。
本页只记录“多 byte 乘法是 base-256 数字卷积”这一算法事实和候选调度，不宣称
十步微码现在能够直接发射。数值模型由 `sim/mul32_microcode_tb.cpp` 验证；该路径
相对于仓库根目录。

## 可选的对角线加速

若十条串行 `PMAC8` 成为瓶颈，可以让现有四个 8×8 multiplier 同时计算一条
对角线，并用 CSA/Wallace 网络把最多四个部分积与 ARF accumulator 合并：

```text
CONV_DIAG diag=0  // 1 partial
CONV_DIAG diag=1  // 2 partials
CONV_DIAG diag=2  // 3 partials
CONV_DIAG diag=3  // 4 partials
```

这样 WORD 乘法降为四条微操作，但需要跨 multiplier lane 的部分积压缩路径。
低 32-bit 乘积属于目标功能语义；base-256 卷积分解和四路 compressor 都是候选
硬件映射。当前保留验证模型，等代表性负载说明串行路径是否构成瓶颈后再比较
硬件方案。
