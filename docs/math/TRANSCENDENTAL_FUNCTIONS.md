# VSP超越函数数学库文档

## 概述

本文档描述VSP数学库中的超越函数实现，包括三角函数、指数对数函数和特殊函数。

## 实现方法

### 查找表法 (LUT)

**优点**:
- 固定时间复杂度 O(1)
- 高精度
- 适合硬实时系统

**缺点**:
- 需要内存空间
- 表大小与精度的权衡

**内存占用**: 约3KB (7个表)

### CORDIC算法

**优点**:
- 只需加法和移位
- 不需要乘法器
- 同时计算sin和cos

**缺点**:
- 迭代收敛，延迟较高
- 需要8-10次迭代

**适用**: 三角函数、双曲函数、向量旋转

## 函数列表

### 三角函数

#### math_sin_lut.uasm
使用256项查找表实现正弦函数

**输入**: 角度 [0, 255] 代表 [0, 2π]  
**输出**: sin值 Q8.8格式 [-256, 256] 代表 [-1.0, 1.0]  
**方法**: 直接查表或线性插值  
**精度**: 约0.4% 误差 (无插值)

```assembly
# 使用示例
VLOAD angles -> vrf[0]
VGATHER sin_table[vrf[0]] -> vrf[1]
```

#### math_cos_lut.uasm
使用sin表实现余弦函数 (cos(x) = sin(x + π/2))

**输入**: 角度 [0, 255]  
**输出**: cos值 Q8.8格式  
**优化**: 复用sin表，节省内存

#### math_sin_cos_cordic.uasm
CORDIC旋转模式同时计算sin和cos

**迭代次数**: 8-10次  
**精度**: 取决于迭代次数  
**输出**: 同时得到sin和cos

### 反三角函数

#### math_atan2_cordic.uasm
CORDIC向量模式计算atan2(y, x)

**输入**: y, x 坐标 (Q8.8)  
**输出**: 角度 [0, 255]  
**优势**: 自动处理四象限

### 指数对数函数

#### math_exp_lut.uasm
指数函数 exp(x)

**输入**: x [0, 8] Q8.8格式  
**输出**: exp(x) Q8.8格式  
**方法**: 整数部分查表 + 小数部分多项式

**范围缩减**:
```
exp(x) = exp(int_part) * exp(frac_part)
int_part: 查表
frac_part: 线性近似 exp(x) ≈ 1 + x
```

#### math_log_lut.uasm
自然对数 log(x)

**输入**: x (0, 256] Q8.8格式  
**输出**: log(x) Q8.8格式  
**方法**: 规格化 + 查表

**范围缩减**:
```
log(x) = log(2^n * m) = n*log(2) + log(m)
其中 m ∈ [1, 2)
```

## 查找表数据

### 表生成

使用 `tools/generate_lut.py` 生成所有查找表：

```bash
python3 tools/generate_lut.py
```

### 表文件格式

**二进制格式** (.bin):
- 直接加载到内存
- 小端序

**十六进制文本** (.hex):
- 用于 $readmemh
- 每行一个值

**C数组** (.c):
- 参考和验证
- 可移植

### 内存布局

```
地址范围          | 内容              | 大小
------------------|-------------------|-------
0x4000 - 0x41FF  | sin_table (Q8.8)  | 512B
0x4200 - 0x43FF  | cos_table (Q8.8)  | 512B
0x5000 - 0x51FF  | exp_table (Q8.8)  | 512B
0x5200 - 0x53FF  | log_table (Q8.8)  | 512B
0x5400 - 0x55FF  | sqrt_table (Q8.8) | 512B
0x5600 - 0x57FF  | recip_table       | 512B
0x6000 - 0x600F  | cordic_atan       | 16B
------------------|-------------------|-------
总计              |                   | 3088B (约3KB)
```

### 表精度分析

| 函数 | 表大小 | 最大误差 | RMS误差 |
|------|--------|---------|---------|
| sin  | 256项  | 0.0039  | 0.0022  |
| cos  | 256项  | 0.0039  | 0.0022  |
| exp  | 256项  | 0.012   | 0.007   |
| log  | 256项  | 0.004   | 0.002   |
| sqrt | 256项  | 0.002   | 0.001   |
| 1/x  | 256项  | 0.004   | 0.002   |

注: 误差相对于Q8.8精度

## 性能对比

### sin函数

| 方法 | 指令数 | 周期数估计 | 精度 |
|------|--------|-----------|------|
| 查表 | 5-8    | 15-25     | 0.4% |
| 查表+插值 | 15-20 | 40-60  | 0.05% |
| CORDIC | 80-100 | 150-200  | 可调 |
| 多项式 | 50-80  | 100-150  | 取决于阶数 |

### 推荐使用

- **实时性要求高**: 查找表法
- **精度要求高**: 查表+插值
- **内存受限**: CORDIC算法
- **同时需要sin/cos**: CORDIC旋转模式

## 使用示例

### 示例1: 计算sin(45°)

```assembly
# 45° = π/4 = 32 (in 256-step circle)
LI rd=1 imm=0x4000          # sin表基址
VLOAD angle=32 -> vrf[0]
EXEC_ALU_RI op=shl va=0 vd=1 imm=1    # index * 2
VGATHER sbase=1 vi=1 vd=2 offset=0
# vrf[2] 现在包含 sin(45°) ≈ 181 (0.707 in Q8.8)
```

### 示例2: 向量旋转

```assembly
# 旋转向量 (x, y) 角度 theta
# x' = x*cos(θ) - y*sin(θ)
# y' = x*sin(θ) + y*cos(θ)

# 使用CORDIC更高效
EXEC_CORDIC_ROTATE angle=theta x=vrf[0] y=vrf[1]
# 结果: vrf[0] = x', vrf[1] = y'
```

### 示例3: 极坐标转换

```assembly
# (x, y) -> (r, θ)
# r = sqrt(x^2 + y^2)
# θ = atan2(y, x)

# 计算r使用勾股定理
EXEC_ALU_RR op=mul_u va=x vb=x dst_arf=0  # x^2
EXEC_ALU_RR op=mul_u va=y vb=y dst_arf=1  # y^2
# ADD + SQRT ...

# 计算θ使用CORDIC向量模式或atan2表
```

## 扩展计划

### 短期
- 添加线性插值提高精度
- 实现tan/atan函数
- 优化CORDIC迭代次数

### 中期
- 双曲函数 sinh/cosh/tanh
- 幂函数 pow(x, y)
- 误差函数 erf(x)

### 长期
- 自适应精度控制
- 多精度运算支持
- IEEE 754兼容模式

## 参考资料

- CORDIC算法: Volder (1959)
- 查找表设计: "Handbook of Floating-Point Arithmetic"
- 误差分析: Muller et al.

## 相关文件

- `tools/generate_lut.py` - 查找表生成工具
- `test_data/lut/*.hex` - 查找表数据
- `examples/uword/math_*.uasm` - 汇编实现
- `docs/math_transcendental_plan.md` - 实现计划

---

**版本**: 1.0  
**日期**: 2026-09-03  
**状态**: 基础实现完成
