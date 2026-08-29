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
| scalar RF / scalar ALU | 未实现 |
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

## 3. 最小候选集合 `[候选]`

建议先保留一个参数化的 32-bit scalar/address RF；若软件工具希望使用 32 个逻辑编号，
可以暴露 32 个逻辑寄存器，但不立即赋予 ABI 的 SP/RA/callee-save 角色。第一组操作为：

| 类别 | 候选操作 | 用途 |
|---|---|---|
| 常量/复制 | `SMOVI` | 构造地址、stride 和 loop count |
| 整数地址 | `SADD`、`SADDI` | base/offset/stride；负 immediate 已覆盖 SUBI |
| 发射状态 | `SET_GMASK` | 为后续 action 捕获 group mask |
| 计数控制 | `LOOP`、`LOOP_END` | 串行化的零开销计数循环 |
| 终止 | `END` | 等待强静止并完成 launch |
| 向量访存 | `VLOAD/VSTORE [sbase+simm]` | 形成 descriptor，实际 beat 仍由 vector memory engine 执行 |

第一阶段不加入 flags、任意条件 branch、CALL/RET、scalar memory、乘除法、CSR、特权态
和中断。这些只有在 workload 或系统集成给出接收者后再讨论。

## 4. 建议落地顺序 `[候选]`

1. MEMORY semantic decoder：先允许 record 携带完整 base eaddr、offset、row、span 与
   address context，接通现有 decoded descriptor。
2. scalar/address RF 与 `SMOVI/SADD(I)/SET_GMASK`：action admission 时快照 resolved
   address 和 mask，避免年轻标量更新改变在途 action。
3. MEMORY base-register form：descriptor 改为读取 scalar base，AGU 仍只接收已解析值。
4. 串行化 loop redirect：遇到 control-flow record 停止年轻 action，清除已预取的年轻
   word/framer state，再从目标 PC 重取。
5. 有负载证据后增加 reduction/count → scalar RF 与条件 branch。

现有 `stream_abort` 表示 transport failure，不能直接复用为正常 redirect。首版 loop
不需要预测：在 redirect 已解析和更老 action 完成前停止 fetch/issue，就无需回滚已经
送入 EXEC/MEMORY engine 的事务。
