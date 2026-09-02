# VSP FFT和DSP函数库

## 概述

本文档描述VSP上的快速傅里叶变换(FFT)实现和数字信号处理(DSP)函数。

## FFT算法

### Radix-2 Decimation-in-Time (DIT)

经典Cooley-Tukey算法：
- 适合N为2的幂
- 原位计算节省内存
- 需要bit-reverse输入排序

**复杂度**: O(N log N)  
**操作数**: N log₂(N)个复数蝶形运算  
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
蝶形运算数: N*log₂(N) = 64*6 = 384
每个蝶形: 4个复数乘法 + 2个复数加法
         = 16个实数MUL + 8个实数ADD
总计: 6144 MUL + 3072 ADD ≈ 15000条指令
```

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

所有信号使用Q8.8定点格式：
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
