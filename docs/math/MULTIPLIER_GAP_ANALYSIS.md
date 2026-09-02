# VSP数学库的乘法器资源分析和建议

> **状态更新（2026-09-03）**：本文发现的工具链缺口已经关闭。
> 汇编器现支持 `EXEC_MUL_RR/RI` 和 `EXEC_MAC_RR/RI`，并把旧的
> `EXEC_ALU_RR/RI op=mul_*/mac_*` 写法映射到独立的 `fmt=4/5/6`。
> 性能数字仍是估算，在数学库改写并完成程序级测量前不应视为实测结论。

## 重要发现

### 1. VSP确实有8位硬件乘法器

在`rtl/units/simd_lane.sv`中实现了：
- **MUL_U** (0x16): 8×8无符号乘法 → 16位结果到ARF
- **MUL_S** (0x17): 8×8有符号乘法 → 16位结果到ARF
- **MAC_U** (0x18): 8×8无符号乘累加 → ARF = ARF + A×B
- **MAC_S** (0x19): 8×8有符号乘累加 → ARF = ARF + A×B

```systemverilog
// 来自 simd_lane.sv
product_u = a_i * b_i;                    // 8×8 = 16位
product_s = $signed(a_i) * $signed(b_i);

SIMD_OP_MUL_U: begin
  result_o = product_u[ELEM_W-1:0];       // 低8位到VRF
  wide_o = {{...}, product_u};            // 完整16位到ARF
  produces_wide = 1'b1;
end

SIMD_OP_MAC_U: begin
  result_o = product_u[ELEM_W-1:0];
  wide_o = acc_i + {{...}, product_u};    // ARF累加
  produces_wide = 1'b1;
end
```

### 2. Gaussian workload确实使用了硬件乘法

在`sim/gaussian3x3_tb.cpp`中：
```cpp
constexpr uint8_t kMulU = 0x16;
constexpr uint8_t kMacU = 0x18;

// 直接设置操作码
dut.op_i = kMulU;  // 或 kMacU
```

Gaussian算法用9个MUL/MAC完成卷积，这是高效的硬件路径。

### 3. 汇编器接入状态

原始问题是 `tools/vsp_uword_asm.py` 没有公开 profile-v0 已定义的乘法格式。
该缺口现已修复：

- `EXEC_MUL_RR/RI` 生成 `fmt=4`；
- `EXEC_MAC_RR` 生成 `fmt=5`；
- `EXEC_MAC_RI` 生成 `fmt=6` 并强制携带立即数扩展字；
- `src_arf`/`dst_arf`、VRF/ARF写回、mask、export和reduction均可编码；
- HALF/WORD模式会在汇编期拒绝，因为当前硬件只定义BYTE MUL/MAC。

### 4. 为什么原来会缺失？

查看文档`docs/design/instruction-delivery.md`：
> The uword assembler and behavioral control store form a development format, not a frozen public ISA.

EXEC profile v0 实际已经为MUL/MAC分配独立格式，但早期工程汇编器只实现了ALU、
CONTROL和MEMORY等部分格式。因此这是工具实现缺口，而不是指令编码未定义。

## 对数学库的影响

### 当前状况

✅ **uword汇编可以使用硬件8×8乘法**
- 专用MUL/MAC拼写直接编码到现有EXEC profile；
- C++ datapath测试和uword工具链现在覆盖同一组canonical操作；
- 既有`math_mul16_*.uasm`多数仍是软件算法，需另行改写和数值验证。

### 性能对比

| 方法 | 指令数 | 精度 | 可用性 |
|------|--------|------|--------|
| 硬件MUL (部分积原语) | 4个8×8乘积起步 | 精确 | ✓ 汇编器可编码 |
| 移位-加法 | 200+ | 精确 | ✓ 可用 |
| Booth算法 | 150+ | 精确 | ✓ 可用 |
| 查表法 | 25 | 精确 | ✓ 可用 |

## 已实施的解决方案

### 独立格式编码

MUL/MAC不能加入`ALU_OPS`后直接使用canonical操作号；ALU字段中的sub-op是格式局部
编号。汇编器必须生成profile-v0的独立`fmt=4/5/6`。现在可以写：
```assembly
# 8×8乘法，结果到ARF
EXEC_MUL_RR op=mul_u mode=byte va=2 vb=4 dst_arf=0

# 乘累加
EXEC_MAC_RR op=mac_u mode=byte va=2 vb=4 src_arf=0 dst_arf=0
```

立即数形式使用`EXEC_MUL_RI`和`EXEC_MAC_RI`。旧的
`EXEC_ALU_RR/RI op=mul_*/mac_*`由汇编器作为兼容别名转到相同编码。

### 方案2：使用WIDEN+WADD模拟乘法

VSP有WIDEN和WADD操作，可以部分利用ARF：

```assembly
# WIDEN: 将8位扩展到32位ACC
EXEC_ALU_RR op=widen_u mode=byte va=2 vb=0 dst_arf=0

# WADD: acc + aligned_a + aligned_b
EXEC_ALU_RR op=wadd_u mode=byte va=3 vb=4 src_arf=0 dst_arf=0 align=1
```

这样可以做位移累加，但仍需多步。

### 方案3：仅保留软件实现

**优点**：
- 不修改汇编器
- 算法仍然正确
- 适合原型验证

**缺点**：
- 性能慢100倍
- 未利用硬件资源

## 16×16乘法映射草案

汇编器已经支持MUL/MAC，但完整16×16乘法仍需显式组合和验证部分积：

```assembly
# 16×16 = (A_hi*256 + A_lo) * (B_hi*256 + B_lo)

# 提取字节
EXEC_ALU_RI op=and mode=byte va=0 vd=2 imm=0xff    # A_lo
EXEC_ALU_RI op=shr_u mode=byte va=0 vd=3 imm=8     # A_hi
EXEC_ALU_RI op=and mode=byte va=1 vd=4 imm=0xff    # B_lo
EXEC_ALU_RI op=shr_u mode=byte va=1 vd=5 imm=8     # B_hi

# P0 = A_lo * B_lo (低16位到ARF a0)
EXEC_MUL_RR op=mul_u mode=byte va=2 vb=4 dst_arf=0

# P1 = A_lo * B_hi (加到a1)
EXEC_MUL_RR op=mul_u mode=byte va=2 vb=5 dst_arf=1

# P2 = A_hi * B_lo (累加到a1)
EXEC_MAC_RR op=mac_u mode=byte va=3 vb=4 src_arf=1 dst_arf=1

# P3 = A_hi * B_hi (到a2)
EXEC_MUL_RR op=mul_u mode=byte va=3 vb=5 dst_arf=2

# 现在需要组合：
# result[15:0] = ARF[0][15:0]
# result[31:16] = ARF[2][15:0] + (ARF[1][23:8])

# 后续仍需为汇编器公开profile-v0 WIDE_CONVERT/NSLICE拼写，
# 再显式完成部分积移位、导出和进位组合。
```

**注意**：20-30条及7-10倍仅为早期估算；完整映射和程序级测试完成前不能作为
已交付性能结论。

## 实际建议

### 已完成
✓ **扩展汇编器支持MUL/MAC**
- 增加4个乘法伪指令和2个兼容入口
- 处理ARF端口、立即数扩展字和全部写回控制
- 编写精确编码、边界与拒绝测试

### 后续
✓ **优化数学库**
- 公开所需的WIDE_CONVERT/NSLICE汇编拼写
- 用硬件MUL重写16×16乘法
- 实现高效的Q8.8乘法
- 基于MAC的FIR滤波器库

## 示例：如何在C++ testbench中使用硬件乘法

如果需要高性能验证，可以参考Gaussian的方法：

```cpp
// 设置8×8乘法
dut.op_i = 0x16;              // MUL_U
dut.src_a_addr_i = 0;         // VRF[0] = A
dut.src_b_addr_i = 1;         // VRF[1] = B
dut.dst_arf_addr_i = 0;       // 结果到ARF[0]
dut.issue_i = 1;
tick(dut);

// ARF[0]现在包含16位乘积
// 可以用NSLICE导出到VRF
```

## 总结

**现状**：
- ✅ VSP有功能完整的8×8硬件乘法器
- ✅ RTL级别完全可用
- ✅ uword汇编器支持MUL/MAC寄存器型和立即数型伪指令
- ✅ 程序流可以到达硬件乘法路径

**影响**：
- 既有数学库仍主要使用软件乘法
- 完整多byte乘法还需要宽结果导出、移位组合和数值验证
- 性能差距需要实测，不能沿用早期100倍估算

**建议**：
1. **短期**：补齐WIDE_CONVERT/NSLICE汇编入口
2. **中期**：基于硬件乘法重写数学库
3. **中期**：增加程序级结果校验与性能基线

---

**结论**：原问题属于工具链缺口，现已按profile-v0真实格式关闭；后续重点是宽结果
导出和数学库映射，而不是再次修改ALU子操作表。
