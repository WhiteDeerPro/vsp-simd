# VSP项目文档索引

本目录包含VSP项目的所有技术文档和交付报告。

## 目录结构

```
docs/
├── architecture/           # 架构文档
├── design/                # 设计文档
├── workloads/             # 工作负载示例
├── integration/           # 集成文档
├── verification/          # 验证文档
├── math/                  # 数学库文档
├── guides/                # 使用指南
├── delivery/              # 交付文档
└── README.md             # 本文档
```

**注**: 问题追踪系统位于根目录 `/issues/`

## 核心架构文档

### 系统概览
- `architecture/overview.md` - VSP架构概述
- `architecture/terminology.md` - 术语表
- `architecture/current-integration.md` - 当前集成状态
- `architecture/microarchitecture.md` - 微架构细节

### 数据通路
- `architecture/datapath.md` - 数据通路设计
- `architecture/arithmetic.md` - 算术单元
- `architecture/register-file.md` - 寄存器文件
- `architecture/routing.md` - 路由架构

### 内存系统

- `architecture/memory-hierarchy.md` - 内存层次
- `integration/memory-subsystem.md` - 内存子系统集成
- [integration/host-mmio.md](integration/host-mmio.md) - 被动主机控制口、任务结果、MMU/维护与IRQ寄存器ABI

## 设计文档

- `design/instruction-delivery.md` - 指令交付和解码
- `design/cluster-control.md` - 集群控制
- `design/data-movement.md` - 数据移动
- `design/exec-uword-profile-v0.md` - EXEC指令配置
- `design/sequencer-state.md` - 序列器状态
- `design/development-roadmap.md` - 开发路线图

## 工作负载示例

- `workloads/gaussian3x3.md` - 高斯滤波 (使用MUL/MAC)
- `workloads/sobel3x3.md` - Sobel边缘检测
- `workloads/gaussian3x3-separable.md` - 可分离高斯
- `workloads/median3x3.md` - 中值滤波
- `workloads/fft64-q7.md` - 64点静态BFP8 FFT、RAM/cache闭环与频谱绘图
- `workloads/fft64-mixed-s8.md` - 64点q/127三音FFT、独立DFT与Verdi/Graphviz闭环

## 数学库文档

### 核心文档
- `math/MATH_LIBRARY.md` - 数学库完整文档
- `math/math_library_format.md` - 数据格式与实现边界 (Q8.8, BFP8, BF16)
- `math/BLOCK_FLOATING.md` - 当前静态BFP8数值契约
- `math/M8E8.md` - M8E8逐元素补码浮点oracle与SoA ABI
- `math/MULTIPLIER_GAP_ANALYSIS.md` - 乘法器资源分析

### 超越函数
- `math/TRANSCENDENTAL_FUNCTIONS.md` - 三角函数、指数对数文档
- `math/math_transcendental_plan.md` - 实现计划

### 查找表
- 生成工具: `../tools/generate_lut.py`
- 数据文件: `../test_data/lut/*.hex`

## 使用指南

- `guides/scatter_operations_guide.md` - Gather/Scatter操作指南

## 交付文档

### 算法库
- `delivery/ALGORITHM_DELIVERY.md` - 图像算法交付报告
- `delivery/ALGORITHMS_SUMMARY.txt` - 算法快速参考

### 数学库
- `delivery/MATH_LIBRARY_REPORT.md` - 数学库实现报告

### 项目总结
- `delivery/PROJECT_DELIVERY_SUMMARY.md` - 完整项目交付
- `delivery/FINAL_DELIVERY_SUMMARY.md` - 最终交付总结

## 验证文档

- `verification/harness.md` - 验证框架

## 探索性文档

- `explorations/architecture-qa.md` - 架构问答
- `explorations/data-lifecycle.md` - 数据生命周期
- `explorations/mul32-byte-convolution.md` - 32位乘法探索

## 快速开始

### 新用户
1. 阅读 `architecture/overview.md`
2. 查看 `architecture/terminology.md`
3. 参考 `workloads/gaussian3x3.md`示例

### 算法开发者
1. 查看 `delivery/ALGORITHM_DELIVERY.md`
2. 参考 `../build/algorithms/README.md`
3. 使用 `../tools/vsp_uword_asm.py`

### 数学库使用者
1. 阅读 `math/MATH_LIBRARY.md`
2. 查看 `math/TRANSCENDENTAL_FUNCTIONS.md`
3. 了解 `math/MULTIPLIER_GAP_ANALYSIS.md`的限制

### 贡献者
1. 检查 `../issues/open/`中的待处理问题
2. 遵循 `../issues/README.md`中的规范
3. 提交issue到对应目录

## 文档分类说明

### architecture/
硬件架构相关的技术规格和设计决策

### design/
指令集、控制流、数据移动等设计文档

### workloads/
具体算法实现示例，包含性能分析

### math/
数学库相关的所有文档，包括超越函数和查找表

### guides/
操作指南和最佳实践

### delivery/
项目交付报告和总结

## 最近更新

- **2026-09-05**: 接入被动host MMIO控制与冻结结果/故障寄存器；AXI与SoC下级目标仍为外部边界
- **2026-09-04**: 增加q/127三音FFT、独立DFT、Graphviz多视图及Verdi闭环
- **2026-09-04**: 增加静态BFP8 FFT闭环、Graphviz频谱绘图与M8E8数值契约
- **2026-09-03**: 重组文档结构，创建math/和guides/目录
- **2026-09-03**: 问题追踪移至根目录
- **2026-09-03**: 添加超越函数文档
- **2026-09-02**: 完成数学库和算法库交付

## 文档编写规范

1. 使用Markdown格式
2. 避免过度使用emoji (考虑编码兼容性)
3. 代码块使用语言标识
4. 包含目录和章节标题
5. 提供使用示例
6. 注明日期和版本

## 联系方式

- 项目维护者: VSP Developer
- 文档问题: 提交到 `/issues/open/`
- 代码问题: 提交git issue

---

**文档版本**: 2.2
**最后更新**: 2026-09-05
