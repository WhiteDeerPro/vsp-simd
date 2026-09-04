# VSP项目问题追踪

本目录用于存放各个代码贡献者提出的问题、建议和需求。

## 文件命名规范

```
事务简要描述-报告者-报告日期.md
```

例如：
- `硬件乘法器支持-WhiteDeerPro-2026-09-03.md`
- `动态块浮点与BF16执行缺口-Codex-2026-09-04.md`

## 目录结构

```
issues/
├── open/           # 待处理的问题
├── in-progress/    # 进行中的问题
├── resolved/       # 已解决的问题
└── archived/       # 已归档的问题
```

## 问题模板

每个issue文件应包含：

1. **标题**: 问题简要描述
2. **报告者**: 提出者姓名
3. **日期**: 提出日期
4. **优先级**: High/Medium/Low
5. **类型**: Bug/Feature/Enhancement/Question
6. **描述**: 详细说明
7. **影响**: 对项目的影响
8. **建议方案**: 可能的解决方案
9. **状态**: Open/In Progress/Resolved/Archived

## 当前活跃问题

待处理项见`open/`，正在实施但尚未满足全部验收条件的事项见`in-progress/`。
`resolved/`只保存已经有验证证据并完成收口的事项。

- [FFT微码与RTL闭环执行缺口](open/FFT微码RTL闭环执行缺口-Codex-2026-09-03.md)
- [动态块浮点与BF16执行缺口](open/动态块浮点与BF16执行缺口-Codex-2026-09-04.md)
- [M8E8补码浮点执行](in-progress/M8E8补码浮点执行-Codex-2026-09-04.md)
- [数学库性能优化](in-progress/数学库硬件加速-Claude-2026-09-03.md)

## 最近已解决

- [FFT64三音定点频谱闭环](resolved/FFT64三音定点频谱闭环-Codex-2026-09-04.md)
- [文档状态源收敛](resolved/文档状态源收敛-Codex-2026-09-04.md)
