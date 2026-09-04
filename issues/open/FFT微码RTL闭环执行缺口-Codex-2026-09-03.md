# FFT微码与RTL闭环执行缺口

**报告者**: Codex  
**日期**: 2026-09-03  
**优先级**: High  
**类型**: Enhancement  
**状态**: Open

## 描述

仓库已有FFT测试信号、Q8.8旋转因子、bit-reverse表和
`examples/uword/dsp_fft_radix2.uasm`，但该微码文件明确是概念性结构，目前不能
作为64点FFT的端到端VSP实现。新增的`make test-vcs-fft64`可以在VCS中验证现有
数据和行为级radix-2算法，但不经过VSP取指、解码、SIMD执行和D-memory路径。

## 已确认缺口

1. 微码只加载了各16字节实部/虚部，没有遍历64个复数样本。
2. 首级蝶形引用VRF 2/3，但程序没有为它们装载对应的B输入。
3. 通用旋转因子复乘在ARF中产生部分积后，没有完成`NSLICE`、符号处理、
   Q8.8右移、舍入/截断及VRF回写。
4. 六级蝶形的索引生成、循环控制、跨16字节窗口搬运和逐级原位回写未实现。
5. 程序只存储一个16字节实部结果，没有输出64个复数频点。
6. 当前VCS demo没有实例化VSP DUT，不能给出硬件周期数或吞吐率。

## 要求建议

### 1. 固化数值语义

- 明确FFT数据格式、每级是否缩放、截断或舍入方式以及饱和/回绕策略。
- 明确有符号Q8.8复乘如何映射到现有8x8 `MUL_S/MAC_S`、ARF和
  `NSLICE/NCLIP`。
- 给出64点bin-8向量的逐级golden状态，便于定位首次偏差。

### 2. 完成可执行微码

- 实现64点bit-reverse装载或预重排输入约定。
- 实现全部6级、每级32个蝶形及twiddle索引循环。
- 按当前4-group/16-byte行宽分块调度，保证数据移动不依赖已退出产品路径的
  跨group寄存器路由。
- 将64个复数输出写回D-memory，并以合法`END`退休。

### 3. 增加端到端RTL TB

- 在VCS中实例化当前program/memory wrapper，装载组装后的FFT微码和现有fixture。
- 使用独立D-memory模型提供输入、twiddle和输出缓冲区。
- 对比行为级golden结果，至少检查bin 8/56、全频点误差界、程序完成状态和
  非法操作/协议错误。
- 记录总周期、EXEC/MEMORY action数量和D-memory请求数量。

## 验收标准

- `dsp_fft_radix2.uasm`不再包含未完成占位或未初始化VRF引用。
- 汇编器测试覆盖该程序，并能生成稳定的hex/listing。
- VCS端到端回归执行真实VSP RTL，64点bin-8向量在已声明的Q8.8误差界内通过。
- 行为级VCS demo继续作为数据/算法参考，RTL测试不得仅复制同一实现作为oracle。
- 文档持续区分算法参考结果与RTL周期性能。

## 影响

在该issue关闭前，仓库可以演示“VCS执行FFT行为模型”，但不能宣称“VSP RTL已
运行完整64点FFT”或引用当前文档中的周期估计作为实测性能。
