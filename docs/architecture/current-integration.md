# 当前控制与内存集成状态

本页只回答“哪些模块现在确实连在一起”。它把严格 uword 程序闭环、decoded
MEMORY 参考闭环、独立并发候选和仿真模型分开，避免把“模块已有”误读为“程序路径
已经使用它”。

![当前控制与内存集成状态](current-integration.svg)

Graphviz 源文件为 [`current-integration.dot`](current-integration.dot)。

## 1. 两条已经能运行的路径 `[RTL事实]`

当前有两条入口不同的闭环：

1. uword 程序路径：behavioral control store → linear byte-PC source →
   multi-record framer → **slot 0** holding/action adapter → strict controller。
   profile-v0 EXEC 与最终 `CONTROL.END` 能执行和退休；MEMORY record 目前形成有序
   decode rejection。
2. decoded MEMORY 路径：外部直接提供完整 MEMORY descriptor，经 strict controller
   进入 vector memory engine，再通过 VRF arbiter 和 group state endpoint 完成
   LOAD/STORE。该路径已和 EXEC、END 做过端到端参考回归。

因此，“encoded 程序能运行 EXEC/END”和“decoded LOAD/STORE 能运行”都成立；
“encoded MEMORY uword 已能 LOAD/STORE”尚不成立。

`vsp_uword_multi_framer` 最多可同时暴露三条 record，`vsp_ordered_action_window`
也已有四项窗口、两个 EXEC view 和一个 side view，但 strict wrapper 仍只消费 slot 0。
window、late-decode holding stage 与 class engines 尚未组成并发 program path。

## 2. PC 为什么有时表现为 `+16` `[RTL事实]`

PC 是 control-word stream 的 **byte fetch cursor**。每个 32-bit word 都占 4 byte，
不论它是 EXEC base、extension，还是 MEMORY/CONTROL body：

```text
word address       = bundle_base_pc + 4 * word_index
next bundle base   = bundle_base_pc + 4 * accepted_word_count
next record header = record_start_pc + 4 * record_word_count
```

默认一次请求最多四个 word，所以满 bundle 被下游接受后通常是 `PC + 16`；最后一个
短 bundle 分别可能 `+4/+8/+12`。这不是“每条指令固定 16 byte”，也不是 data-memory
地址规则。source PC 在 bundle 交付时推进，不等待其中 action 执行或退休；当前也没有
branch/loop redirect。

## 3. 向量取数与 AGU `[RTL事实 + 分层说明]`

一条 decoded vector-memory parent 含：

```text
LOAD/STORE + context/tag
           + address-space/address-context
           + base_eaddr + signed offset
           + group mask + VRF row + span_bytes
```

当前 engine 内同时包含 span planner、unit-stride AGU、VRF child sequencing、dmem
request/response 和 parent completion。默认每个 group 的 VRF row 为 4 byte。选中
group 按编号升序接收连续 memory beat；稀疏 mask 只改变目的 group，不在内存地址中
制造洞；每个 beat 的最低地址 byte 对应该 group 的 lane 0。例如：

```text
group_mask = 4'b1011, span_bytes = 10, eaddr0 = 0x100

0x100..0x103 -> group 0, VRF[row], byte mask 1111
0x104..0x107 -> group 1, VRF[row], byte mask 1111
0x108..0x109 -> group 3, VRF[row], byte mask 0011
```

它不表示一次完成一个 10-byte 原子 memory access；当前会顺序执行三个 beat。
LOAD 的每个 beat 等 memory response 和 VRF write completion；STORE 先等 VRF read
completion/data，再等 memory write ack。随后才推进下一 beat。

AGU 只负责把 descriptor/beat index 变为 effective address 和 beat metadata。
outstanding 数量、response correlation、fault 顺序和 parent retirement 属于 transaction
engine。当前两者只是合在 `vsp_vector_memory_engine` 中，并不意味着以后必须合在一起。

## 4. 当前 outstanding 合同 `[RTL事实]`

vector memory engine 是 `1 active parent + 1 dmem beat outstanding`。`dmem_req/rsp`
没有 transaction ID，每个 accepted LOAD 或 STORE beat 都必须严格返回一条 response；
STORE 的 response 是 write acknowledgement。request、response 与 parent completion
都允许 ready/valid 背压。

无 ID 接口仍可允许多个 outstanding，但只能按 request 顺序返回，并且 requester 需要
FIFO 保存每个 beat 的 group/address/fault-retirement metadata。若以后允许乱序返回，
则必须增加 transaction ID 与 scoreboard/reorder 状态。尤其 STORE 多飞行会改变当前
stop-on-first、partial-commit 的可观察边界，不能只把深度参数调大。

新增的 `sim/models/vsp_ordered_dmem_model.sv` 是该逻辑口的可执行仿真模型：

- byte-addressed、little-endian backing array；
- STORE byte strobe 与每个 STORE 一条 acknowledgement；
- 地址空间、对齐、范围和 beat-shape fault；
- 可配置固定响应延迟与 FIFO ordered outstanding 深度；
- response 背压稳定，reset 丢弃在途 response 但保留 backing bytes；
- 独立 init/peek sideband，明确不冒充 VSP 发出的 memory transaction。

它不是物理 SRAM、cache、MMU 或 DMA。默认模型 depth=4 是为了验证一般的无 ID 有序
合同；当前 vector memory engine 实际只会占用其中一项。

## 5. 地址服务的后续边界 `[候选]`

建议保持以下分层：

```text
MEMORY semantic decode / scalar-address state
        -> vector transfer planner
        -> unit-stride AGU
        -> outstanding / response / fault transaction engine
        -> dmem effective-address port
        -> translation + protection + local/cache router
        -> physical SRAM/cache/SoC memory
```

每个 dmem beat 都带自己的 effective address、address space 和 address context。未来跨页
时应逐 beat 翻译，不能只翻译 parent base 后默认相邻 virtual page 对应相邻 physical
page。control-store fetch 与 data-memory 也应保持两个逻辑前端；即使它们最后共享
SRAM/cache，合流位置也是下游仲裁，不是让 data AGU 修改 PC。

## 6. 标量/控制侧完成度 `[RTL事实 + 候选]`

当前没有 scalar RF、scalar ALU 或 scalar load/store。已有的 scalar-like 状态只有线性
byte PC、launch envelope/tag、SIMD 广播立即数和向外返回的 reduction/count；后两者
不会写入内部 scalar state。CONTROL profile 只定义最终 `END`。

第一阶段若要让程序自行推进地址和循环，更合适的是一个小型 **sequencer state
engine**，而不是另一颗通用 CPU。候选最小集合为 `SMOVI`、`SADD`、`SADDI`、
`SET_GMASK`、计数型 `LOOP/LOOP_END`、`END`，以及 MEMORY class 的
`VLOAD/VSTORE [sbase+simm]`。它暂不需要 flags、任意条件分支、CALL/RET、SP/RA、
scalar L/S、乘除法、CSR、特权态或中断入口。

在加入 loop redirect 前，可以先做 MEMORY semantic decoder，以完整 immediate eaddr
接通当前程序路径；随后加入 scalar/address state，再把 MEMORY base 改为寄存器引用。
具体候选与非目标见[Sequencer 标量/地址状态](../design/sequencer-state.md)。
