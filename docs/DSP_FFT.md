# VSP FFT和DSP函数库

## 概述

本文档描述VSP上的快速傅里叶变换(FFT)实现和数字信号处理(DSP)函数。

> **实现状态（2026-09-04）**：当前真实VSP RTL闭环采用静态BFP8数据
> （本fixture为`Ein=-2`的signed-int8 mantissa）、Q2.6旋转因子和逐级指数更新，
> Verilator与VCS均已通过，详见
> [64点原生lane静态BFP8 FFT](workloads/fft64-q7.md)。本文其余Q8.8表和
> `fft64_vcs_tb.sv`属于历史fixture/行为参考，不代表Q8.8微码已在VSP RTL执行。

## FFT算法

### Radix-2 Decimation-in-Time (DIT)

经典Cooley-Tukey算法：
- 适合N为2的幂
- 原位计算节省内存
- 需要bit-reverse输入排序

**复杂度**: O(N log N)  
**操作数**: (N/2) log₂(N)个复数蝶形运算
**内存**: 2N个复数样本 + N/2个旋转因子

### 蝶形运算 (Butterfly)

基本计算单元：
```
输入: A, B (复数对)
旋转因子: W = e^(-j2πk/N) = cos(θ) - j sin(θ)

输出:
  A' = A + B*W
  B' = A - B*W
```

**展开**:
```
复数乘法 B*W:
  Br' = Br*cos(θ) - Bi*sin(θ)
  Bi' = Br*sin(θ) + Bi*cos(θ)

需要4次实数乘法，2次实数加法
```

### 旋转因子 (Twiddle Factors)

预计算表：
```
W_N^k = e^(-j2πk/N) = cos(2πk/N) - j sin(2πk/N)

对于N点FFT，需要N/2个旋转因子
利用对称性: W_N^(k+N/2) = -W_N^k
```

## VSP实现策略

### 方法1: 直接实现 (需要硬件MUL)

**优点**:
- 最佳性能
- 标准算法

**要求**:
- 硬件8x8乘法器(MUL/MAC)
- ARF累加器支持

**性能估计** (N=64):
```
蝶形运算数: (N/2)*log₂(N) = 32*6 = 192
每个通用蝶形: 1个复数乘法 + 2个复数加/减
             = 4个实数MUL + 6个实数ADD/SUB
标量算术总计: 768 MUL + 1152 ADD/SUB
```

上述是未扣除平凡旋转因子、未计SIMD并行度和数据移动的算法计数，
不等于VSP实测指令数或周期数。

### 方法2: CORDIC-based FFT

**优点**:
- 无需乘法器
- 只用加法和移位

**缺点**:
- 较慢 (每次复数乘需8-10次迭代)
- 精度取决于迭代次数

### 方法3: 优化小尺寸FFT

**Radix-4算法** (N=4的幂):
- 减少75%的乘法
- 更复杂的蝶形

**Split-radix算法**:
- 最少的算术运算
- 复杂控制流

## 内存布局

### 输入数据
```
地址          | 内容
0x1000-0x11FF | 实部 (N个Q8.8值)
0x1200-0x13FF | 虚部 (N个Q8.8值)
```

### 旋转因子表
```
地址          | 内容
0x4000-0x40FF | cos表 (N/2个值)
0x4100-0x41FF | sin表 (N/2个值)
0x4200-0x42FF | bit-reverse索引
```

### 工作缓冲区
```
原位计算: 直接在输入缓冲区
或
双缓冲: 输入 + 输出各2N样本
```

## 测试信号

### 提供的测试信号

**1. 正弦波** (sine_XXXhz.hex)
- 频率: 100, 440, 1000, 2000 Hz
- 用途: 验证单频点FFT输出

**2. 线性调频 (chirp_100_2000hz.hex)**
- 频率扫描: 100-2000 Hz
- 用途: 测试宽带频谱

**3. 方波 (square_440hz.hex)**
- 基频: 440 Hz
- 用途: 验证谐波识别

**4. 多音信号 (multitone_3freq.hex)**
- 频率: 300, 700, 1400 Hz
- 用途: 测试频率分辨率

**5. QPSK调制信号 (qpsk_32sym_iq.hex)**
- 32个符号，每符号8采样
- 用途: 通信信号解调

**6. FFT测试向量**
- 脉冲信号 (impulse_N.hex)
- 单频点信号 (fft_test_N_binK.hex)
- 用途: 功能验证

### 信号格式

本节列出的旧通用信号fixture使用Q8.8定点格式：
- 16位有符号整数
- 8位整数部分，8位小数部分
- 范围: -128.0 到 +127.99609375

**复数信号**:
- _iq.hex: I/Q交织 [I0, Q0, I1, Q1, ...]
- _i.hex, _q.hex: 分离的I和Q通道

## 使用示例

### 示例1: 加载FFT表

```systemverilog
// 加载64点FFT旋转因子
logic [15:0] twiddle_cos [0:31];
logic [15:0] twiddle_sin [0:31];
logic [15:0] bitrev [0:63];

initial begin
    $readmemh("test_data/fft/fft64_twiddle_cos.hex", twiddle_cos);
    $readmemh("test_data/fft/fft64_twiddle_sin.hex", twiddle_sin);
    $readmemh("test_data/fft/fft64_bitreverse.hex", bitrev);
end
```

### 示例2: 加载测试信号

```systemverilog
// 加载正弦波测试信号
logic [15:0] test_signal [0:1999];

initial begin
    $readmemh("test_data/signals/sine_440hz.hex", test_signal);
end
```

### 示例3: 验证FFT输出

```python
# Python参考实现
import numpy as np

# 读取输入
signal = load_q88_signal("sine_440hz.hex")
signal_float = signal / 256.0

# 计算FFT
fft_result = np.fft.fft(signal_float)

# 与VSP输出比较
vsp_output = load_q88_signal("vsp_fft_output.hex")
difference = compare_results(fft_result, vsp_output)
```

## 工具

### VSP RTL + RAM/cache 64点FFT

当前可执行profile由`tools/generate_fft64_vsp.py`生成93-word微码、224-word
SRAM数据镜像、逐级golden和最终golden。程序从`0x1360`加载复制的`Ein=-2`，
固定六级执行后由EXEC生成`Eout=4`并经D-cache/shared SRAM写回`0x1370`。
`make test-fft64-vsp`已通过真实PC/I-cache/decode/SIMD/D-cache/shared SRAM
闭环并生成VCD；`make test-vcs-fft64-vsp`使用相同镜像和RTL，也已在
VCS O-2018.09-SP2通过并生成VPD。

```bash
make test-fft64-vsp
cd build/fft64_vsp
verdi -ssf fft64_vsp.vcd -nologo

cd ../..
make test-vcs-fft64-vsp
make prepare-verdi-fft64-vsp
make view-verdi-fft64-vsp
```

完整数值契约、内存地址和当前验证结果见
[64点原生lane静态BFP8 FFT](workloads/fft64-q7.md)。
当前结果是bin-8单音端到端smoke，且program/data/golden同源；它不代表
已完成一般FFT的独立数学验证。

### 旧Q8.8行为级VCS参考Demo

仓库提供一个独立的、可重复运行的SystemVerilog行为级参考TB。它加载现有的
64点bin-8测试信号、Q8.8旋转因子和bit-reverse表，执行radix-2 DIT FFT，
并检查bin 8/56共轭峰、DC和非峰值杂散。

```bash
make test-vcs-fft64
```

通过时的关键输出为：

```text
FFT64 spectrum: bin 8=(0,-6561), bin 56=(0,6561) Q8.8
PASS fft64_vcs_tb: 132 checks
```

该目标为可选目标，需要Synopsys VCS许可证，不加入默认的`make test`。
默认链接参数包含`-Wl,--no-as-needed`，用于兼容本项目验证环境中的
VCS O-2018.09与新版GNU ld；可通过`VCS_LDFLAGS=...`覆盖。
TB只验证FFT算法和旧Q8.8测试数据在VCS/SystemVerilog环境中的一致性；它不执行
`dsp_fft_radix2.uasm`，也不证明VSP RTL已经形成完整FFT执行闭环。对应的RTL/
微码闭环缺口记录在`issues/open/FFT微码RTL闭环执行缺口-Codex-2026-09-03.md`。

### generate_signals_pure.py

生成各种测试信号

**用法**:
```bash
python3 tools/generate_signals_pure.py
```

**输出**: test_data/signals/

### generate_fft_tables.py

生成FFT旋转因子表

**用法**:
```bash
python3 tools/generate_fft_tables.py
```

**输出**: test_data/fft/

### 支持的FFT大小

- 64点
- 128点
- 256点
- 512点
- 1024点

## 性能分析

### 64点FFT

| 实现方法 | 指令数 | 周期数估计 | 精度 |
|---------|--------|-----------|------|
| 硬件MUL | 15000 | 25000 | 精确 |
| CORDIC | 120000 | 200000 | 可调 |
| 软件MUL | 300000 | 500000 | 精确 |

### 256点FFT

| 实现方法 | 指令数 | 周期数估计 |
|---------|--------|-----------|
| 硬件MUL | 80000 | 130000 |
| CORDIC | 650000 | 1000000 |

### 瓶颈

1. **复数乘法**: 占总时间70-80%
2. **内存访问**: bit-reverse和旋转因子查表
3. **数据重排**: 原位计算需要careful索引

## 通信应用

### 频谱分析

- 信号检测
- 频率估计
- 功率谱密度

### OFDM解调

- 子载波提取
- 信道估计
- 均衡

### 匹配滤波

- 脉冲压缩
- 雷达信号处理

### 信道编码

- 卷积码
- Turbo码
- LDPC码

## 扩展计划

### 短期
- 优化蝶形运算
- 实现Radix-4 FFT
- 添加窗函数

### 中期
- 快速卷积 (FFT-based)
- 滤波器组
- 小波变换

### 长期
- 自适应FFT (动态选择算法)
- 多速率信号处理
- 压缩感知

## 参考资料

- Cooley & Tukey (1965): "An Algorithm for Machine Calculation of Complex Fourier Series"
- Oppenheim & Schafer: "Discrete-Time Signal Processing"
- Xilinx FFT IP: 参考实现

## 相关文件

- `examples/uword/dsp_fft_radix2.uasm` - FFT汇编实现框架
- `tools/generate_signals_pure.py` - 信号生成器
- `tools/generate_fft_tables.py` - FFT表生成器
- `test_data/signals/` - 测试信号
- `test_data/fft/` - FFT旋转因子表

---

**版本**: 1.0  
**日期**: 2026-09-03  
**状态**: 框架实现，需要硬件MUL优化
