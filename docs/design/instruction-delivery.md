# 队列、微指令与译码器候选设计

> 状态：uword bundle framing/class predecoder、单 record assembler、三 record framer、
> 顺序 byte-PC program source、浅层 ordered action window、EXEC cluster integration、
> late-decode holding stage、EXEC-uword profile-v0 canonical expander，以及 strict ordered
> class router 已有参考 RTL。严格 PC→EXEC/END program closure 已接通；多 record
> framer 与 action window 的三项并发路径仍是独立吞吐/依赖边界，尚未替换 strict
> single-active action-stream 路径。MEMORY semantic decode、完整 admission metadata 与
> 并发 queue-head integration 仍未完成。
> 本文用于比较实现路径，不拥有
> 最终外部指令格式或控制器组织的决策权。

## 1. 当前真实状态 `[RTL事实]`

现在已有 full-decoded EXEC 集群闭环、译码后的状态边界，以及一套尚未接入 queue
控制链的 compact EXEC 解析逻辑：

- `simd_datapath` 直接接收 `op`、寄存器地址、立即数、mask、route、reduction
  和写回选择等展开控制；
- testbench 充当外部 sequencer，直接驱动这些信号；
- `simd_uop_legal` 检查展开控制的 mode、写回、route 和 reduction 组合；
- `simd_issue_dispatch` 只处理 `valid/context/group_mask/group_ready` 并输出每个
  group 选择哪个 issue slot，它不保存或解释完整操作 bundle；
- `simd_issue_queue` 为每个 context 保存独立有序 FIFO，当前有一个 admission
  入口并并行暴露所有 context head；它把 `uword/resolved/sched_meta/tag` 当作
  不透明 entry 保存，不解释任何指令位域；
- `simd_cluster_issue_frontend` 默认以 `4 group / 2 queue / 2 slot`
  集成 queue、round-robin live-head 选择、opaque locked shadow、显式
  reject credit、terminal pop 和原子 group dispatch；当前 queue identity 在参考
  profile 中同时作为 ownership context；
- `simd_group_wrapper` 已直接接受 canonical decoded EXEC，并以独立 state-write
  子事务提供 VRF/ARF/MRF 数据注入、tagged child completion 和可背压结果；
  这没有增加 encoded-uword parser。
- `simd_cluster_exec` 已按 `group_issue_slot` 选择完整 canonical bundle，
  通过每 group 单项 ingress 原子 multicast 到四个 wrapper，并接入 tracker、reject
  buffer 和 result collector；当前 admission 仍由可信上游直接提供展开控制；
- `simd_issue_decode_stage` 是每 issue slot 一项、无 fall-through 的 late-decode
  holding stage：它锁存 raw/resolved/cached provenance，以及 hook 产生的
  class/response/group-mask/exact-resource/canonical-payload/legal/error；背压时所有
  字段稳定。当前 hook 是参考 adapter 接口，不是 encoded parser。
- `vsp_exec_uword_expander` 组合解析内部实验 profile v0 的 32-bit base 与可选
  32-bit scalar-immediate extension，覆盖当前 EXEC function 与 SIMD4-local route；它复用
  `simd_uop_legal`，对非法项输出确定 cause 并把所有 canonical 副作用归零。具体
  位域见 [EXEC uword profile v0](exec-uword-profile-v0.md)。
- `vsp_uword_predecoder` 组合扫描一个默认 4-word 的连续 uword bundle，划分完整
  record、预判 `EXEC/MEMORY/CONTROL` class，并把未完成尾 record 作为续接提示输出；
  它不保存跨 bundle 状态，不检查 class 内语义，也不绑定 action envelope。
- `vsp_uword_multi_framer` 在同一 framing 规则上增加跨 bundle 状态和最多三个
  packed-prefix record 输出。默认 `BUNDLE_WORDS=4`、`ADMIT_SLOTS=3` 是彼此独立的
  参数：前者表示一次交付四个 32-bit stream word，不表示一定取得四条 record；后者
  对应当前候选吞吐的两个 EXEC admission 加一个 MEMORY/CONTROL side admission。
  framer 按 record 边界识别 `CONTROL.END`、阻止更年轻 fetch/record，并继续保留 EOF
  truncated 与 discontinuity 诊断。
- `vsp_uword_control_store`、`vsp_uword_program_source` 与
  `vsp_uword_bundle_assembler` 已组成一个独立 program frontend reference：从非零
  byte PC 启动，按至多四个连续 32-bit word 请求，保存跨 bundle tail，并把完整或
  EOF 截断 record 串行为 stall-stable ready/valid 输出。这个 frontend 不解释
  `CONTROL.END`，也未接 action controller。
- `vsp_ordered_action_window` 是独立的四项浅窗口 reference，默认每拍接纳三项、观察
  两个 EXEC 候选和一个 non-EXEC side 候选；后者覆盖 MEMORY、CONTROL 与有序
  reject。它按 group child 与共享
  dependency metadata 阻止相关操作，允许 split action 的无冲突 group 独立推进、
  completion 乱序到达，并以最多三项 packed prefix 按序 retirement。四项深度用于
  短暂 record 对齐、背压吸收和依赖观察，不是 branch-prediction 深队列；当前也没有 branch predictor、
  redirect epoch 或投机恢复。side 候选只是 class-router 结构端口，不是已实现的
  scalar ALU 发射槽。
- `vsp_decoded_action_controller` 已按 `EXEC/MEMORY/CONTROL` 分流一条统一 action
  流，并用统一 completion 保持严格程序顺序；`vsp_cluster_controller_wrapper`
  已把 profile-v0 EXEC expander、decoded MEMORY 和最小 `CONTROL.END` 接到这条路径。
  该路径全局只保留一个 active action，尚未复用 per-context queue/head scheduler。
- `vsp_uword_action_adapter` 与 `vsp_uword_cluster_program_wrapper` 已把 behavioral
  control store、byte-PC source、multi-record framer、launch envelope、profile-v0 EXEC
  和 final `CONTROL.END` 接到上述 strict controller。当前 closure 只消费 framer 的
  slot 0，并在 controller 完成前保持一项 action；MEMORY record 只产生 ordered decode
  reject，不会被零填充为 memory command。因此它证明 PC→EXEC/END 的严格保序闭环，
  不证明三项 admission 或 action window 已接入执行端。

因此现在可以准确地说：full-decoded reference profile 已能执行和退休 EXEC，
decode holding 协议、EXEC canonical expansion、跨 class 严格顺序、multi-record
framing，以及一个独立的浅层依赖窗口都已有验证。尚缺的是 MEMORY/CONTROL semantic
decode、真实 shared-resource metadata，以及把三 record admission、ordered window、
late decode 和各 class engine 组成同一条并发控制链。严格 action-stream 接法只证明
PC→record→EXEC/END 的保序合同能够闭环，不等于三发射 sequencer 已完成；当前
MEMORY 可执行路径仍由 decoded reference 入口验证，而不是从 uword stream 驱动。

### 1.1 Uword bundle framing 与 class predecode `[RTL事实 + 内部实验]`

当前 `vsp_uword_predecoder` 的默认输入是一组按 stream 顺序排列的
`4 × 32-bit` word，word 0 最老，有效部分必须从 word 0 连续开始。它使用
`vsp_uword_pkg` 中的内部实验 framing：

| header `[31:28]` | 初步 class | record word 数 |
|---|---|---:|
| `0x1..0xa` | `EXEC` | 由 EXEC format 的 extension 规则决定 1 或 2 |
| `0xb` | `MEMORY` | `1 + header[27:26]`，即 1 至 4 |
| `0xc` | `CONTROL` | `1 + header[27:26]`，即 1 至 4 |
| `0xd` | `EXEC/ROUTE` | 固定 1 |
| `0x0, 0xe..0xf` | undefined | 固定 1，并留给后级形成有序错误记录 |

这里的 `4 × 32-bit` 是 fetch/bundle 的 stream-word 数，不是每拍四条 instruction 或
四条 record。四个 word 可能组成四条单字 EXEC，也可能只组成一条四字 MEMORY，或
由一个跨 bundle tail、若干完整 record 和下一个 tail 共同占用。因而 fetch 宽度应
覆盖目标发射需求，但不能直接等同于发射槽数量。

EXEC 是否拥有 extension 由 `vsp_exec_uword_extension_required()` 唯一判定，canonical
expander 复用同一函数。已经识别的 EXEC format 即使 sub-op、reserved bit 或地址
随后被判非法，仍按结构位消费 extension。MEMORY/CONTROL body 与 EXEC extension
都是 opaque 32-bit word；它们的高 nibble 即使看起来像另一个 header，也不会被再次
分类。

`0xb/0xc + body_count` 只是当前内部 stream framing experiment，不定义
MEMORY/CONTROL body 字段，也不承诺最终 ISA。它以两个 header bit 换取 class decoder
尚未完成时的通用 1..4-word framing；相应代价是这些位损坏可能使扫描多消费后续
word。若后续可靠性或 code-density 证据不接受该权衡，可以版本化改成
`(major, subformat)` 固定长度表；不能让两套长度规则在同一 profile 中并存。

一个 bundle 可同时输出多条归一化 record；未完成的最后一条不输出为完整 record，
只报告 start/required/present 与已有 word。当前模块是无握手的组合原语：它不知道
stream end、epoch、PC 或地址，也不把 tail 判成 truncated error。后续 bundle
assembler 边界负责 ready/valid、跨 bundle 补齐、结束/discontinuity 处理和稳定输出；
当前 `vsp_uword_bundle_assembler` 已实现其中的线性 stream reference，尚无 epoch 或
redirect/flush。

单输出 `vsp_uword_bundle_assembler` 仍服务既有 program frontend；新增
`vsp_uword_multi_framer` 则保存同样的跨 bundle tail，并把最多 `ADMIT_SLOTS=3` 条完整
record 作为 packed prefix 暴露。逐 slot `ready` 只能接受从最老 slot 开始的连续前缀，
`record_accept` 是非前缀 ready 输入下的权威结果；消费旧前缀和接收下一 bundle 可以
同拍发生。它会扫描全部已缓存 record 寻找 canonical END，所以即使 END 位于当前三个
输出槽之后也能先拉高 sticky `stop_fetch`；opaque body 中相同的 32-bit 值不会被误认。
`stream_abort` 为 fetch fault/外部取消清掉 incomplete tail、EOF、连续 PC 和 discard
状态，但不伪造成功 EOF、不清 sticky protocol error，也不撤销已经识别的 END halt。

这些 record 仍缺实际 workload 派生的依赖/资源 metadata 和 class-specific canonical
payload。默认三项 admission 是“两个 EXEC 候选 + 一个 MEMORY/CONTROL side 候选”的
吞吐目标，不是三条任意 class 都能送往任意 engine 的对称超标量端口，也不表示 side
路径已有 scalar ALU。

### 1.2 线性 program frontend `[RTL事实 + 里程碑基线]`

当前新增的 reference 路径是：

```text
internal uword source file
        -> tools/vsp_uword_asm.py
        -> one-word-per-line hex image
        -> behavioral control store
        -> byte-PC program source
        -> stateful bundle assembler
        -> one normalized record ready/valid
```

program source 接受半开区间 `[start_pc, end_pc)`。两端都必须四字节对齐；空区间
直接产生 delivery completion，不访问 control store。非空区间每次请求
`min(BUNDLE_WORDS, (end_pc-current_pc)/4)` 个 word。每个 base、extension 和 opaque
body 都占一个 32-bit stream word，因此相邻 word 地址恒为 `+4`；bundle 被下游接受
后，`current_pc` 增加 `4 * bundle_word_count`。PC 宽度、control-store 基址和容量均
参数化，范围检查比较完整 PC，越界返回 fault，不能用低地址位静默 alias。

control store 是未复位的数据数组和单响应行为模型。它的逻辑 request/response 边界
与 data-memory `dmem_*` 分开；未来可在该边界外替换物理 SRAM、translation 或
I-cache-like 供应结构。program source 当前只允许一个 outstanding request，并把完整
response 保存成 bundle 等待下游；所以 4-word 只是单次 response/fetch bundle 宽度，
不证明能够持续每拍供应 4 words 或 3 actions。真实 I-side SRAM/cache pipeline、bank/
端口、miss/refill 和吞吐仲裁都尚未实现。

另有独立 `vsp_ordered_ifetch_model` 为这个 I-side 候选合同验证 address metadata、
fault、固定延迟和 FIFO ordered response；它尚未连接 program source，且不是 cache。
I/D 分层预期见[内存模型边界](../architecture/memory-hierarchy.md)。

assembler 最多保存一条三 word 未完成 tail，把下一 bundle 的前缀作为 opaque
extension/body 补齐，而不重新按 header 分类。完整 record 依序串行输出；最终 tail
不足时输出一次 `record_truncated`，其中 structural count 与 present count 分开。
输出背压期间 PC、class、count 与全部 word 保持稳定。`end_pc` 只是 stream 边界；
即便某个 word 当前编码为 `CONTROL_END`，assembler 也只把它作为 CONTROL record
交付，停止/退休语义留给后级 decoder/controller。非连续、未对齐或非法 count 的
bundle 不参与组包；assembler 置 sticky protocol error，并丢弃到该 source stream 的
最终 bundle，避免错误地址的数据被拼成伪 record。

`tools/vsp_uword_asm.py` 是验证这条内部路径的工程辅助工具，不是外部 ISA
assembler。它目前能产生 profile-v0 ALU RR/RI、opaque MEMORY/CONTROL、
`CONTROL_END` 和 raw word，并可输出 byte-PC listing 与 symbol JSON。ALU builder
拒绝它能静态识别的 profile-v0 mode/reduction/unused-field 非法组合；故意构造非法
record 时使用 raw word。外部 instruction 宽度和软件 ABI 仍未选择。

### 1.3 浅层 ordered action window `[RTL事实 + 尚未接入并发闭环]`

`vsp_ordered_action_window` 默认 `WINDOW_DEPTH=4`、`ADMIT_LANES=3`、
`EXEC_SLOTS=2`、`SIDE_SLOTS=1`。三条 admission lane 按输入年龄压紧进入窗口并分配
sequence ID；两个 EXEC view 与一个 side view 分别寻找最老的可发射候选。side view
覆盖全部 non-EXEC class：正常的 MEMORY/CONTROL 以及需要送往有序错误路径的
undefined class。它是未来 memory/controller/scalar engine 的统一结构边界，不证明
标量运算单元已经实现。

窗口当前采用两层保守依赖：重叠 group 的未完成 child 阻止年轻 action 使用同一
group；`dep_read/dep_write` 位描述跨 group 的共享资源 RAW/WAR/WAW 关系。`split_ok`
允许一条 action 只向当前 ready 且未被更老 action 占用的 group 子集推进；非 split
action 仍须完整目标 mask 同拍接受。child completion 可按 sequence 和 group mask
乱序回到窗口，但对外 retirement 始终是最多三项的连续 sequence 前缀。
serializing/END 在到达年龄头部前不发射，END admission 会拒绝同批更年轻 record
并保持 fetch halt。
重复、未知 sequence、未发射 group 或形状错误的 completion 仍会被 ready/valid
边界消费，以免错误报告反向堵死 engine；它们不修改完成状态，并置 sticky protocol error。

四项深度目前只给 4-word fetch、三项 admission、engine backpressure 和短距离依赖
提供一个小的解耦空间。它没有预测分支产生的未决路径，也没有 rename、speculative
issue、epoch 或错误路径回滚，因此不能按 CPU branch-prediction instruction queue
解释。深度和吞吐参数仍需用代表性 trace 决定。

### 1.4 Strict executable program closure `[RTL事实 + 保守基线]`

`vsp_uword_cluster_program_wrapper` 当前闭合以下路径：

```text
behavioral control store
    -> single-outstanding byte-PC program source
    -> 4-word multi-record framer
    -> slot-0 action holding / vsp_uword_action_adapter
    -> strict vsp_cluster_controller_wrapper
    -> EXEC group completion/result or ordered error
    -> final CONTROL.END retirement
```

launch 捕获 `context/group_mask/tag_seed`，后续每个被 controller 接受的 record 递增 tag。
adapter 检查 EXEC base/extension 结构、undefined/truncated record，以及 canonical
`CONTROL.END`。END 只有位于 `[start_pc,end_pc)` 的最终一个 word 才合法；early END
先停止向 framer 输入更年轻 record，再以 ordered control reject 失败并排空 source。
EOF 没有 END、截断 EXEC、未知 CONTROL 和 fetch fault 都形成可观察的 program failure；
fetch fault 通过 `stream_abort` 清除 incomplete tail，允许下一次 launch 重新开始。opaque
MEMORY body 中出现 `0xC0000000` 不会被当作 END。

这个 wrapper 刻意只令 `record_ready[0]` 有效，并在一项 action holding 与全局
single-active controller 后推进。尽管 framer 参数仍为 `ADMIT_SLOTS=3`，closure 的
实测吞吐上限不是三 action/cycle；其目的只是证明 record boundary、envelope、ordered
reject、EXEC writeback/result 和 END 生命周期可以从 PC 串到退休。它也没有接
`vsp_ordered_action_window`，没有 MEMORY uword semantic decoder、branch/loop、真实
I-cache 或持续四 word/cycle 的供给结构。

## 2. 区分三种表示 `[分析模型]`

```text
encoded instruction/uword
    紧凑、适合控制存储和深 FIFO
             │ decode / canonicalize
             ▼
decoded uop bundle
    展开的执行控制，适合 issue、legality 和 datapath
             │ dispatch by slot/group mask
             ▼
SIMD4 group control signals
```

外部软件指令、sequencer 内部 uword 和最终 decoded bundle 不必具有相同宽度或
编码。当前 `op_i`/`exec_op_i` 上的 6-bit `simd_op_e` 只是
canonical EXEC bundle 中的 function，不是完整 opcode。

## 3. 三种 queue 方案 `[候选比较]`

| 方案 | 优点 | 代价 |
|---|---|---|
| full-decoded FIFO | 发射端简单、被阻塞时控制稳定 | entry 很宽，FIFO 面积和切换功耗大；编码变化会扩散到所有 queue |
| encoded FIFO + late decode | entry 紧凑、控制存储自然 | 调度前看不到完整资源需求；多 head 可能复制译码或形成时序瓶颈 |
| compact FIFO + cached predecode + head expansion | 存储较小，同时能提前仲裁资源 | 两段译码之间必须保持语义一致，并定义 canonical bundle |

当前 `simd_issue_queue`、frontend 与 decode holding stage 提供第三种 hybrid 可复用
的存储、发射和稳定输出协议边界，但不规定不透明字段的 bit layout。profile v0
已经给出一个可测的 EXEC bit layout 与 standalone bundle framing/class predecode；
方案比较仍需要 admission legality/cached metadata、实际 integration、queue 面积和
代表性 trace 比较；前两种方案没有因此被架构性排除。“无解码队列”不是独立方案：保存
encoded uword 只是把译码推迟到队头之后。

## 4. 当前参考数据流 `[候选]`

```text
sequencer / microcode store
        │ encoded uword + resolved sideband
        ▼
admission format parse + predecode
        │ queue_entry + derived sched_meta
        ▼
per-context compact FIFO
        │ expose one ordered head per context
        ▼
round-robin head scheduler
        │ select at most ISSUE_SLOTS heads
        ▼
ISSUE_SLOTS copies of canonical expander
        │ canonical decoded uop
        ▼
exact shared-resource arbitration
        │
        ├─ EXEC ── atomic group-mask dispatcher ── SIMD4 wrappers
        ├─ MEMORY ────── DMA/local-memory engine
        └─ CONTROL ── barrier/admin state machine
```

深 FIFO 保存紧凑 uword；展开表示只出现在所选队头的组合 expander 输出，或可选的
浅 holding register 中。
canonical expander 数量随 `ISSUE_SLOTS` 增长，而不是随 `CONTEXT_COUNT` 或
`GROUP_COUNT` 增长。对默认四组双发射配置，基线是两个 expander。

当前 frontend 已有 live-head fast path 和每 slot 的 opaque locked shadow。未受理的
live head 在时钟沿被复制到 shadow，FIFO 暂不 pop；只有原子 group accept，
或已获得 `reject_ready` credit 的错误 reject，才同时清 slot 并 terminal
pop。这保证 downstream backpressure 下 payload 稳定，FIFO head 仍是唯一
逻辑 owner。但 shadow 保存的是 opaque payload/resolved/sched_meta，不是已由
本仓库 expander 生成的 canonical decoded bundle。

第一版 `simd_cluster_exec` 已用 full-decoded queue profile 闭合
`group_issue_slot` bundle mux、group ingress、wrapper、tracker 和 result/reject
返回。外层 `vsp_cluster_controller_wrapper` 已在单 action 入口把 canonical expander
和 class router 接到该边界；尚缺的是把同一语义移动到选中队头与 cluster 之间，
并保留 terminal feedback。当前 cluster execution integration 自身仍不负责 encoded
format。

## 5. Queue entry 应保存什么 `[RTL边界 + 候选语义]`

当前 `simd_issue_queue` 实际保存四项参数化字段：`tag + uword + resolved +
sched_meta`。context 由所属逻辑 FIFO 隐含；默认宽度只是 elaboration 配置，不是
32-bit ISA 或 metadata layout。逻辑上后三项分别对应：

紧凑 uword 保存：

- format/major class 与 function；
- VRF/ARF/MRF 源和目的地址；
- element mode、mask 选择与写回类别；
- immediate/shift 的短编码或 extension 引用；
- route/reduce 子功能或 route preset；
- barrier/memory 等控制类操作。

由 sequencer 解析后附带的动态 sideband 保存：

- `tag`；per-context FIFO 的 `context_id` 通常由 FIFO 编号隐含，只有共享物理
  queue 才需要逐 entry 保存；
- `target_group_mask`；
- 循环迭代产生的有效 mask；
- 已解析的 scalar 参数、extension word 或控制存储索引；
- 需要时的 memory descriptor 引用、短地址操作数和依赖；bulk data 与完整 mover
  状态不进入 instruction queue。

由 admission predecode 从前两部分唯一派生并缓存的 `sched_meta` 保存：

- `dispatch_class` 与 `response_kind`；
- 当前调度真正消费的粗粒度 group-state/write-port 类别；若以后不同 RF 文件或
  物理 bank 参与队头选择，再加入相应 file mask/bank hint；
- 保守的 shared-resource may-need mask 与 serialize/ordering class；
- 静态合法性和错误原因。

`sched_meta` 不是软件或 sequencer 可以任意填写的第二份资源声明；它必须由硬件
predecoder 生成，并在 canonical expansion 时复核关键约束。
当前四个字段使用独立参数宽度只是为了先验证 FIFO。接入 profile/predecoder 时，应由
唯一的 `uword_t/resolved_t/sched_meta_t`（或等价 profile type）的 `$bits` 驱动这些
宽度，避免 controller top 人工重复 `32/16/16`；这仍不要求确定最终 ISA。

`group_mask` 可能比一个普通指令字更宽，也可能来自 owner/context 状态，因此没有
必要强迫它永久占据基础 uword。相邻 boundary data 和 RF 读数据更不
应该进入 instruction FIFO；它们属于 operand/staging 通道。

## 6. Predecode 与调度 `[候选]`

head scheduler 在选择 context 前需要少量信息，但不需要看到完整 datapath bundle。
admission record 向它暴露两类字段：`target_group_mask` 来自受信的 resolved
sideband，predecoder 只验证并使用它；其余 scheduling metadata 由轻量解析唯一
派生：

```text
dispatch_class   = EXEC / MEMORY / CONTROL
response_kind    = NONE / STATUS / GROUP_DATA / MEMORY_DATA
group_state/write_port coarse class
resource_may_need_mask
serialize/ordering class
static_error + cause
```

第二阶段 canonical expander 在某个 head 被 issue slot 选中后才产生：

```text
simd_op + element mode
exact VRF/ARF/MRF row addresses and writeback enables
expanded immediate and default fields
route/reduce/mask/export controls
class-specific EXEC / MEMORY / CONTROL request
final legality + exact resource set
```

这就是“半解码”的准确含义：不是只译一半指令，而是两段译码，中间只缓存调度
提前需要的结果。一个字段是否应该 predecode 的判断标准是：scheduler 在选择 head
之前是否立即消费它。当前还没有 bank/hazard scoreboard，因此完整 RF file mask、
row 地址和 latency class 都留在晚译码；若以后不同 RF 文件并发或物理 bank 冲突
参与 head 选择，可只提前派生相应 file mask、bank index 或 address descriptor，
而不是把整份 decoded bundle 塞回深 FIFO。

`response_kind` 是返回形态，不应与目的执行引擎混成一个 class。例如 reduction
仍是 `EXEC`，只是产生 `GROUP_DATA`；barrier/admin 通常走 `CONTROL`，不要求
非零 group mask。完成精确资源译码后必须按 `dispatch_class` 分流，不能把所有
canonical uop 都交给 group-mask dispatcher，否则合法的 controller-local 命令会被
空 mask 规则误判。

其中 capability、source/destination 和资源需求必须由 opcode、modifier 与显式
writeback choice 共同派生，不能让软件另带一份可能与 function 矛盾的资源声明；
target mask 等动态字段来自受信的 resolved sideband，并参与 owner/format 校验。
例如 WADD/WSUB 固定读取
`VRF-A+B+ARF`，MAC 读 ARF 而 MUL 不读，SELECT 额外读取 select MRF，MRF logic
复用两个 MRF 口，slide 需要 boundary 资源；compare、MUL、compact 和 MRF logic
还允许不同形式的双目的写回。cached resource 可以保守多报但不能漏报；canonical
expander 在选中后重新生成 exact resource，并检查 `exact ⊆ resource_may_need` 及
class/response 一致性。不一致视为内部译码错误，零执行副作用。

静态 format error 也随 entry 保序保存。只有该 entry 到达本 context 队头且 error
completion sink ready 时才能 reject/pop，不能在 enqueue 时旁路退休而越过更老
指令。

所有路径共享的正确性条件是 entry 所有权不能丢失或复制：它要么仍在 FIFO，要么
已经原子转移到被 scoreboard 跟踪的 reserved issue stage；只有目标引擎 fire，
或者错误 completion 已经获得存储空间，才算从控制器退休。当前
`simd_issue_dispatch` 已有每 slot 的 `issue_reject_ready_i`；空 mask/owner
error 只在该 credit 有效时产生 `ready + reject`。frontend 把这个
terminal reject 与 queue pop 绑定，错误返回无空间时保持 slot 和队头。

`simd_issue_queue.head_ready_i[queue]` 的具体含义就是最终 dequeue/ownership
release，不是“队头已被 live-select”或 shadow slot 已复制。已实现的
locked-shadow 在 slot claim 时保持它为零，并通过 `queue_claimed`
防止同一队首被两个 slot 重复领取；只在 EXEC accept 或有
credit 的 reject 时同时清 slot 并拉高该 queue 的 `head_ready_i`。full queue
会据此允许同拍 pop+push，所以 speculative ready 会直接造成过早释放，
而不仅是性能差异。

同一 context 首版每周期只能提供一个 head，所以不会从同一 FIFO 同时取两条不同
指令。不同 context 的 head 可以被多个 issue slot 同周期选中。

## 7. Decoder 与 canonical expander 的分层 `[候选]`

建议把“译码器”拆成两次解析和两个状态边界，而不是一条只执行一次的线性链：

1. **Admission parse/predecode**：识别格式、检查 reserved/未定义 function 与
   extension/preset 引用，解析少量默认值，派生保守 scheduling metadata；这里只
   判定不依赖动态 owner/ready/data 的错误；
2. **Queue storage**：保存原始 uword、resolved sideband、tag 与 cached metadata，
   静态错误也按 context 顺序等待；
3. **Selected-head canonical expansion**：重新解析被选中的 head，扩展 immediate，
   补齐默认字段，生成 exact RF/resource/class request，并做最终 capability/legality
   检查；owner mismatch、动态资源不足和最终 route/control 错误在此后处理；
4. **Issue hold**：候选终局形态是把 decoded bundle 和
   `context/tag/group_mask` 放入每 slot 的浅 holding register。当前
   frontend 的 opaque shadow 已实现稳定与 claim/pop 契约，但不证明
   canonical expansion 已完成。

`simd_issue_decode_stage` 已实现第 4 项所需的一项 elastic holding：没有组合
fall-through，支持同拍 retire/refill，并在 stall 时保持 raw provenance、class、
resource、canonical payload 与错误字段全部稳定。当前 `hook_*` 由 reference driver
产生；已有 EXEC expander 可在其前方派生 canonical EXEC 字段，class/response/
resource metadata 仍需 predecoder 与 class router 补齐。该模块的
`in_valid && in_ready` 表示 entry 所有权已经转入 holding。若未来仍让 FIFO 持有
entry 直到 engine/error terminal，则必须另加 claim/captured 门控，不能在旧输出退休
时把仍可见的同一 FIFO head 当作 refill 再捕获一次。

### 与通用 CPU decoder 的差异 `[当前边界]`

两者都会把紧凑编码展开成执行控制，但事务环境不同：

| 通用 CPU decoder 常见职责 | 当前 VSP/SIMD decode 边界 |
|---|---|
| 从 PC/IFetch 指令流识别标量 ALU、branch、load/store | 从 sequencer action/uword 识别 `EXEC/MEMORY/CONTROL` class |
| 产生分支、特权、异常、flush/重启元数据 | 产生 group mask、response kind、exact resource、canonical payload 与 ordered error completion 元数据 |
| 产生供后续 in-order 或 rename/issue/commit 结构消费的 uop、分支与异常元数据 | 以 `context+tag`、原子 multicast、engine fire 和 result lifetime 描述事务所有权 |
| 一条 architectural instruction 可展开成一个或多个 uop，再由后续结构选择执行资源 | 一个 issue slot 的 decoded bundle 可原子广播到多个 SIMD4 group；expander 数量随 slot 而不是 group 增长 |
| 非法指令通常形成 trap/精确异常 | 当前非法 action 零执行副作用并保序产生 command completion，不在 SIMD4 内建立异常系统 |

因此这里的 decoder 更接近 sequencer transaction expander，而不是把 SIMD4 变成
一颗自行取指的 CPU。若未来上层加入 architectural IFetch 或精确异常，那是新的
controller 边界，不会自动落入每个 group decoder。

当前 reference frontend 把 opaque slot 直接接到 group dispatcher，并由该
dispatcher 的 accept/reject 触发 queue pop；所以它只适用于入口已经完成最终
EXEC 分类与调度合法性检查的配置。以后接入 selected-head late expander 时，
不能简单把 expander 串在现有 `group_issue_slot` 之后，因为那时 terminal 决策已经
发生。届时需要把边界重排为：

```text
queue / RR / opaque shadow
        -> canonical expander / final legality / class router
        -> selected engine fire or ordered error credit
        -> terminal feedback -> queue pop
```

这是接入 hybrid decoder 的结构工作项，不要求保留当前 reference frontend 的内部
组合方式。

错误 uword 不进入任何执行引擎。它由 queue 消费并产生带原 tag 的 error completion，
与 dispatcher 对空 mask/owner mismatch 的 reject 采用相同退休模型；两者都必须先
获得 completion credit。

合法性保留两道防线：ingress/predecode 检查 format、reserved bits、extension/preset
和静态 capability；canonical expander/transaction wrapper 再检查最终控制。现有
`simd_uop_legal` 只覆盖 op-mode、写回 capability、route 和 narrow-reduce
组合，group 内还分别检查具体 `reduce_op`、route index/slide amount 等控制。
即使上级已经检查，也不删除 group 的统一 illegal side-effect gate。

## 8. Canonical 表示与物理拆分 `[候选]`

“canonical decoded uop”是逻辑语义，不要求把所有字段永久绑成一根超宽总线。
建议物理上拆成：

| 表示 | 去向 | 主要内容 |
|---|---|---|
| `queue_entry` | per-context FIFO | compact uword、tag、resolved sideband |
| `sched_meta` | scheduler/resource arbiter | dispatch/response class、粗粒度 RF 使用、may-need resource、serialize、static error |
| `group_uop` | 被选择的 SIMD4 | op/mode、RF 地址、expanded immediate、mask/writeback、route/reduce |
| `issue_envelope` | dispatcher/wrapper | context、tag、response kind；group mask 在 dispatcher 终止 |

每个 group 通过 `group_issue_slot` 已经知道选择哪个 slot，不需要再接收完整
`target_group_mask`；`shared_resource_mask` 也只到 resource arbiter。transaction
wrapper 消费 `group_uop + issue_envelope`，未来修改 compact encoding 不需要修改
SIMD4。

非 group class 不使用 `group_uop`；它们由各自的 canonical request 表示消费。
`issue_envelope` 中可以保留统一的 context/tag/error/retire 信息，使各引擎仍遵守
相同的 queue-pop 与 completion 规则。

`RF_FILL` 等数据动作与算术操作可以共用 sequencer program/uword 空间，但以
`MEMORY` major class 分流，不加入 `simd_op_e`。queue 只保存 descriptor reference、
目标摘要和依赖，不保存 bulk data。parent/child beat、DMA width、local SRAM、
packetizer 和完成聚合统一归入[数据准备与 DMA 边界](data-movement.md)，不在译码页
继续展开。
MEMORY descriptor 中的 effective address、address-space kind 和 opaque address
context 不是 MMU 或 virtual-address 实现证明；当前只将它们传到
`dmem_req/rsp` 逻辑口。

未使用的 `group_uop` 字段由 expander 规范成零。它仍保留 6-bit `op`，并不是把
每个门级控制都展开成 one-hot。`simd_datapath/simd_exec` 仍负责执行功能选择；
上级 expander 负责的
是格式解析、立即数扩展、默认字段、资源分类和非法组合检查。

## 9. 关于指令字 `[内部实验 + 开放问题]`

当前有一套 32-bit base + optional 32-bit extension 的内部
[EXEC uword profile v0](exec-uword-profile-v0.md)，用于检验 code density 和 decoder
边界；它不是外部 instruction。当前仍没有已定义的 32-bit 或 16-bit 软件指令。
内部信号
`op_i`/`exec_op_i` 携带的 6-bit `simd_op_e` 只是 canonical
`EXEC` 的 function，不是完整 opcode。应分开三层：

1. major dispatch class：`EXEC/MEMORY/CONTROL`；
2. 版本化的内部 compact uword profile；
3. 已展开 canonical EXEC 中的 `simd_op_e` function。

queue 参数的 32-bit payload、16-bit resolved 和 16-bit sched-meta 仍只是 opaque
默认宽度，不会因为 profile v0 出现就自动成为 entry 格式合同。profile v0 已证明
常用本地 ALU action 可放入一个 32-bit base，但以下内容仍需 extension 或 sideband：

- 完整 32-bit scalar immediate；
- 较大的 `target_group_mask`；
- 大规模 mask；跨 lane gather 的索引来自 VRF 中的索引向量，基础字只需保留
  寄存器号，不携带网络控制位；
- memory descriptor 引用或短地址操作数；完整 DMA/二维描述符不要求塞进基础字；
- 多个寄存器域、tag 与 barrier 信息。

较自然的方向是“32-bit 常用基础字 + extension/control state/sideband”，或者
内部采用更宽的 microcode word。选择依据应来自常用内核的 code density、decoder
时序和 queue 面积测量。

## 10. Multicast、tag 与退休 `[RTL 事实 + 暂行集成]`

已实现的 `simd_group_completion_tracker` 默认为
`4 group / 2 alloc slot / 2 context / 4 entry`。一条 queue entry 只有一个
command tag。若 `target_group_mask` 含 `k` 个 group，
dispatcher 原子 fire 后生成 `k` 个内部 group 子事务；每个子返回携带相同的
`context_id + tag` 和各自的 `group_id`。`simd_cluster_exec` 已在 dispatch 原子
accept 的同拍提交 tracker entry：`alloc_valid/ready` 只表示候选和
credit，只有与同拍 group issue fire 对应的 `alloc_commit` 写表。保存：

```text
key = context_id + tag
pending_group_mask = accepted_group_mask
expected_result_mask = accepted_result_mask
```

每个无重复的 group completion 清除一位；多 group 可乱序、同拍到达，
illegal 按 group mask 聚合。pending mask 清零产生一条无数据、可背压的
command completion；多 entry 以 RR 选择，stall 时保持稳定。带 payload
的 reduction/count 仍按 group 形成 result record；expected result mask
独立跟踪，command completion 可先报告，但只在 result collector 发出
全部 retire pulse 后才释放 entry/tag。
dispatch 前的 format/empty-mask/owner error 尚未产生 group 子事务，只生成一个
command-level error completion。

需要区分两种生命周期：barrier/quiesce 等待的是内部 `pending_group_mask`、DMA 和
MEMORY inflight 清零，不必等待外部读取已经缓冲的 response；tag 在所有对应
result/completion record 被 cluster 内部的可靠 buffer 接管前不能复用。接管后的
外部 stall 由该 buffer 承担；若未来改变返回层次或引入更大的内部唯一序号，可重新
定义这一退休边界。
completion 容量核算也不能只按“一条 queue entry 一格”处理：multicast 最坏需要
`popcount(mask)` 个 group result slot，另加可选的 command status。
当前 tracker 满表会对 allocation 背压；live context+tag 也是普通 allocation
dependency，而不是 protocol fault。unknown/wrong/duplicate/mismatch 返回被消费并
置 sticky protocol error。tracker 已与 frontend/wrappers 组成 cluster execution integration，result
collector 在捕获 wrapper response 时产生 retire pulse，并用自己的输出寄存器承接
后续外部背压。
`has_result` 与 allocation mask 不一致时，tracker 依 child 实际回报修正
effective result mask，同时聚合 illegal 并置 sticky；早到的 result retire
也会被对账，不会永久占用 tag。

可替代模型包括每 group subtag、tag generation ID，或引擎内部聚合后只返回一个
command record。决定点不是文档重复次数，而是 response 带宽、tag 生命周期和
barrier 语义的实测复杂度。

## 11. 当前工作建议 `[候选摘要]`

- 控制存储和深 per-queue FIFO：候选上保存紧凑 encoded uword、resolved sideband 与
  硬件派生的 cached `sched_meta`；
- issue slot 前：完整展开成 decoded canonical bundle；
- 当前每个 issue slot：已有 FIFO head 的 opaque locked shadow，以及独立
  `simd_issue_decode_stage` 所验证的 decoded holding 结构；EXEC
  expander 已能把 profile-v0 packet 唯一展开，并已接到 strict action-stream
  controller，但尚未接到这些 queue/head 状态边界；
- 接入 late expander 时：先把当前 frontend 的 terminal/pop 从内部 group dispatch
  解耦，改由 expander 后的目标 engine 或 ordered error sink 回传；
- expander 后：按 `dispatch_class` 分流，group dispatcher 只接收确实需要 group 的
  指令；
- entry ownership：接入时保持一种一致模型。可以在 decode-stage input fire 时把
  所有权转入 holding，同时继续阻止同 context 越过该 entry；也可以让 FIFO 保持
  owner 到目标路径 terminal，但必须用 captured/claim 状态禁止重复捕获同一 head。
  当前 frontend 的 opaque shadow 属于后一种，独立 decode stage 的 ready/valid 端口
  属于前一种，二者尚未直接串接；
- `simd_datapath`：继续只看展开控制，不加入取指或编码解析；
- 当前 RTL：已有 legality、decoded group wrapper、EXEC frontend、completion
  tracker、decode holding stage，以及闭合 queue/dispatch/ingress/wrapper/
  result/reject 的 `simd_cluster_exec`；
- 当前已有 standalone bundle framing/class predecoder、byte-PC program source、跨
  bundle stateful assembler/multi-record framer、strict single-active class
  router、ordered error/completion、最小 `CONTROL.END` 和已接入的 VRF-only memory
  engine；`vsp_uword_cluster_program_wrapper` 已把 program record 经 action adapter 接到
  strict EXEC/END 路径，但只消费 slot 0，MEMORY uword 仍作 ordered reject。仍没有
  multi-record→ordered-window→多 engine 的并发接线、真实 admission resource
  predecode、queue-head integration、动态 owner/resource state、一般化 barrier、
  loop/redirect 或 host completion；当前 control store 只是行为模型；
- action-stream wrapper 的 EXEC 输入是已收齐的 `base + optional extension` packet；
  `extension_required_diag` 不是跨拍 refill handshake。该 wrapper 的 exact-resource
  metadata 在 global non-overlap profile 中为零，不能作为 resource predecode 已完成
  的证据；
- 最终 instruction width 和字段分配继续延期。

本页的 queue/control-store 交付是 controller 内部 uword 路径，不是
architectural IFetch。当前 program source 的 byte PC 只定位内部 uword stream；未来若
需要软件 instruction IFetch，它仍是与 `dmem_req/rsp` 分开的逻辑请求类和流控边界。
当前没有 architectural IFetch、I-cache、MMU 或精确异常重启。
