# 64点q/127三音混合FFT

## 状态

**状态**：已完成Verilator、VCS、独立DFT、Graphviz和Verdi闭环（2026-09-04）。

本fixture用于补足单音bin-8 smoke对一般FFT数学行为覆盖不足的问题。输入是64点实数
三余弦混合波，量化后装入backing SRAM，随后走正常PC、I-cache、微码解码、SIMD
EXEC、D-cache、shared fabric和RAM路径。计算完成后testbench自动导出连续地址结果、
CSV和波形，不需要人工控制TB。

## 输入定义

```text
x[n] = 0.40*cos(2*pi*5*n/64)
     + 0.28*cos(2*pi*13*n/64 + pi/4)
     + 0.16*cos(2*pi*23*n/64 - pi/3)
```

采用用户指定的对称signed-int8定点约定：

```text
q[n]   = clip(floor(127*x[n] + 0.5), -127, 127)
xq[n]  = q[n] / 127
+127 -> +1，-127 -> -1；不使用-128
```

三个频率均为奇数，因此`x[n+32] = -x[n]`，量化码也保持同样的半周期反对称。
实际码值范围是`[-94,94]`，理想波形采样峰值约`0.743916`，留有33 code余量，
没有输入削顶。自然顺序样本同时导出到`fft64_input.csv`，SRAM中的工作数组按
6-bit bit-reverse顺序预排。

## 执行尺度与用户尺度

RTL仍使用原生static-BFP8执行契约`value = mantissa * 2^(E-7)`。该fixture以
`Ein=0`开始，六级蝶形各右移一位并将共享指数加一，最终`Eout=6`。执行时同一组
整数码可看成`q/128`；FFT是齐次运算，因此在用户要求的`q/127`坐标中，最终频谱
按下式导出：

```text
X_user[k] = output_mantissa[k] * 64/127
```

CSV分别保留`execution_exponent=6`和`value_scale=64/127`，避免把执行BFP指数与
用户显示尺度混为一谈。实部结果连续覆盖`0x1000..0x103f`，虚部结果连续覆盖
`0x1040..0x107f`，输出指数位于`0x1370..0x137f`。

## 实测频谱

对自然顺序`q/127`样本做独立、负角度、未归一化的直接DFT后，六个最强频点为
`5/13/23/41/51/59`。RTL单边幅度按DC/Nyquist为`|X|/64`、其他bin为
`2|X|/64`计算：

| 正频率bin | 设计幅度 | RTL复数频谱 | RTL单边幅度 |
|---:|---:|---:|---:|
| 5 | 0.40 | `12.598425 + j0` | 0.393701 |
| 13 | 0.28 | `6.047244 + j6.551181` | 0.278611 |
| 23 | 0.16 | `2.519685 - j4.535433` | 0.162136 |

负频率bin 59/51/41形成对应共轭主峰。相对dB图中bin 5/59为`0 dB`，
bin 13/51约`-3.003 dB`。其余可见小谱线来自Q2.6 twiddle和每级signed-int8
舍入；最大杂散的单边幅度约`0.01575`。

独立校验器只使用Python标准库的`O(N^2)` DFT，不导入生成器或其radix-2 golden。
它还从每行整数码重新核对`real/imag_value=code/127`并拒绝`-128`，因此不会把
误写成q/128的输入CSV当作有效oracle。
实测结果为：

- 最大复数误差`0.5101312`（bin 37）；
- RMS复数误差`0.175368301`；
- Parseval相对能量误差`1.695114%`；
- RTL最强六bin集合与独立DFT完全一致；
- Verilator与VCS的输出HEX和频谱CSV逐字节一致。

## 命令

```bash
make generate-fft64-mixed-vsp
make test-fft64-mixed-vsp          # Verilator + RAM/cache + VCD
make verify-fft64-mixed-vsp        # 独立DFT及误差CSV/JSON
make plot-fft64-mixed-time-domain  # 只生成输入时域DOT/SVG/PNG
make plot-fft64-mixed-vsp          # 时域图、components、单边幅度、相对dB

make test-vcs-fft64-mixed-vsp      # VCS + VPD
make verify-vcs-fft64-mixed-vsp
make plot-vcs-fft64-mixed-vsp      # VCS结果的同组三视图
make compare-fft64-mixed-vsp       # 两套模拟器逐字节比较
make prepare-verdi-fft64-mixed-vsp # VPD -> VCD -> FSDB
make view-verdi-fft64-mixed-vsp    # 打开预置nWave窗口
```

Graphviz `neato`直接生成DOT、SVG和PNG，不依赖NumPy或Matplotlib。推荐以
`fft64_input_time_domain`图查看64点量化时域波形，以`one_sided_amplitude`图确认
输入三音幅度，以`relative_db`图观察弱杂散，以`components`图检查相位和共轭关系。

## 主要产物

`build/fft64_mixed_vsp/`：

- `fft64_input.csv`：自然顺序q/127输入；
- `dsp_fft64_q7.hex`、`fft64_q7_data.hex`、`fft64_q7_golden.hex`：微码、SRAM
  镜像和逐字节执行golden；
- `fft64_mixed_rtl_output.hex`、`fft64_mixed_spectrum.csv`：Verilator结果；
- `fft64_dft_reference.csv`、`fft64_spectrum_comparison.csv`、
  `fft64_spectrum_metrics.json`：独立DFT与误差报告；
- `fft64_input_time_domain.{dot,svg,png}`：64点q/127输入时域波形；
- `fft64_mixed_spectrum_{components,one_sided_amplitude,relative_db}.{dot,svg,png}`；
- `fft64_mixed_vsp.vcd`。

`build/vcs_fft64_mixed_vsp/`保存相同的VCS CSV/校验报告、`fft64_mixed_vsp.vpd`、
三组Graphviz图、转换后的VCD/FSDB、VCS KDB及`verdi_fft64_mixed.png`窗口快照。
Verdi中的
`plot_bin`、signed mantissa、
`execution_exponent`、`plot_*_value` real信号和Q16.16镜像都由TB在
系统静默后自动逐bin扫描。

## 边界

这项回归显著扩大了static-BFP8 FFT的数学覆盖，但仍不是全输入空间证明。当前
twiddle为Q2.6，数据每级缩放并窄化为signed int8；动态BFP、随机/极值向量及旧
Q8.8/16-bit profile仍需分别实现和验证。
