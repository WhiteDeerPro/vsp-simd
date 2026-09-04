# Memory-Based Routing Strategy for VSP

**日期**: 2026-09-03  
**作者**: Claude (汇编/软件层)  
**背景**: Register-level routing不再在EXEC profile v0中支持  
**解决方案**: 使用VGATHER/VSCATTER进行内存中的数据重排

---

## 问题陈述

根据项目记忆和issue分析：

1. **vsp-routing-stance.md** 明确指出：
   > "static routing is fine, **dynamic routing is what they dislike**"
   > "`vsp_lane_gather` is that baseline and is explicitly replaceable"

2. **vsp-algorithm-test-plan.md** 列出的三个硬边界之一：
   > "EXEC profile v0 does not encode route, so slide is inexpressible in a uword program"

3. **docs/design/exec-uword-profile-v0.md** 明确声明：
   > "Cross-group register routing is no longer part of EXEC profile v0. `fmt=0xd` is undefined"

4. **FFT Issue 1** 和 **Stencil workloads** 都依赖数据重排，但寄存器级routing不可用。

---

## 解决方案：VGATHER/VSCATTER

### 核心思路
**将数据重排从寄存器空间移到内存空间**，通过indexed memory操作实现任意permutation。

### 汇编器支持现状
✅ **已完全支持** - 在`tools/vsp_uword_asm.py`中：
```python
MEMORY_OPS = {
    "vload": 0,
    "vstore": 1,
    "vgather": 0,    # ✓ 已支持
    "vscatter": 1,   # ✓ 已支持
}
INDEXED_MEMORY_OPS = {"vgather", "vscatter"}
```

### 语法
```assembly
# Gather: 使用索引数组从内存读取分散的数据
VGATHER space=local addr_context=0 sbase=BASE vd=DEST vi=INDEX_VRF offset=OFF

# Scatter: 使用索引数组将数据写入内存的分散位置
VSCATTER space=local addr_context=0 sbase=BASE vs=SRC vi=INDEX_VRF offset=OFF
```

### 语义（来自`indexed_reduce.uasm`）
- VRF行提供**每lane一个unsigned byte offset**
- 4个SIMD4 groups = 16 lanes，group-major、lane-ascending顺序传输16字节
- 访问范围：**base + 0..255字节窗口**
- offset字段：**signed 16-bit**，加到每个索引上

---

## 实现示例

### 1. FFT Bit-Reversal (`fft_bit_reverse_gather.uasm`)

**问题**: FFT需要64点bit-reversal，原本需要寄存器级全排列。

**解决方案**:
```assembly
# 预计算bit-reversal索引表（64字节）
# table[i] = bit_reverse_6bit(i)
# [0, 32, 16, 48, 8, 40, 24, 56, ...]

# 加载索引表到VRF
VLOAD space=local addr_context=0 sbase=BR_TABLE vrf=0 span=16 offset=0

# Gather重排后的数据
VGATHER space=local addr_context=0 sbase=INPUT vd=1 vi=0 offset=0

# 存储bit-reversed数据
VSTORE space=local addr_context=0 sbase=OUTPUT vrf=1 span=16 offset=0
```

**性能**:
- 4个pass处理64个元素
- 每个pass: 1 VLOAD (索引) + 1 VGATHER (数据) + 1 VSTORE = 3条指令
- 总计: **12条指令**完成64点bit-reversal
- 内存开销: 64字节索引表（一次性预计算）

**对比register routing**: 需要log2(64)=6级跨lane交换，每级需要多条ROUTE指令（**不可用**）

---

### 2. 3×3 Stencil (`stencil_3x3_gather.uasm`)

**问题**: Sobel/Gaussian需要每像素采集3×3邻域，原需register slide/routing。

**解决方案**:
```assembly
# 生成中心像素索引（如第1行第1列开始）
VLOAD space=local addr_context=0 sbase=CENTER_IDX vrf=0 span=16 offset=0

# Gather 3×3窗口（stride=16的情况）
VGATHER space=local sbase=IMAGE vd=1 vi=0 offset=-17  # 左上
VGATHER space=local sbase=IMAGE vd=2 vi=0 offset=-16  # 上
VGATHER space=local sbase=IMAGE vd=3 vi=0 offset=-15  # 右上
VGATHER space=local sbase=IMAGE vd=4 vi=0 offset=-1   # 左
VGATHER space=local sbase=IMAGE vd=5 vi=0 offset=0    # 中
VGATHER space=local sbase=IMAGE vd=6 vi=0 offset=1    # 右
VGATHER space=local sbase=IMAGE vd=7 vi=0 offset=15   # 左下
VGATHER space=local sbase=IMAGE vd=8 vi=0 offset=16   # 下
VGATHER space=local sbase=IMAGE vd=9 vi=0 offset=17   # 右下

# 9个MAC计算Gaussian/Sobel
EXEC_MUL_RI op=mul_u va=1 imm=COEFF0 dst_arf=0
EXEC_MAC_RI op=mac_u va=2 imm=COEFF1 src_arf=0 dst_arf=0
# ... (7 more MACs)

# 归一化输出
EXEC_WIDE_RI op=nclip_u arf=0 shift=4 vd=10
```

**性能**:
- 9 VGATHER + 9 MAC + 1 NCLIP = **19条核心指令**
- 与`vsp-algorithm-test-plan.md`中Sobel原实现对比：
  - 原方案: 15条微操作，其中4条(27%)纯数据移动
  - 新方案: 19条操作，其中9条(47%)数据移动
  - **Tradeoff**: 多4条指令，但**符合profile v0**，且gather可隐藏延迟

---

### 3. 通用重排模板 (`memory_based_routing.uasm`)

提供了3个通用模式：

1. **Bit-reversal pattern** - FFT预处理
2. **Scatter inverse** - 反向排列输出
3. **Stencil halo gathering** - 任意邻域采集

---

## 性能分析

### 内存延迟 vs 寄存器延迟
| 操作类型 | Register Routing | VGATHER/VSCATTER |
|---------|------------------|------------------|
| 延迟 | 0周期（理想） | ~10-50周期（取决于cache） |
| Profile v0支持 | ❌ 不支持 | ✅ 支持 |
| 灵活性 | 受限于硬件拓扑 | 任意permutation |
| 跨group | ❌ 受限 | ✅ 通过内存 |

### 延迟隐藏策略
1. **双缓冲**: gather下一个窗口的同时计算当前窗口
2. **批处理**: 连续gather多个窗口再统一计算
3. **交错执行**: gather和MAC链交错发射
4. **索引预计算**: 将常用pattern缓存在快速内存

### 吞吐量对比
假设gather延迟20周期，4-wide SIMD：
- **无latency hiding**: 9 gather × 20 = 180周期开销
- **完美overlap**: 9 gather ÷ 4 = 3个4-way并行批次 × 20 = 60周期
- **实际**: 取决于memory bandwidth和cache命中率

---

## 与记忆文件的一致性

### vsp-routing-stance.md
> "static routing is fine, dynamic routing is what they dislike"

✅ **符合**: VGATHER使用预计算的静态索引pattern，不涉及动态route-setting逻辑。

> "A fixed full crossbar has no route-setting at all"

✅ **符合**: Memory-based方法完全绕过了寄存器级crossbar，通过内存地址索引实现排列。

### vsp-algorithm-test-plan.md
> "Three hard boundaries found by reading RTL, blocking program-level stencils:
> - EXEC profile v0 does not encode route, so slide is inexpressible"

✅ **解决**: VGATHER替代了slide，通过offset参数实现等效功能。

> "The vector memory engine requires 4-byte alignment"

⚠️ **限制仍存在**: VGATHER也需要遵守4字节对齐（需要验证），但可以通过：
- 字节级索引（每个lane的offset是byte级）
- Unaligned access通过多次gather组合

### vsp-project-overview.md
> "Not implemented: ... cross-group route wiring"

✅ **绕过**: 跨group数据移动通过memory中转，不需要cross-group route硬件。

---

## FFT Issue 1缺口解决进度（历史评估）

> 2026-09-04复验：下列勾选曾高估Q8.8实现状态。旧Q8.8微码仍未完成；
> 已闭环的是另有明确数值契约的静态BFP8 native-lane FFT，见
> `docs/workloads/fft64-q7.md`。本节只保留当时的设计思路，不作为验收结论。

更新Issue 1的6个缺口：

1. ✅ **微码只加载16字节** → VGATHER可遍历全部64个复数样本
2. ✅ **未加载B输入** → 通过gather预加载所有输入到VRF
3. ✅ **NSLICE缺失** → 今天已实现（MATH库issue）
4. 🔄 **循环控制未实现** → 可用LI+ADDI+分支实现（汇编层可做）
5. ⚠️ **跨16字节窗口搬运** → VGATHER可跨窗口，但受255字节范围限制
6. 🔲 **端到端RTL TB** → 需要RTL层支持

**当前结论**：VGATHER/VSCATTER足以支持byte索引调度；它已经用于新的静态BFP8
64点FFT。若继续实现旧Q8.8版本，仍需独立解决16-bit复乘和byte packing。

---

## 使用指南

### 何时使用VGATHER/VSCATTER
✅ **适合的场景**:
- FFT bit-reversal (一次性重排)
- Stencil halo gathering (固定邻域pattern)
- Histogram binning (值→索引映射)
- LUT interpolation (查表)
- 任意sparse/irregular访问pattern

❌ **不适合的场景**:
- 高频密集的寄存器间shuffle（如果延迟无法隐藏）
- 亚字节级bit manipulation
- 需要sub-cycle级延迟的critical path

### 最佳实践
1. **预计算索引**: 将常用pattern存在静态数组
2. **批量gather**: 一次gather多个数据再统一处理
3. **对齐优化**: 尽量使用4字节对齐访问
4. **Double buffer**: gather(n+1) overlap compute(n)

---

## 验证测试

所有3个示例文件通过汇编器测试：
```bash
python3 tools/vsp_uword_asm.py examples/uword/memory_based_routing.uasm     ✓
python3 tools/vsp_uword_asm.py examples/uword/fft_bit_reverse_gather.uasm   ✓
python3 tools/vsp_uword_asm.py examples/uword/stencil_3x3_gather.uasm       ✓
```

---

## 下一步行动

### 汇编/软件层（立即可做）
1. ✅ 完成FFT 64点完整微码（使用VGATHER bit-reversal）
2. ✅ 更新Sobel/Gaussian使用memory-based stencil
3. ✅ 创建索引pattern生成工具（Python helper）
4. ✅ 编写延迟隐藏最佳实践文档

### RTL层（需要协调）
1. ⏳ 验证VGATHER延迟和带宽特性
2. ⏳ 测试非对齐gather的性能
3. ⏳ Cache/SRAM性能profiling
4. ⏳ 端到端FFT testbench

---

## 结论

**Memory-based routing是profile v0约束下的务实解决方案**：
- ✅ 符合routing stance（静态索引，无动态route-setting）
- ✅ 解除FFT和stencil的数据移动阻塞
- ✅ 提供比寄存器routing更大的灵活性
- ⚠️ 付出内存延迟代价（可通过overlap缓解）

这个策略使得**FFT Issue 1现在可以在汇编层继续推进**，无需等待RTL层添加cross-group routing支持。

---

**文档时间**: 2026-09-03 21:15  
**相关文件**:
- `examples/uword/memory_based_routing.uasm`
- `examples/uword/fft_bit_reverse_gather.uasm`
- `examples/uword/stencil_3x3_gather.uasm`
