# Sequencer 标量/地址状态

> 状态：当前能力审计与下一阶段候选，不是已冻结指令集。

## 1. 当前实际存在什么 `[RTL事实]`

| 能力 | 当前状态 |
|---|---|
| 线性 byte PC 与半开程序范围 | 已实现；control-store source 单 request outstanding |
| 默认四 word fetch | 已实现；满 bundle 接受后通常 `PC + 16` |
| 1–4 word record framing | 已实现；每个 stream word 仍是 `+4` |
| profile-v0 EXEC semantic decode | 已实现 |
| decoded MEMORY execution | 已实现参考入口，并由 encoded program path 驱动 |
| encoded MEMORY semantic decode | 已实现固定两 word `VLOAD/VSTORE/VGATHER/VSCATTER` profile |
| CONTROL | 已实现 `SMOVI/SADD/SADDI`、六种寄存器比较 branch、`J` 与 canonical final `END` |
| sequencer address-state RF / adder | 已接 strict slot-0 program path；MEMORY admission 快照 base |
| loop / branch / redirect | 已实现单 PC、PC-relative `J/BEQ/BNE/BLT/BGE/BLTU/BGEU`；无预测 |
| call/return、SP/RA | 未实现 |
| scalar LOAD/STORE | 未实现 |
| reduction/count 写 scalar state | 未实现；当前只向外返回 result |
| interrupt/trap/precise restart | 未实现；错误通过 completion/sticky status 报告 |
| I-cache / MMU / DMA | 未实现；control store 与 `dmem_*` 仍是行为/逻辑边界 |

EXEC 的 scalar immediate 是给 SIMD lanes 的广播操作数，不是标量指令。ordered action
window 的 side view 是 MEMORY/CONTROL/reject 的 class-router 结构端口，也不是 scalar
issue slot。当前 launch 捕获一次 group mask，stream 内各 record 复用它；尚无逐 record
mask 或 `SET_GMASK`。

## 2. 为什么最终仍需要少量标量状态 `[候选]`

完全展开的短 microprogram 可以让外部 sequencer 每次提供绝对地址，因此当前测试不需要
标量核。但实际 kernel 很快会需要：

- 更新 input/output/temporary buffer 地址；
- 表达行、块和 tile 的计数循环；
- 为不同 phase 改变 group mask；
- 以后按 reduction/count 结果选择少量控制路径。

这些需求不推导出通用 CPU。标量状态可以从属于 VSP sequencer，只服务 action
生成、地址形成和 program control；SIMD4 group 仍不取指、不执行地址、不处理中断。

## 3. 第一版已实现集合 `[RTL事实]`

`vsp_sequencer_state_engine` 内含 per-context、参数化的 32-bit state RF；默认每 context
32 个逻辑寄存器。register 0 恒为零，但不赋予 SP/RA/callee-save 等 ABI 角色。
RF 只在 transaction-domain reset 时清零；普通 program launch 不隐式重置它，程序若不
依赖前一 launch 留下的状态，就应先显式初始化将要读取的寄存器。
当前操作为：

| 类别 | 已实现操作 | 用途 |
|---|---|---|
| 常量/复制 | `SMOVI`（source alias `LI`） | 构造地址、stride 和 loop count |
| 整数地址 | `SADD`、`SADDI`（aliases `ADD/ADDI`） | base/offset/stride；负 immediate 已覆盖 SUBI |
| 控制流 | `J`、`BEQ/BNE`、`BLT/BGE`、`BLTU/BGEU` | 同一 PC 的跳转，以及相等、有符号、无符号双寄存器比较 |

加法按 state width 模回绕，不产生 flags 或 overflow exception。decoded command 在
handshake 时写状态，每项 accepted command 恰好产生一项可背压 completion；非法 op、
context 或实际使用的 register 产生零副作用错误 completion。组合 base query 已接到
MEMORY decoder；decoder 只在 action admission 时把同 context 的 base 值快照到
canonical MEMORY descriptor，memory engine 不会在传输过程中重新读取 state RF。

当前内部编码为：`SMOVI`、`SADDI` 使用一条 CONTROL header 加一条完整 32-bit
immediate body，`SADD` 是单 word；四种 vector memory pseudo-op 都使用固定两 word
MEMORY record。header 携带 op、address mode、address space/context、五位 state base
register 和 data VRF row。`UNIT_STRIDE` 的五位 span code `0` 表示填满全部被选 group，
并在 admission 后解析为 `4 * popcount(group_mask)` byte；code `1..31` 是显式 span。
`INDEX_U8` 则在同一字段中保存 index VRF row，decoded span 保持为零。第二 word 必须是
当前 signed 16-bit memory offset 的 canonical 32-bit 符号扩展。group mask 仍来自 launch
envelope，不在 record 中逐项编码。strict wrapper
一次只允许一个 action active，因此 state update 退休后才会接纳后续 MEMORY，已经
保证这条参考路径上的 state RAW；这不等于并发 action window 已有 state dependency
scoreboard。

branch family 同样是固定两 word：header 保存
`J/BEQ/BNE/BLT/BGE/BLTU/BGEU` 条件和两个五位 state register，body 是相对 branch
header PC 的 signed 32-bit byte displacement。目标必须 4-byte
对齐；taken target 必须位于 launch 半开范围 `[start_pc,end_pc)`。`BEQZ/BNEZ/BLTZ/BGEZ`
以及交换零操作数的 `BGTZ/BLEZ` 都是 assembler 伪指令。比较直接读取两个 register，不保存
NZP/flags，所以没有隐式 condition-code RAW dependency。每条合法 branch 都显式选择 target 或
fall-through PC，并冲刷 framer 中尚未发射的 word、EOF 和可能预取到的 END；若旧 fetch
request 已 outstanding，其 response 会被排空但不采纳。branch completion 也遵守统一的
ready/valid 背压合同。branch compare 与 state arithmetic 复用同一个双读 RF view；当前
strict wrapper 不会同时提出两者，因此没有为 branch 额外推导两组读端口。

当前没有 `SET_GMASK`、专用 `LOOP/LOOP_END`、CALL/RET、scalar memory、
乘除法、CSR、特权态和中断。`END` 仍由既有 CONTROL path 实现，不在 state engine 内。
当前定向程序已经执行
`SMOVI/SADDI → BNE` 倒计时循环，以及
`SMOVI/SADD/SADDI → VLOAD [sbase+simm] → EXEC → VSTORE [sbase+simm] → END`。
两者都只走 strict slot 0、全局 single-active 路径；没有 I-cache、MMU、DMA 或多 action
并发。

### 3.1 裁剪后的寻址与调用边界 `[候选]`

vector memory 已采用唯一的基础地址原语：

```text
VLOAD/VSTORE:       eaddr(k)    = state[sbase] + simm16 + k
VGATHER/VSCATTER:   eaddr(lane) = state[sbase] + simm16 + u8(vi[lane])
```

它不为每种 scalar 写法复制一个 vector 版本。PC 属于 control-store I-side，D-side 地址
另带 address-space/context；因此不增加隐式 `mem[PC+offset]`。如果以后需要 scalar
memory，首个原语应只有对齐 32-bit 的 `LW rd,simm(sbase)` 与
`SW rs2,simm(sbase)`：PC-relative data address 由显式 PC-address-forming operation 加
`LW/SW` 合成，双重间接由两条 `LW` 合成。32-bit 操作命名为 `LW/SW`；`LD` 留给未来
真正的 64-bit load。

launch 的 `start_pc` 已定义程序入口，当前 leaf kernel 用 `J` 和条件 branch 已可闭环。
若 workload 或 C ABI 需要子程序，再加入 `JAL/JALR`，并令 `J/CALL/JR/RET` 成为其伪指令；
这一步应与通用 state-RF writeback ingress 一起完成，使 link、未来 scalar load 和
reduction-to-state 共用同一提交边界。`LEA/AUIPC` 也只在需要可重定位 PC-relative
地址时加入；当前完整 immediate 的 `SMOVI/LI` 已能构造绝对地址。

## 4. 后续落地顺序 `[候选]`

1. 保持单 PC、单 issue slot 和 global single-active 基线，补齐 4-group/16-byte 与
   16-group/64-byte 的 state/MEMORY 定向程序。
2. 根据实际多 group 程序加入 `SET_GMASK`，同样在 action admission 时快照；当前只有
   一个 execution context。
3. 用实际 kernel 评估当前“每条 branch 都 redirect/refetch”的保守策略，再决定是否为
   not-taken 引入顺序快路径。
4. 有负载证据后增加通用 state-RF writeback，再评估 reduction/count、`JAL/JALR` 与
   scalar `LW/SW` 的接入顺序。
5. 只有在 trace 表明单 action admission 是瓶颈时，才研究小型 action window 及其
   state/VRF/MEMORY dependency metadata；它不增加 PC，也不把 slot 变成线程。

现有 `stream_abort` 仍只表示 transport failure；正常 redirect 使用独立 framer flush。
首版 loop 不需要预测：strict single-active 保证 branch 解析时没有年轻 action 已送入
EXEC/MEMORY engine，只有 source/framer 的预取状态需要撤销。
