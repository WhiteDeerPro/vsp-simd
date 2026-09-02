# 数据准备与 DMA 边界

> 状态：VRF-only `vsp_vector_memory_engine`、wrapper/cluster 的独立 VRF
> state-read 路径及 `vsp_cluster_vrf_arbiter` 已有参考 RTL。
> `vsp_cluster_memory_wrapper` 已把 blocking 的 vector memory engine 接到
> EXEC cluster，形成 decoded LOAD→EXEC→STORE 参考闭环。
> 其外的 `vsp_cluster_controller_wrapper` 已增加 strict class router 和跨 class
> 程序顺序：进入该层的 MEMORY descriptor 为 decoded canonical 形态，EXEC 使用
> profile-v0 packet。更外层 uword program wrapper 已接通固定两 word MEMORY semantic
> decoder、sequencer address-state base 快照和 CONTROL state decoder；strict slot-0
> 定向程序已执行 `SMOVI/SADD/SADDI → VLOAD → EXEC → VSTORE → END`。
> `sim/models/vsp_ordered_dmem_model.sv` 已提供
> 可配置 FIFO outstanding 的有序仿真 endpoint，但不代表物理 SRAM 已实现。
> VSP-owned product wrapper 已把同一 D-side 接入外部 LSU、地址路由、共享 MMU、
> D-cache、local SRAM、uncached/device endpoint 和 physical fabric，并直接承接 executable
> uword MEMORY path；generic ordered lower 以下的 SoC target/bus、I-cache、DMA 与全局
> maintenance policy 仍待接线。
> 本文不规定总线宽度、SRAM 组织或 DMA 描述符格式。
> 当前 MEMORY engine 同时支持 unit-stride 与 unsigned-byte indexed addressing；
> `INDEX_U8+LOAD/STORE` 分别形成 gather/scatter。产品路径不再提供跨 group 的
> register-to-register route，见[路由边界](../architecture/routing.md)。

## 1. 控制动作与传输数据分离 `[候选]`

`RF_FILL`、`RF_DRAIN` 可以作为 sequencer program 中的 `MEMORY` class 动作，与
算术 uword 共用有序发射和 tag/completion 规则；但它们的 bulk data 不进入
instruction queue。queue 只需保存 descriptor reference、目标摘要、依赖和少量
已解析参数。

候选数据层级为：

下面是最终可能出现的完整数据准备层级。decoded reference integration 仍可在
`dmem_*` 逻辑边界处终止并使用 local-memory oracle；另一个 product program wrapper 已把
同一逻辑口接到 LSU/MMU、local/cache/uncached-device endpoint 与 physical fabric。
SoC lower target、DMA 及其 ingress/capture 接口仍在后续集成。

```text
SoC memory / producer
        │ DMA burst
        ▼
burst FIFO / width gearbox
        ▼
banked local SRAM or scratchpad
        ▼
vector memory engine + packetizer
        ▼
per-group ingress / capture staging
        ▼
SIMD4 state-write / export endpoint
```

sequencer/controller 发起或许可 program-level memory action；vector memory engine 保存
地址推进、beat 计数和 command/subrequest completion 状态；SIMD4 只接受已经带数据的叶端
state-write beat。这样不会因为加入数据供应而让 SIMD4 获得自行取数或地址执行能力。

## 2. 连续搬运与 indexed memory `[RTL事实]`

连续或条带化的 RF fill 首先考虑 bank select、demux 和分周期写入，不经过任何跨
lane 置换网络。这条路径的职责是把外部数据搬进 VRF，不负责重排。

数据依赖的跨 group 选择当前直接属于 MEMORY class：索引 VRF row 为每个物理 lane
提供 unsigned 8-bit byte offset，地址为 `base + signed_offset + index[lane]`。
LOAD 是 gather，STORE 是 scatter。实际 4-group profile 在 full group mask 下搬运 16 个
byte，这些 byte 可落在 256-byte window 的任意 16 个位置；参数化上限是
16 group/64 byte。稀疏 group mask 按每个被选 group 减少四个 transfer。
这不是把整个 256-byte window 一次搬完。

只有要求把 `4M` 个输入 byte 在一个周期任意映射到 `4N` 个目的 lane，才直接推导出
矩形 `4M × 4N` crossbar。顺序 fill、banked SRAM、若干 ingress lane 和多拍
packetizer 可以避免把这个最强映射能力当作数据装载的默认成本。复制仍可由 SIMD4
内部 broadcast 完成；point-to-point 网络不必因此具有复制语义。

当前 vector memory engine 对命令接受前发现的字段组合、effective-address 位宽
溢出和对齐错误产生带 tag、
已提交 0 byte 的错误完成；运行时 memory 或 VRF child 错误采用
stop-on-first。早先完成的 group 不回滚，completion 显式返回 requested/
completed/failed group mask、committed bytes 和 partial。重试仍未设计。
实际 local SRAM/descriptor bounds 尚不在 controller 入口检查，由上游 view
解析或 memory error response 负责。

## 3. 宽度与吞吐只作为测量参数 `[开放问题]`

外部接口可以从 DMA burst 宽度看，而不是从单条 RF 写指令反推。`128 bit` 可作为
首个逻辑 transfer line，`256 bit` 可作为八个 SIMD4 各写一行 VRF 的聚合候选；
两者都不是当前 profile 的承诺。gearbox 可以让外部 burst、local SRAM bank 和叶端
state-write 使用不同宽度。

下面只取一个假设的 8-group 扩展点说明计量方法，不表示当前 4-group 实例已经部署
八组。八个 SIMD4 在每周期各执行一次双源 byte-vector 操作时，逻辑 RF 读量是
`8 × 2 × 4 = 64 byte/cycle`；它不是外部唯一数据摄入率。若 A、B 的平均寄存器内
复用次数分别为 `R_A`、`R_B`，忽略中间值和边界流量的粗略 fill 需求为：

```text
unique input bytes/cycle ~= 32/R_A + 32/R_B
```

这个式子只用于标出复用率的重要性，不能替代负载 trace。时钟频率、LS 指令密度
或“通常能复用十次”目前都不作为设计常量。

## 4. 当前 VRF vector memory engine `[RTL事实]`

`vsp_vector_memory_engine` 每次只保存一个 active parent，且最多发出一个
outstanding memory beat。命令为：

```text
LOAD/STORE + exec_context/tag
           + UNIT_STRIDE/INDEX_U8 address mode
           + addr_space + addr_context
           + base_eaddr + signed offset
           + group mask + data VRF row
           + index VRF row + span_bytes
```

进入 engine 的 `span_bytes` 是已解析的连续合并 span，不是“等宽数组”。engine
不观察地址并自动合并独立 command。uword 的五位 `span code` 中，code `0` 由 action
adapter 按捕获的 group mask 解析为 `4 * popcount(group_mask)` byte，code `1..31` 是
显式 span；因此完整 16-group 线性传输可表达为 64 byte。若需要大于 31 byte 又带
partial tail，软件拆成多条 command。有效 group 按编号升序映射到连续 4-byte beat；
最后一 beat 可只使用低位 byte tail。命令要求 4-byte 对齐，且解析后满足
`ceil(span_bytes/4) = popcount(group_mask)`。

`INDEX_U8` 的 decoded `span_bytes=0`，它与 `UNIT_STRIDE` 的 code-zero sentinel 由地址
模式区分；该模式按 group 升序、lane 升序访问全部选中 group 的
四个 byte lane。gather 允许重复 index 形成 memory broadcast；scatter 的重复地址按
该遍历顺序串行写入，最后一个 lane 获胜。scatter 不是原子操作，遇错后已提交 byte
不回滚。`bytes_committed` 统计成功的 lane transfer 数，不是去重后的物理地址数。
gather 只有在一个 group 的四个读取全部成功后才写该 group VRF row。

- unit-stride LOAD：memory read response 先被缓存，再发出对应 group 的 masked VRF
  state-write child，收到 child completion 后才推进下一 beat；
- unit-stride STORE：发出 VRF read/export child；child completion 和 data response 可任意
  顺序到达，两者都收齐后才发 memory write，并等待 write ack；每个 accepted
  read 即使报错也必须各产生一条 completion 和一条 response；
- 只支持 VRF。ARF 需先用 `NSLICE`/`NCLIP` 转换到 VRF 再 STORE；
- 每个 accepted parent 恰好一条可背压 completion。

indexed engine 读取 index row；scatter 再读取 data row。每个 byte 被降为普通、对齐
的 4-byte dmem beat：gather 从返回 beat 选择一个 byte，scatter 用 one-hot write strobe。
因此下游 MMU/cache 不需要理解 vector index。当前仍只有一个 outstanding memory beat；
延迟会随 VRF/dmem backpressure 变化，不是固定周期，也不能每拍接收一条新命令。

`exec_context` 是 sequencer/owner 身份；`addr_context` 是交给未来地址
服务的 opaque handle，两者不是同一命名空间。`addr_space` 明确区分
`LOCAL`、`PHYSICAL` 和 `TRANSLATED`。`MEM_EADDR_W` 是 effective-address
payload 宽度；`VRF_ROW_ADDR_W` 由 `VRF_ROWS` 推导，是 VRF row index
宽度，不是 virtual-address width。
对应的主要参数名为 `VRF_ROW_BYTES`、`VRF_ROWS`、
`EXEC_CONTEXT_COUNT`、`CMD_TAG_W`、`MEM_EADDR_W`、`MEM_OFFSET_W` 和
`ADDR_CONTEXT_W`；MEMORY op、address-space、fault 与 completion 类型由
`vsp_pkg` 定义。这些是内部 canonical control 语义，不是已冻结 ISA 编码。

`dmem_req/rsp` 是 data-memory 逻辑口：单飞行、有序、无 transaction
ID，每个 accepted LOAD/STORE request 恰好一条 response。未来 adapter
可以对 `TRANSLATED` 请求做翻译，对 `LOCAL/PHYSICAL` 做旁路/路由；
engine 本身不实现 MMU、TLB、PTW、cache、replay 或乱序返回。
每个 beat 都携带自己的 current effective address，因此翻译服务应逐 beat
查询/命中 TLB，不能只翻译 parent 的 base 后再连续递增物理地址；跨页时相邻
virtual page 不保证映射到相邻 physical page。

`dmem_rsp` 携带 fault cause；parent completion 保留 fault cause 和 fault
effective address。translation、permission、access、bus、data-integrity 和
protocol 错误可区分。

首版 request/response 没有 epoch。vector memory engine、downstream dmem endpoint 与 VRF subrequest endpoint
必须共享事务域 reset，并在 reset 时共同丢弃旧 outstanding response；异步保留旧
response 后立即启动新命令不属于当前协议。

### 4.1 当前 cluster VRF child 路径 `[RTL事实]`

`simd_group_wrapper` 除 state-write 外，已有独立的 VRF state-read request、
completion 和 data response。read completion 与 response 可以分别背压；wrapper
在接受 read 时同时保留两条返回的容量，非法 context/row 返回 illegal、零 data
与零 mask，不修改 RF。`simd_cluster_exec` 按 group demux state-read/write，
并分别用 stall-stable RR 汇聚 read completion、read response 与 write completion。

`vsp_cluster_vrf_arbiter` 在多个 client 与上述 cluster endpoint 之间仲裁
VRF-only read/write subrequest。参考实现一次只允许一个 accepted subrequest 在途；read owner
保持到 completion 和 response 都被对应 client 接受，write owner 保持到 completion
被接受。仲裁和 owner capture 解决的是 child 返回归属，不提供 program-level
class ordering、寄存器依赖或 group ownership 判定。

`vsp_cluster_memory_wrapper` 当前以唯一的 MEMORY client 实例化该 arbiter，把 vector
memory engine 的 LOAD state-write 和 STORE state-read 接到
`simd_cluster_exec`。arbiter 的参数化接口为以后并接其他 VRF-only engine
留出边界，但当前 wrapper 只有一个 client，也没有在 EXEC 与 MEMORY 两个独立 command
入口之间建立统一顺序。

因此 decoded memory wrapper 单独复用时，调用者必须保证会访问同一 VRF state 的
EXEC/MEMORY 不交错；产品 uword 路径由 strict single-active controller 提供这项顺序。
indexed engine 的快照粒度是当前 group，不是整条分布式向量的原子快照。

`vsp_cluster_controller_wrapper` 保留上述两个叶端入口，在更外层只暴露一个 ordered
action lane。它在 MEMORY 发往 engine 前执行 common context/owner precheck，把
memory fault/partial detail 保存进统一可背压 completion，并禁止年轻 EXEC 或
CONTROL 越过尚未退休的 MEMORY。owner snapshot 当前由外部提供，至少从 action
accept 保持到 child completion；这不是动态 owner table。

## 5. Strict 集成闭环与延期项 `[已实现参考 + 延期项]`

当前闭环保持 blocking：

```text
dmem LOAD response
  -> 若干 VRF state-write child beat
  -> decoded EXEC
  -> 若干 VRF state-read child beat
  -> dmem STORE request/ack
```

`vsp_cluster_memory_wrapper` 已完成上述 decoded reference wiring；自检 testbench 用
边界外 local-memory model 顺序驱动 LOAD、ADD-immediate EXEC 和 STORE，
117 项检查覆盖四组数据变换、请求背压、完成状态与 protocol-error 清洁。这里的
“顺序”来自 test driver 等待前一 command completion 后再提交下一 action，并非 wrapper
已实现 common class router 或 program-order enforcement。

更外层 controller testbench 持续提供 `decoded LOAD → profile-v0 encoded EXEC →
decoded STORE → END` action stream，不由 driver 等待并选择下一 class；strict
controller 自动建立顺序，并验证统一 completion 背压、MEMORY owner precheck、
fault/partial detail 与 END。该 closure 仍是 blocking single-active reference，
不表示 queue-head sequencer 或 DMA 已完成。

再外层 `vsp_uword_cluster_program_wrapper` 已从 behavioral control store 的 byte-PC
stream 解析 CONTROL state 与 MEMORY record。当前 directed closure 先以
`SMOVI/SADD/SADDI` 构造 `0x100/0x104` 两个 effective address，再执行单组四 byte
`VLOAD → ADD-immediate EXEC → VSTORE → END`；test-side dmem responder 验证
address space/context、request backpressure、load data、store data/strobe，以及八项
有序 completion/tag。MEMORY admission 快照 state base，后续 transfer 不 live-read
state RF。

产品级 `vsp_uword_cached_program_wrapper` 另以同一个 behavioral control-store program
执行三次 16-byte physical/cacheable `VLOAD -> saturating add -> VSTORE` 循环，并通过
真实 D-cache、physical fabric 和 ordered SRAM 检查结果及详细 MEMORY completion。它保持
相同 single-active/single-dmem-beat engine 合同，不增加 action overlap。

`vsp_uword_memory_system_wrapper` 保持同一个执行合同，但从 external provider seam 经
redirect bridge、共享 iMMU、独立 I-region 和 read-only I-cache 取得 uword，并让 I-cache
与 D-cache/PTW/uncached-device 共用 physical fabric。独立的同顶层动态回归已从 lower
program image 运行 PHYSICAL I+D branch loop，并在 1290 checks、1483 cycles 内观察到
72 shared-lower beats 与 4 次 I-cache miss；它没有覆盖 TRANSLATED/fault I-fetch 或真实
SoC lower target。

该闭环仍只消费 framer slot 0，并在全局 single-active controller 下逐项推进；它没有
接入 `vsp_ordered_action_window`，也没有实现 multi-record 并发 admission、计算/搬运
重叠或高吞吐 memory supply；program path 已有严格串行的
`J` 与六种双寄存器比较 branch 可以 redirect，但仍没有 memory/action overlap。

当前 product path 已集成 local SRAM、I/D cache/MMU adapter 与 lower-width cache/fabric
转换；DMA、SoC target/bus 和系统级 ingress/capture FIFO 仍未集成，详细 IFetch fault
metadata 也尚未穿过 legacy program-source response。
`dmem_*` 继续作为 engine 与产品内存子系统间的 effective-address 逻辑边界。ping-pong、计算/搬运重叠、
多 outstanding、二维地址和一致性在真实 trace 与 SoC 边界出现后再评估。

独立 `vsp_ordered_dmem_model` 已把该逻辑边界的 byte array、little-endian 读写、
write strobe、地址空间/范围 fault、固定延迟和 FIFO ordered response 变成可执行模型。
模型默认 depth=4，用于验证无 ID 时的严格顺序合同；当前 vector memory engine 仍只会
产生一个 outstanding beat。乱序返回需要 transaction ID 与 requester scoreboard，
不由 AGU 单独解决。

实施顺序与验收条件见[开发路线的 M2 与 M4](development-roadmap.md)。
