# 硬件乘法器资源未充分利用

**报告者**: WhiteDeerPro  
**日期**: 2026-09-03  
**优先级**: High  
**类型**: Enhancement  
**状态**: Open

## 问题描述

VSP在RTL级别实现了8×8硬件乘法器（MUL_U/MUL_S/MAC_U/MAC_S），但当前的uword汇编器（`tools/vsp_uword_asm.py`）没有提供相应的伪指令支持，导致无法在程序级别使用这些硬件资源。

## 技术细节

### 硬件层面
- ✅ `rtl/units/simd_lane.sv`中实现了完整的8×8乘法器
- ✅ 操作码：MUL_U=0x16, MUL_S=0x17, MAC_U=0x18, MAC_S=0x19
- ✅ 结果输出到ARF（32位累加器寄存器）
- ✅ Gaussian workload已验证该路径有效

### 工具链层面
- ❌ `tools/vsp_uword_asm.py`的ALU_OPS字典缺少mul/mac操作
- ❌ 无法编码MUL/MAC到uword程序
- ✅ C++ testbench可以直接设置op_i使用

## 影响

### 性能影响
| 运算 | 当前软件实现 | 理想硬件实现 | 性能损失 |
|------|-------------|-------------|---------|
| 8×8乘法 | ~50条指令 | 1条指令 | 50× |
| 16×16乘法 | ~200条指令 | ~20条指令 | 10× |
| MAC链(9项) | ~1800条指令 | ~10条指令 | 180× |

### 应用影响
- 数学库性能受限（当前为理论值的1%）
- 无法高效实现卷积、FFT等密集计算
- Q8.8定点乘法效率低
- 矩阵运算性能差

## 建议方案

### 方案1：扩展汇编器（推荐）

**步骤1**: 修改`tools/vsp_uword_asm.py`

```python
ALU_OPS = {
    # ... 现有操作
    "mul_u": 0x16,
    "mul_s": 0x17,
    "mac_u": 0x18,
    "mac_s": 0x19,
}
```

**步骤2**: 增加ARF端口参数支持

```python
def encode_alu(...):
    # 添加参数
    src_arf_addr = ...
    dst_arf_addr = ...
    write_arf = ...
```

**步骤3**: 创建新的伪指令格式

```assembly
# 乘法示例
EXEC_MUL_RR op=mul_u mode=byte va=0 vb=1 dst_arf=0

# 乘累加示例
EXEC_MAC_RR op=mac_u mode=byte va=2 vb=3 src_arf=0 dst_arf=0
```

**步骤4**: 添加ARF到VRF导出支持

```assembly
# 使用NSLICE从ARF导出到VRF
EXEC_NSLICE src_arf=0 shift=0 vd=5
```

**工作量估计**: 2-3周

### 方案2：创建专用乘法伪指令

不修改通用EXEC_ALU，而是创建专门的MUL/MAC伪指令：

```assembly
MUL_U va=0 vb=1 arf=0          # 简化语法
MAC_U va=2 vb=3 arf=0 arf=0    # src和dst可以相同
```

**工作量估计**: 1-2周

### 方案3：保持现状+文档化

暂不修改汇编器，但完善文档说明：
- ✓ 如何在C++ testbench中使用硬件乘法
- ✓ 性能基准对比
- ✓ 未来优化路线图

## 相关文件

- `docs/MULTIPLIER_GAP_ANALYSIS.md` - 详细分析文档
- `rtl/units/simd_lane.sv` - 硬件实现
- `sim/gaussian3x3_tb.cpp` - 使用示例
- `tools/vsp_uword_asm.py` - 需要修改的汇编器
- `examples/uword/math_mul16_*.uasm` - 当前软件实现

## 后续行动

- [ ] 评估方案1和方案2的优缺点
- [ ] 确定ARF端口编码规范
- [ ] 设计MUL/MAC伪指令语法
- [ ] 实现汇编器扩展
- [ ] 编写测试用例
- [ ] 更新文档
- [ ] 重写数学库利用硬件乘法

## 参考

- IEEE 754浮点标准（FP16实现）
- Gaussian workload（现有MUL/MAC用例）
- ARM Cortex-M DSP指令集（类似的MAC设计）

---

**最后更新**: 2026-09-03  
**分配给**: 待定  
**预计完成**: 待评估
