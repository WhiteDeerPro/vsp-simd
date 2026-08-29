# Sequencer 标量/地址状态

> 状态：当前能力审计与下一阶段候选，不是已冻结指令集。

## 1. 当前实际存在什么 `[RTL事实]`

| 能力 | 当前状态 |
|---|---|
| 线性 byte PC 与半开程序范围 | 已实现；control-store source 单 request outstanding |
| 默认四 word fetch | 已实现；满 bundle 接受后通常 `PC + 16` |
| 1–4 word record framing | 已实现；每个 stream word 仍是 `+4` |
| profile-v0 EXEC semantic decode | 已实现 |
| decoded MEMORY execution | 已实现参考入口 |
| encoded MEMORY semantic decode | 未实现；program path 当前有序拒绝 |
| CONTROL | 只实现 canonical final `END` |
| sequencer address-state RF / adder | 已实现独立 decoded reference；尚未接 program path |
| loop / branch / redirect | 未实现 |
| call/return、SP/RA | 未实现 |
| scalar LOAD/STORE | 未实现 |
| reduction/count 写 scalar state | 未实现；当前只向外返回 result |
| interrupt/trap/precise restart | 未实现；错误通过 completion/sticky status 报告 |

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
当前操作为：

| 类别 | 已实现操作 | 用途 |
|---|---|---|
| 常量/复制 | `SMOVI` | 构造地址、stride 和 loop count |
| 整数地址 | `SADD`、`SADDI` | base/offset/stride；负 immediate 已覆盖 SUBI |

加法按 state width 模回绕，不产生 flags 或 overflow exception。decoded command 在
handshake 时写状态，每项 accepted command 恰好产生一项可背压 completion；非法 op、
context 或实际使用的 register 产生零副作用错误 completion。一个组合 base query
供未来 MEMORY decoder 在 action admission 时快照值。

当前没有 `SET_GMASK`、`LOOP/LOOP_END`、任意条件 branch、CALL/RET、scalar memory、
乘除法、CSR、特权态和中断。`END` 仍由既有 CONTROL path 实现，不在 state engine 内。
`VLOAD/VSTORE [sbase+simm]` 仍是下一步 MEMORY semantic decode 的目标，不是已实现
encoding。

## 4. 建议落地顺序 `[候选]`

1. MEMORY semantic decoder：定义 record 的 address-state base register、signed offset、
   row、span、address context 与 group mask；admission 时读取 base 并形成现有 decoded
   descriptor。
2. 把已实现的 `SMOVI/SADD(I)` decoded state command 接入 CONTROL/class routing，并让
   dependency metadata 保证 state RAW；memory engine 仍只接收已快照的 resolved eaddr。
3. 根据实际多 group 程序加入 per-context `SET_GMASK`，同样在 action admission 时快照。
4. 串行化 loop redirect：遇到 control-flow record 停止年轻 action，清除已预取的年轻
   word/framer state，再从目标 PC 重取。
5. 有负载证据后增加 reduction/count → scalar RF 与条件 branch。

现有 `stream_abort` 表示 transport failure，不能直接复用为正常 redirect。首版 loop
不需要预测：在 redirect 已解析和更老 action 完成前停止 fetch/issue，就无需回滚已经
送入 EXEC/MEMORY engine 的事务。
