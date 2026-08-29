# 单通道 3×3 Median

> 状态：工作负载证据。当前 Verilator 回归把四个相邻输出像素放在 SIMD4 的四个
> physical lane，把每个像素的九个 tap 放在九个 VRF row。它验证现有逐 lane
> `MIN_U/MAX_U/PASS_A` 能组成正确 median-of-nine，不代表当前序列已经最优。

## 映射

```text
VRF p0..p8 : 九个空间 tap
lane 0..3  : 四个互相独立的输出像素
result     : p4
```

因此这里需要的是“同一 lane、跨 VRF row”的 compare-exchange。SIMD4 horizontal
reduction 会把四个不同输出像素混到一起，不能用于这个布局。已有
`REDUCE_MIN/MAX_{U,S}` 仍适合一行四个 lane 合作求一个标量的另一类布局。

## Selection network

当前使用 19-comparator median-of-nine network；testbench 对 `0..8` 的全部
`9! = 362880` 个 rank permutation 先做独立结构验证，再用同一 comparator 顺序驱动
RTL，并与 `nth_element` 图像 reference 对照。

当前 VRF 只有一个窄写口。一个原位 compare-exchange 使用：

```text
MAX(a,b)  -> tmp
MIN(a,b)  -> a
PASS(tmp) -> b
```

所以每个 SIMD4 block 是 `19 × 3 = 57` 条 EXEC；VRF 初始填充和最终 STORE 不计入
这个执行微操作数。回归覆盖 zero-padding、tail mask、flat、impulse、随机噪声与
salt-and-pepper 图样。

## 对硬件 feature 的判断

不需要再增加四 lane MIN/MAX reduction：该比较树、masked value 和 winning lane
index 已经存在，内部编制可写：

```text
EXEC_REDUCE op=min_u va=1
EXEC_REDUCE op=max_u va=1
```

这两条是 `PASS_A + reduce` 的编制器 pseudo-op，结果进入 scalar result channel，不
写 VRF。中值滤波更值得后续测量的是双结果 `MINMAX`/compare-exchange：若仍只有一个
VRF 写口，它主要减少重复比较和控制字，不能自然变成单周期双写；只有负载统计证明
57 条序列成为主要瓶颈时再扩展执行路径。
