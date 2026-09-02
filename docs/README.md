# VSP项目文档索引

本目录包含VSP项目的所有技术文档、交付报告和问题追踪。

## 目录结构

```
docs/
├── architecture/           # 架构文档
├── design/                # 设计文档
├── workloads/             # 工作负载示例
├── integration/           # 集成文档
├── verification/          # 验证文档
├── math/                  # 数学库文档 (新增)
├── guides/                # 使用指南 (新增)
├── delivery/              # 交付文档
├── issues/                # 问题追踪
│   ├── open/             # 待处理
│   ├── in-progress/      # 进行中
│   ├── resolved/         # 已解决
│   └── archived/         # 已归档
└── README.md             # 本文档
```

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

## 数学库文档 (新增)

### 核心文档
- `math/MATH_LIBRARY.md` - 数学库完整文档
- `math/math_library_format.md` - 数据格式定义 (Q8.8, BF16)
- `math/MULTIPLIER_GAP_ANALYSIS.md` - 乘法器资源分析

### 超越函数
- `math/TRANSCENDENTAL_FUNCTIONS.md` - 三角函数、指数对数文档
- `math/math_transcendental_plan.md` - 实现计划

### 查找表
- 生成工具: `tools/generate_lut.py`
- 数据文件: `test_data/lut/*.hex`

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

## 问题追踪

- `issues/README.md` - 问题管理指南
- `issues/open/` - 待处理问题
  - `数学库硬件加速-Claude-2026-09-03.md`
- `issues/resolved/` - 已解决问题
  - `硬件乘法器汇编支持-WhiteDeerPro-2026-09-03.md`

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
2. 参考 `build/algorithms/README.md`
3. 使用 `tools/vsp_uword_asm.py`

### 数学库使用者
1. 阅读 `math/MATH_LIBRARY.md`
2. 查看 `math/TRANSCENDENTAL_FUNCTIONS.md`
3. 了解 `math/MULTIPLIER_GAP_ANALYSIS.md`的限制

### 贡献者
1. 检查 `issues/open/`中的待处理问题
2. 遵循 `issues/README.md`中的规范
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

### issues/
问题追踪和特性请求

## 最近更新

- **2026-09-03**: 重组文档结构，创建math/和guides/目录
- **2026-09-03**: 添加超越函数文档
- **2026-09-03**: 创建问题追踪系统
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
- 文档问题: 提交到 `docs/issues/open/`
- 代码问题: 提交git issue

---

**文档版本**: 2.0  
**最后更新**: 2026-09-03
