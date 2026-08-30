# 当前控制与内存集成状态

本页只回答“哪些模块现在确实连在一起”。它把严格 uword 程序闭环、decoded
MEMORY 参考闭环、独立并发候选和仿真模型分开，避免把“模块已有”误读为“程序路径
已经使用它”。

![当前控制与内存集成状态](current-integration.svg)

Graphviz 源文件为 [`current-integration.dot`](current-integration.dot)。

## 1. 三条已经能运行的参考路径 `[RTL事实]`

前两条入口不同并复用同一 vector memory engine；第三条是尚未绑定程序前端的
dependency-route 执行闭环：

1. uword 程序路径：behavioral control store → linear byte-PC source →
   multi-record framer → **slot 0** holding/action adapter → strict controller。
   profile-v0 EXEC、sequencer-local `SMOVI/SADD/SADDI`、两词
   `VLOAD/VSTORE` 与最终 `CONTROL.END` 都能执行和有序退休。现有回归已经运行
   `state address → VLOAD → EXEC → VSTORE → END`，并检查真实 dmem 地址、数据与
   byte strobe。
2. decoded MEMORY 路径：外部直接提供完整 MEMORY descriptor，经 strict controller
   进入 vector memory engine，再通过 VRF arbiter 和 group state endpoint 完成
   LOAD/STORE。该路径已和 EXEC、END 做过端到端参考回归。
3. route-wave 路径：外部提供带 participant frontier/token 的 `DEP_OUT/DEP_IN`
   fragments，rendezvous table 在执行 admission 之前配对；frontier 均到达后，controller
   保持稳定的 source/destination union-resource 请求。grant 与真实 register-route engine
   command 同拍接受后，engine 从各自 mask 捕获 VRF source/index，经显式
   `ROUTE_RESULT` 寄存级再写回 destination mask，最后为两个 participant 保存独立
   completion。它是可执行 RTL 闭环，但尚未连接 PC、framer、queue 或 ordered window。

因此，“encoded 程序能用地址状态驱动 LOAD/STORE”与“外部 decoded descriptor 入口
仍可独立使用”都成立。encoded MEMORY 不是独立的新内存实现：semantic decoder 在
action admission 读取 state base，现有 memory engine 接收快照后的 descriptor。

`vsp_uword_multi_framer` 最多可同时暴露三条 record，`vsp_ordered_action_window`
也已有四项窗口、两个 EXEC view 和一个 side view；结构 predecoder 会把非零 route
mode 标成 `barrier-before`，并区分需要配对的 `DEP_IN/DEP_OUT`。window 能让这类 entry
等到所有更老项真正退休后才暴露。`vsp_route_rendezvous_table` 既可独立验证，也已由
`vsp_route_wave_controller` 使用：收集两个 partial role、比较 participant retirement
token，并对 illegal/conflict/flush 产生可背压 terminal。strict wrapper 仍只消费 slot 0；
predecoder、window、route-wave fragment 入口、late-decode holding stage 与 class engines
尚未组成并发 program path。尤其不能把 strict controller 放在 rendezvous 前面：它的
global-single-active ownership 会让先到 half 等待 completion，并阻止 peer 到达。

route engine 中的 `ROUTE_RESULT` 是 timing/ownership boundary：它切断完整 gather 组合
结果到首次 VRF write request 的路径。capture 和 commit 仍串行，一个 engine 仍只接纳
一个 active parent；当前没有宣称固定总延迟或 `II=1`。

rendezvous table 可以在一个 parent RUN 时继续收集别的 key，但 controller 仍一次只让一个
parent 经过 LAUNCH/RUN/FANOUT。table terminal 在背压时保持原 payload；匹配的 flush/
epoch advance 由 controller 在 `parent_fire` 前转成双 CANCEL，RUN 中已经接受的 VRF
事务则继续完成，不做回滚。ready terminal 的选择是 RR 而非 age-order；当前独立入口
要求这些 waves 可重排。未来 program binding 若要求 age order，必须在 terminal 被捕获前
限制 frontier/admission，或采用 age-aware terminal 仲裁；仅在 LAUNCH 后压低 resource
ready 不会让表重选较老 wave。这个入口因此既不是完整 program path，也不是 `II=1`
route pipeline。

`vsp_ordered_ifetch_model` 仍是尚未绑定到 strict program path 的独立 I-side bundle
endpoint，需要 launch address metadata/fault adapter。与它不同，
`vsp_sequencer_state_engine`、CONTROL/MEMORY semantic decoder 和 action adapter 已经
接入 strict wrapper；它们仍不在独立的并发 action-window reference 中。

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

semantic MEMORY record 在 admission 后形成一条 decoded vector-memory parent：

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

与它独立的 `sim/models/vsp_ordered_ifetch_model.sv` 对 read-only program bundle
提供同类 executable contract：byte PC、1–4 word packed response、address-space/fault、
固定延迟和 FIFO ordered outstanding。当前 program source 仍是单 outstanding，并直接
连接 behavioral control store；I-side 模型尚未接入 wrapper。两套模型不共享 ready、
response queue 或 outstanding domain。

I-cache/D-cache 的预期边界、共享物理端口的位置和一致性待办见
[I-side / D-side 内存模型边界](memory-hierarchy.md)。fetch bundle 的 16-byte 上限不是
I-cache line，4-byte dmem beat 也不是 D-cache line。

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

## 6. Sequencer 地址/控制侧完成度 `[RTL事实 + 候选]`

`vsp_sequencer_state_engine` 默认每 execution
context 32 个 32-bit state register，register 0 恒零；支持 `SMOVI`、`SADD`、
`SADDI`，按模 \(2^{32}\) 回绕；一项 registered completion 可背压；组合 base query
供 MEMORY admission 快照。CONTROL decoder 输出的合法 state action 在 strict wrapper
内被送到该 engine；其 completion 与 cluster completion 在同一有序出口汇合。MEMORY
decoder 只在完整合法记录可见时查询 base，memory action 被接纳后由现有 engine 保存
descriptor，后续 state 写不能改变在途访问。state engine 本身仍不持有 PC，也不访问
dmem。

当前没有 `SET_GMASK`、loop/branch/redirect、
scalar load/store、reduction/count 写 state、CALL/RET、CSR、特权态或中断入口。
当前 state/MEMORY 绑定只属于 global single-active、slot-0 strict closure；把它移入
多 record admission/window 时，还必须把 state RAW/WAW、resolved base 与 MEMORY/VRF
依赖写入 window metadata。之后再按负载证据增加 group-mask state 和计数 loop；
redirect 必须单独扩展 program source 并清理 framer/window 中的年轻记录。具体边界见
[Sequencer 标量/地址状态](../design/sequencer-state.md)。
