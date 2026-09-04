# 64点原生lane静态BFP8 FFT

## 状态

该工作负载是当前可执行的VSP FFT闭环。它不是原有Q8.8行为模型的改名版本：
数据格式、缩放规则和内存镜像均已重新定义，以匹配VSP的8位物理lane。

2026-09-04验证状态：

- `make test-fft64-vsp`通过，完整实例化VSP取指、I-cache、微码解码、
  SIMD EXEC、vector MEMORY、D-cache、shared physical fabric和backing SRAM；
- 64个复数输出逐字节匹配生成器golden，输出块指数也经真实执行路径写回；
- Verilator：1646项检查，449个action，46125个TB周期，45次I-cache miss、
  72次D-cache read miss和1708个shared-RAM beat；
- VCS O-2018.09-SP2：411项检查，449个action，46440个TB周期，cache miss和
  RAM beat计数与Verilator一致；
- 已生成Verilator VCD、VCS VPD及由VPD转换的VCD/FSDB，并已用Verdi打开；
- Verilator/VCS结果均已通过CSV和Graphviz `neato`生成确定坐标的DOT、SVG和PNG
  频谱图，不依赖Matplotlib或NumPy。

两个testbench的cycle计数受各自时钟驱动和检查调度影响，不应用二者差值衡量RTL性能；
action、cache miss、RAM beat和最终存储内容才是跨仿真器的一致性检查项。

## 数值规格

- 算法：64点Cooley-Tukey radix-2 DIT；
- 数据：静态BFP8，mantissa为signed int8，数值定义为
  `x = mantissa * 2^(E-7)`；
- 本fixture输入块指数`Ein=-2`；尾数仍按7个小数位的BFP契约解释，
  但不能脱离共享指数单独称为Q1.7输入；
- 旋转因子：signed Q2.6 byte，`W[k] = cos(theta) - j sin(theta)`；
- 输入：host生成后按6 bit bit-reverse预排；
- 调度：每级32个蝶形，拆为两个16-lane batch，共6级、12个batch；
- 缩放：每级在`NCLIP_S`中右移一位，同时块指数加一；最终mantissa为
  `FFT(x)/64`，`Eout=Ein+6=4`，二者组合重构未缩放FFT；
- 舍入：严格沿用`SIMD_OP_NCLIP_S`，即算术右移后加被丢弃部分的最高位；
- 溢出：窄化时饱和到`[-128, 127]`。测试输入的mantissa峰值为96，在
  `Ein=-2`下对应物理幅度`96 * 2^(-9) = 0.1875`的bin-8实正弦。

蝶形在Q2.13中形成：

```text
Tr  = Br*Wr - Bi*Wi
Ti  = Br*Wi + Bi*Wr
Ar' = round_sat((Ar*64 + Tr) / 128)
Ai' = round_sat((Ai*64 + Ti) / 128)
Br' = round_sat((Ar*64 - Tr) / 128)
Bi' = round_sat((Ai*64 - Ti) / 128)
```

微码用`MUL_S/MAC_S`生成`Tr/Ti/-Tr/-Ti`，用format-0x8
`WADD_S`把旧A对齐到相同小数位，再用`NCLIP_S shift=7`完成逐级缩放、舍入和
饱和。该映射没有假设不存在的16位乘法lane或隐式byte packing。

程序先从`0x1100..0x111f`加载独立零向量，再从SRAM加载16份复制的
`Ein=-2`，在EXEC中生成16份`Eout=4`，再经
VSTORE、D-cache和shared SRAM写回。它验证了静态指数元数据的真实传输，不代表
硬件已经具备跨group绝对值最大归约、动态headroom判断或BF16运算。

对于本测试，存储输出的bin 8为`(0,-48)`、bin 56为`(0,48)`；结合`Eout=4`
可重构为`(0,-6)`和`(0,6)`。

## SRAM布局

程序从`0x0020`执行；data区域位于可缓存physical页`0x1000..0x1fff`。

| 地址 | 长度 | 内容 |
|---|---:|---|
| `0x1000` | 64 B | bit-reversed work real / 最终real |
| `0x1040` | 64 B | bit-reversed work imag / 最终imag |
| `0x1080` | 32 B | twiddle real，Q2.6 |
| `0x10a0` | 32 B | twiddle imag，Q2.6 |
| `0x10c0` | 32 B | negated twiddle real |
| `0x10e0` | 32 B | negated twiddle imag |
| `0x1100` | 32 B | EXEC `WADD` 使用的独立零向量 |
| `0x1120` | 192 B | 12个batch的A byte index |
| `0x11e0` | 192 B | 12个batch的B byte index |
| `0x12a0` | 192 B | 12个batch的twiddle byte index |
| `0x1360` | 16 B | 复制的signed-int8输入块指数`Ein=-2` (`0xfe`) |
| `0x1370` | 16 B | 输出指数缓冲，sentinel初始化，运行后为`Eout=4` |

生成的`fft64_q7_data.hex`是从`0x1000`开始的little-endian 32-bit word镜像。
测试平台通过`backing_init_*`逐word安装程序和数据；该初始化端口不计入lower
transaction。启动后，程序取指必须由I-cache miss/refill获得，全部FFT数据和指数
访问也必须经过D-cache和shared lower port。

## 生成与验证

```bash
make generate-fft64-vsp
make test-fft64-vsp
make test-vcs-fft64-vsp
make plot-fft64-vsp
make plot-vcs-fft64-vsp
```

`plot-fft64-vsp`和`plot-vcs-fft64-vsp`分别先完成对应的自检回归，再将64个bin的
`real_value`、`imag_value`和`magnitude`交给Graphviz `neato -n2`绘制。绘图只
依赖Python标准库和Graphviz，无需安装Matplotlib或NumPy。

生成目录`build/fft64_vsp/`包含：

- `dsp_fft64_q7.uasm/.hex/.lst/.json`：93-word循环微码及符号；
- `fft64_q7_data.hex`：224-word backing SRAM data镜像；
- `fft64_q7_golden.hex`和`fft64_q7_rtl_output.hex`：最终64个复数golden/RTL输出；
- `fft64_q7_stage_golden.hex`：每一级的完整real/imag golden；
- `fft64_q7_input_natural.hex`与`fft64_q7_input_bitreversed.hex`；
- `fft64_bfp_exponents.hex`：`fe,ff,00,01,02,03,04`静态块指数计划；
- `fft64_q7_manifest.json`：数值格式、地址和计数的机器可读契约；
- `fft64_vsp.vcd`：Verilator回归波形；
- `fft64_spectrum.csv`：64行解码结果，分别记录执行块指数、显示尺度、real/imag、
  幅值和功率；
- `fft64_spectrum.dot/.svg/.png`：`make plot-fft64-vsp`生成的Graphviz频谱图。

程序地址为`0x0020..0x0193`，data地址为`0x1000..0x137f`，data镜像为224 words。

VCS在workload完成且`system_quiescent_o`有效后，自动用每bin一个周期扫描连续的
64个FFT结果，生成`build/vcs_fft64_vsp/fft64_spectrum.csv`；不需要在计算完成后
手工poke或控制testbench。`make plot-vcs-fft64-vsp`在同一目录继续生成
`fft64_spectrum.dot/.svg/.png`。当前Verilator和VCS生成的CSV逐字节一致。

VCS还生成`build/vcs_fft64_vsp/fft64_vsp.vpd`。当前Verdi 2018的`-ssf`入口
直接接受VCD/FSDB，因此保留原始VPD，再转换为VCD和FSDB。FSDB可避免
Verdi首次打开VCD时的交互式转换提示；预置脚本会直接将FFT/cache/RAM关键
信号和频谱扫描信号加入nWave：

```bash
make prepare-verdi-fft64-vsp
make view-verdi-fft64-vsp
```

两个目标分别执行`vpd2vcd`/`vfast`转换，以及使用VCS KDB、
`fft64_vsp_vcs.fsdb`和`sim/verdi_fft64_vsp.tcl`启动Verdi。

Verilator波形也可直接用Verdi查看：

```bash
cd build/fft64_vsp
verdi -ssf fft64_vsp.vcd -nologo
```

testbench中的`fft_stage`、`fft_batch`、`bfp_exponent`、`completed_actions`以及
cache/RAM计数器用于快速定位波形；`fetch_pc_o`及I/D cache性能脉冲可确认真实
执行路径。频谱组包含`plot_valid`、`plot_bin`、mantissa、指数，以及
`plot_real_value`/`plot_imag_value`/`plot_magnitude`/`plot_power`等Verdi `real`
信号；同时提供对应Q16.16整数信号，供不便使用analog/real显示时观察。扫描和
CSV写出均由testbench自动完成。Verdi analog视图会在稀疏`real`变更点之间作
连线，逐bin数值以同一窗口中的数字值/Q16.16或CSV为准；Graphviz图按64个离散点
绘制，是观察频谱形状的主视图。

## 边界

该实现验证的是当前原生8-bit静态BFP FFT profile。旧的
`examples/uword/dsp_fft_radix2.uasm`和Q8.8 fixture仍只作为历史/算法参考；
它们没有形成16-bit Q8.8 VSP执行闭环。若产品必须保持Q8.8 I/O，应另行实现
byte拆包、signed 16x16复乘、进位和回包契约，不能直接替换本程序的格式标注。

本页默认fixture仍是bin-8实正弦单音，program、data与逐级golden由同一生成器
产生，因此单独看它仍只是执行与memory-system smoke。新增的
[64点q/127三音混合FFT](fft64-mixed-s8.md)已用5/13/23三频输入和不依赖生成器的
直接`O(N^2)` DFT补足多频点独立数学检查；随机、极值和动态缩放向量仍未覆盖。

动态BFP和真正BF16的范围及剩余工作见
[块浮点数值契约](../math/BLOCK_FLOATING.md)。
