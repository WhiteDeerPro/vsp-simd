# VSP项目文档索引

本目录包含VSP项目的所有技术文档、交付报告和问题追踪。

## 目录结构

```
docs/
├── architecture/           # 架构文档（已有）
├── design/                # 设计文档（已有）
├── workloads/             # 工作负载文档（已有）
├── integration/           # 集成文档（已有）
├── verification/          # 验证文档（已有）
├── delivery/              # 交付文档（新增）
├── issues/                # 问题追踪（新增）
├── MATH_LIBRARY.md        # 数学库完整文档
├── math_library_format.md # 数学格式定义
├── MULTIPLIER_GAP_ANALYSIS.md  # 乘法器资源分析
├── scatter_operations_guide.md # 已有
└── README.md              # 本文档
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
- `design/development-roadmap.md` - 开发路线图

## 工作负载示例

- `workloads/gaussian3x3.md` - 高斯滤波（使用MUL/MAC）
- `workloads/sobel3x3.md` - Sobel边缘检测
- `workloads/gaussian3x3-separable.md` - 可分离高斯
- `workloads/median3x3.md` - 中值滤波

## 交付文档（新增）

### 算法库
- `delivery/ALGORITHM_DELIVERY.md` - 图像算法交付报告
- `delivery/ALGORITHMS_SUMMARY.txt` - 算法快速参考

### 数学库
- `delivery/MATH_LIBRARY_REPORT.md` - 数学库实现报告
- `MATH_LIBRARY.md` - 数学库完整文档
- `math_library_format.md` - 数据格式定义
- `MULTIPLIER_GAP_ANALYSIS.md` - 乘法器资源分析

### 项目总结
- `delivery/PROJECT_DELIVERY_SUMMARY.md` - 完整项目交付
- `delivery/FINAL_DELIVERY_SUMMARY.md` - 最终交付总结

## 问题追踪（新增）

- `issues/README.md` - 问题管理指南
- `issues/open/` - 待处理问题
  - `硬件乘法器支持-WhiteDeerPro-2026-09-03.md`
- `issues/in-progress/` - 进行中的问题
- `issues/resolved/` - 已解决问题
- `issues/archived/` - 已归档问题

## 验证文档

- `verification/harness.md` - 验证框架

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
1. 阅读 `MATH_LIBRARY.md`
2. 查看 `delivery/MATH_LIBRARY_REPORT.md`
3. 注意 `MULTIPLIER_GAP_ANALYSIS.md`中的限制

### 贡献者
1. 检查 `issues/open/`中的待处理问题
2. 遵循 `issues/README.md`中的规范
3. 提交issue到对应目录

## 最近更新

- **2026-09-03**: 创建文档管理结构
- **2026-09-03**: 添加硬件乘法器issue
- **2026-09-02**: 完成数学库交付
- **2026-09-02**: 完成图像算法库

## 联系方式

- 项目维护者: VSP Developer
- 文档问题: 提交到 `docs/issues/open/`
- 代码问题: 提交git issue

---

**文档版本**: 1.0  
**最后更新**: 2026-09-03
