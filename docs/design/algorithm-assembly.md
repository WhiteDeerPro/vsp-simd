# 算法汇编层与验证边界

## 目标

算法汇编层把“一个算法怎样分块、使用哪些状态寄存器和 VRF 行、怎样循环”变成
当前编码器可以检查的 `.uasm`。它不代替精确编码器，也不把软件参考模型塞进
RTL。当前工作流是：

```text
算法语义与独立参考结果
        │
        ▼
静态调度 / VSPAsmBuilder（可选）
        │  生成可读 .uasm
        ▼
vsp_uword_asm.py
        │  标签解析、profile 合法性、32-bit word 编码
        ▼
control-store hex
        │
        ▼
program wrapper → sequencer state / EXEC / MEMORY → D-memory
        │
        ▼
完成、错误、请求轨迹和输出数据检查
```

这里的“算法层”首先是一个静态排程层，不尝试成为 C 编译器。它允许以后加入更
成熟的寄存器分配和分块器，同时保持 `.uasm` 与精确编码器仍可独立审查。

## 四层职责

### 1. 算法语义与参考模型

每个闭环例子应说明：

- 输入、输出地址布局和数据范围；
- 一次向量动作处理多少 byte、需要怎样的 launch group mask；
- 尾块、别名、溢出或饱和的程序语义；
- 独立于向量指令顺序的标量参考结果。

参考模型回答“结果是什么”，不逐条复刻汇编执行过程。

### 2. 静态调度 builder

[`vsp_asm_generator.py`](../../tools/vsp_asm_generator.py) 提供轻量 builder：

- 分配或检查 32 个 sequencer state register 与 16 个 VRF row；
- 生成 unit-stride/indexed MEMORY、EXEC、state、label 和 branch 源码；
- 检查明显的 row/register/span 越界；
- 把生成文件放在 `build/generated/uword/`，避免把临时源码散落到
  `examples/`。

builder 只输出文本，不包含二进制位域。其输出仍必须交给精确编码器检查。

```bash
python3 tools/vsp_asm_generator.py
python3 tools/vsp_asm_generator.py \
  --program brightness_loop --output-dir /tmp/vsp-uasm --base-pc 0x20
```

### 3. 精确 `.uasm` 与编码器

[`vsp_uword_asm.py`](../../tools/vsp_uword_asm.py) 负责当前 source contract：

- 标签与 byte-PC；
- state、branch、EXEC 和 MEMORY 字段合法性；
- extension word、立即数和寄存器范围；
- `.hex`、listing 和 symbol map。

被提交到 [`examples/uword`](../../examples/uword) 的程序是便于审查的精确来源。
builder 生成同一算法时，测试比较两者编码后的 word，防止两份描述静默漂移。

### 4. 程序执行与结果检查

仅“能汇编”不能证明算法可运行。RTL 算法回归还应：

1. 装载 control-store 和 D-memory；
2. 给出 start/end PC、context 与 group mask；
3. 设置超时并观察 END、fault 和残留 outstanding；
4. 检查 completion class/tag/mask/status；
5. 用独立参考模型检查输出 memory 或 reduction result。

## 当前第一条闭环程序

[`program_brightness_loop.uasm`](../../examples/uword/program_brightness_loop.uasm)
处理 48 byte：

```text
dst[i] = min(255, src[i] + 40)
```

它使用四个 SIMD4 group（launch mask `0xf`），每轮处理 16 byte，共执行三轮：

```text
VLOAD → ADD_SAT_U → VSTORE → ADDI(pointer) → BLTU(loop)
```

静态程序为 15 个 32-bit word，适配现有 16-word wrapper 回归配置。测试实际检查
18 个 action completion、24 个 D-memory word request、48 个输出 byte、输入保持、
输出边界 guard 以及 END 后无残留 response。这条证据覆盖从取指到最终 memory
结果的完整路径。

[`simple_algorithms_tb.cpp`](../../sim/simple_algorithms_tb.cpp) 仍有价值，但它位于
datapath 边界；它和上述 program-level 回归回答的是两个不同问题。

## 例子状态的表达

算法材料按它实际达到的层次描述：

| 状态 | 可以主张的内容 |
|---|---|
| 调度草图 | 数据布局或指令顺序值得研究 |
| 可汇编 | 当前编码器接受语法和资源编号 |
| 可执行 | program wrapper 能运行到 END，未发生错误 |
| 结果闭环 | 输出或 reduction 与独立参考结果一致 |

例如，现有四 bin histogram predicate 已能汇编并产生 group-local reduction；它不
等同于完整的 256-bin histogram。完整 histogram 仍需解决同组重复 index、
group-specific bin base、16-bit counter layout 和 reduction 结果回写。类似地，
双 VRF bank 的顺序排程不自动意味着 MEMORY 与 EXEC 已经重叠。

## 后续扩展顺序

在不扩充指令集的前提下，可以继续加入 threshold、SAD、短 FIR 等闭环程序，并
记录每个程序的 state/VRF 占用、指令 word 数、D-memory 请求数和向量利用率。
当多个负载都反复暴露同一个缺口时，再评估新 state 操作、reduction 消费路径、
访存原子性或并发窗口，避免由单个概念稿直接反推硬件功能。
