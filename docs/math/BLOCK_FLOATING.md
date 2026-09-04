# VSP BFP8块浮点数值契约

## 状态与范围

本文定义VSP当前64点FFT可采用的BFP8解释，以及静态缩放与未来动态块浮点之间的
边界。BFP8不是IEEE-754 `bfloat16`：BFP8由一组8位有符号尾数共享一个指数，
而`bfloat16`为每个16位元素各自编码符号、指数和小数。

当前FFT已经执行BFP8尾数和静态共享指数的数据通路：程序从共享SRAM读取复制的
`Ein=-2`，在EXEC中生成`Eout=4`，再经D-cache写回共享SRAM。动态块浮点仍未
实现，尚缺跨组headroom归约、动态shift决策、指数同步和异常协议。

逐元素数值若需要每个尾数携带自己的8位补码指数，应使用单独定义的
[M8E8逐元素补码浮点数值契约](M8E8.md)。M8E8的软件数值oracle和SoA ABI已经
完成，但RTL、汇编/微码及RAM/cache执行闭环尚未完成；它不能作为当前BFP8 FFT
硬件能力的一部分。

## BFP8表示

对同一数据块中的每个元素，定义：

```text
x[i] = m[i] * 2^(E - 7)
```

- `m[i]`是8位二补码尾数，范围`[-128, 127]`；
- `E`是整个数据块共享的有符号整数指数；当前SRAM ABI将它编码为复制到16个
  byte lane的signed 8-bit值；
- 当前64点复数FFT中，一个块包含全部64个实部尾数和64个虚部尾数，实部与虚部
  共享同一个`E`；
- 当前静态profile只验证了`Ein=-2`到`Eout=4`；动态指数的允许范围以及溢出/下溢
  行为仍未固化。

例如，`m=64, E=0`表示`0.5`，而`m=64, E=1`表示`1.0`。零尾数表示零；动态实现
仍需另行规定零块的规范指数。

## 当前FFT的静态stage shift

当前64点radix-2 DIT FFT采用固定缩放计划：每一级蝶形都将尾数右移一位，六级
共右移六位。为保持重建后的数值不变，共享指数按同样次数增加：

```text
E(stage + 1) = E(stage) + 1
Eout          = Ein + 6
```

因此，SRAM中的输出尾数字节等价于定点实现所述的`FFT(input)/64`；按BFP8契约使用
`Eout`重建后，则仍表示未除以64的数学FFT结果。当前生成器在`0x1360..0x136f`
放置16份signed byte `Ein=-2`。微码通过正常D-cache路径载入该向量，在12个FFT
batch结束后以byte EXEC加上常数6，生成16份`Eout=4`，再通过`VSTORE`和D-cache/
shared fabric写入共享SRAM的`0x1370..0x137f`。

指数复制16份只是为了匹配当前16-lane向量load/store宽度；逻辑上仍只有一个块级
共享指数。程序没有在每个stage动态更新指数状态，而是在固定六级调度结束后一次性
计算`Ein+6`。

旋转因子仍是独立的signed Q2.6常量，不共享上述数据块指数。蝶形的乘法、小数位
对齐和每级缩放详见[64点原生lane静态BFP8 FFT](../workloads/fft64-q7.md)。

## 舍入与饱和

静态FFT沿用`SIMD_OP_NCLIP_S`。对宽中间值`v`和右移量`s>0`：

```text
r = sat_s8((v >>> s) + bit(v, s - 1))
```

其中`>>>`是算术右移，`bit(v, s-1)`是最高被丢弃位，`sat_s8`将结果限制到
`[-128, 127]`。这就是项目所称的round-to-nearest-up；在恰好位于中点时向正无穷
方向选择。`s=0`时不加舍入增量，只执行有符号8位饱和。

饱和不会触发指数自适应，也不会回头重算该级。发生饱和意味着当前静态指数计划
已经造成信息损失，必须由测试或未来动态BFP机制检测。

## RTL与VCS验证

当前静态BFP8程序、指数输入和指数输出均经过真实RAM/cache路径验证：

- Verilator：`PASS`，1646项检查、449个action、46125周期、45次I-cache miss、
  72次D-cache read miss、1708个shared-RAM beat；
- VCS：`PASS`，411项检查、449个action、46440周期，cache miss和RAM beat计数
  同上；生成`build/vcs_fft64_vsp/fft64_vsp.vpd`。

两套testbench都检查输出尾数和`0x1370..0x137f`中的复制`Eout=4`。不同仿真器的
周期数包含各自testbench计数窗口，不应直接解释为硬件性能差异。

## 当前不支持的动态BFP

当前实现不是数据相关的动态块浮点。它没有：

- 在每级蝶形前后扫描整个复数块的最大绝对值或headroom；
- 根据数据选择0位、1位或更多位的stage shift；
- 根据动态shift逐stage保存、广播和更新共享指数；当前只在结尾执行固定`Ein+6`；
- 在多个SIMD group之间同步指数决策；
- 对指数溢出、下溢、尾数饱和或零块产生状态。

因此只能称为“具有显式共享指数解释的静态缩放BFP8 profile”，不能宣称已支持
自适应精度的动态BFP。动态方案的RTL、微码、内存ABI和验证门槛由对应open issue
追踪。

当前数值回归仅覆盖bin-8单音，program、data与golden也由同一生成器产生。
该结果支持静态BFP数据通路smoke，但不构成一般FFT的独立数学验证。

## 与BF16的边界

真正的`bfloat16`采用`1 sign + 8 exponent + 7 fraction`，每个元素都有自己的指数，
还涉及非规格数、无穷、NaN、指数对齐、guard/round/sticky位和特殊值传播。VSP当前
没有BF16执行闭环；`examples/uword/math_fp16_add.uasm`只是不可执行的历史算法轮廓，
不能作为BF16支持证据。格式详情见[数学库数据格式](math_library_format.md)。

M8E8同样不是BF16：M8E8的符号来自补码尾数，指数为无bias补码整数，并明确不支持
NaN、无穷和非规格数。其已冻结语义和未完成硬件范围见
[M8E8数值契约](M8E8.md)。
