# 数据准备与 DMA 边界

> 状态：VRF-only `vsp_vrf_span_engine`、row-level
> `vsp_benes_exchange_engine`、wrapper/cluster 的独立 VRF state-read 路径及
> `vsp_cluster_vrf_service` 已有参考 RTL。`vsp_cluster_memory_shell` 已把 blocking
> span actor 接到 GROUP_EXEC cluster，形成 decoded LOAD→GROUP_EXEC→STORE 参考闭环。
> class router、跨 class 程序顺序、owner/resource controller、物理 local SRAM、
> MMU/cache、DMA 与 EXCHANGE 接线仍待实现。本文不规定总线宽度、SRAM 组织、
> DMA 描述符格式或 Bênes 的物理分级；跨组交换采用 group-aligned row packet 语义。

## 1. 控制动作与传输数据分离 `[候选]`

`RF_FILL`、`RF_DRAIN` 可以作为 sequencer program 中的 `MEMORY` class 动作，与
算术 uword 共用有序发射和 tag/completion 规则；但它们的 bulk data 不进入
instruction queue。queue 只需保存 descriptor reference、目标摘要、依赖和少量
已解析参数。

候选数据层级为：

下面是最终可能出现的完整层级。当前 decoded reference integration 在 `dmem_*`
逻辑边界处终止；testbench 在边界外提供 local-memory model。物理 local SRAM、
cache/MMU adapter、SoC DMA 及其上方接口延期到后续集成。

```text
SoC memory / producer
        │ DMA burst
        ▼
burst FIFO / width gearbox
        ▼
banked local SRAM or scratchpad
        ▼
memory actor + packetizer
        ▼
per-group ingress / capture staging
        ▼
SIMD4 state-write / export endpoint
```

sequencer/controller 发起或许可 program-level memory action；memory actor 保存地址
推进、beat 计数和 parent/child completion 状态；SIMD4 只接受已经带数据的叶端
state-write beat。这样不会因为加入数据供应而让 SIMD4 获得自行取数或地址执行能力。

## 2. 普通填充与交换分开 `[独立 RTL + 集成候选]`

连续或条带化的 RF fill 首先考虑 bank select、demux 和分周期写入，不必经过 Bênes。
Bênes 面向已经进入 staging 的 group 间 row exchange。每个物理端口与一个 SIMD4
group 对齐，一次携带：

```text
{byte_we[3:0], data[31:0]}
```

mask 与 data 使用同一条一一置换路径；输出 `byte_we` 直接控制目的 VRF row 的
masked write。inactive group 注入零 `byte_we` packet。当前 engine 要求
`GROUP_COUNT>=2` 且为二次幂；用 invalid dummy endpoint 包装非二次幂 group 是
后续候选。Bênes 不提供复制能力。

一条 `EXCHANGE` 只处理一个物理 pass。超过网络一次 row 容量的向量由 sequencer
拆成多个 pass，并配合 SIMD4 local route 完成 byte 重排或 broadcast。多 pass
若在同一组寄存器上原地工作，需要 scratch/ping-pong 或 cycle decomposition；
不能假定前一 pass 的写回不会覆盖后一 pass 的源。

现有 engine 的 canonical command 接收外部已经解析的 route-entry valid/raw
control，而不是指令立即数，并在 command 接受时快照到飞行事务。交换调度还需
区分 `src_group_mask`、路由得到的 `dst_group_mask` 和二者之并
`resource_group_mask`。engine 已用 mask-shadow route 在任何 VRF child 前核对
source/expected-destination mask；route table、class router 和 cluster 接线仍未实现，
最终编码保持开放。

engine 首版单飞行：按 group 编号串行读取 source row，等全部 active source capture
完成后通过 `GROUP_COUNT × 36-bit` Bênes 锁存 routed packet，再按 group 编号串行
masked-write destination。任一 read/write child 错误 stop-on-first；parent
completion 显式返回 requested/completed/failed mask 和 partial。

只有要求把 `4M` 个输入 byte 在一个周期任意映射到 `4N` 个目的 lane，才直接推导出
矩形 `4M × 4N` crossbar。顺序 fill、banked SRAM、若干 ingress lane 和多拍
packetizer 可以避免把这个最强映射能力当作数据装载的默认成本。复制仍可由 SIMD4
内部 broadcast 完成；point-to-point 网络不必因此具有复制语义。

当前 span engine 对命令接受前发现的字段组合、effective-address 位宽
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

八个 SIMD4 在每周期各执行一次双源 byte-vector 操作时，逻辑 RF 读量是
`8 × 2 × 4 = 64 byte/cycle`；它不是外部唯一数据摄入率。若 A、B 的平均寄存器内
复用次数分别为 `R_A`、`R_B`，忽略中间值和边界流量的粗略 fill 需求为：

```text
unique input bytes/cycle ~= 32/R_A + 32/R_B
```

这个式子只用于标出复用率的重要性，不能替代负载 trace。时钟频率、LS 指令密度
或“通常能复用十次”目前都不作为设计常量。

## 4. 当前 VRF span engine `[RTL事实]`

`vsp_vrf_span_engine` 每次只保存一个 active parent，且最多发出一个
outstanding memory beat。命令为：

```text
LOAD/STORE + exec_context/tag
           + addr_space + addr_context
           + base_eaddr + signed offset
           + group mask + VRF row + span_bytes
```

`span_bytes` 是编译器已选择的一个连续合并 span，不是“等宽数组”。
engine 不观察地址并自动合并独立 command。有效 group 按编号升序映射
到连续 4-byte beat；最后一 beat 可只使用低位 byte tail。命令要求
4-byte 对齐，且 `ceil(span_bytes/4) = popcount(group_mask)`。

- LOAD：memory read response 先被缓存，再发出对应 group 的 masked VRF
  state-write child，收到 child completion 后才推进下一 beat；
- STORE：发出 VRF read/export child；child completion 和 data response 可任意
  顺序到达，两者都收齐后才发 memory write，并等待 write ack；每个 accepted
  read 即使报错也必须各产生一条 completion 和一条 response；
- 只支持 VRF。ARF 需先用 `NSLICE`/`NCLIP` 转换到 VRF 再 STORE；
- 每个 accepted parent 恰好一条可背压 completion。

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

首版 request/response 没有 epoch。span engine、downstream dmem service 与 VRF child endpoint
必须共享事务域 reset，并在 reset 时共同丢弃旧 outstanding response；异步保留旧
response 后立即启动新命令不属于当前协议。

### 4.1 当前 cluster VRF child 路径 `[RTL事实]`

`simd_group_wrapper` 除 state-write 外，已有独立的 VRF state-read request、
completion 和 data response。read completion 与 response 可以分别背压；wrapper
在接受 read 时同时保留两条返回的容量，非法 context/row 返回 illegal、零 data
与零 mask，不修改 RF。`simd_cluster_exec_shell` 按 group demux state-read/write，
并分别用 stall-stable RR 汇聚 read completion、read response 与 write completion。

`vsp_cluster_vrf_service` 在多个 parent actor 与上述 cluster endpoint 之间仲裁
VRF-only read/write child。参考实现一次只允许一个 accepted child 在途；read owner
保持到 completion 和 response 都被对应 client 接受，write owner 保持到 completion
被接受。仲裁和 owner capture 解决的是 child 返回归属，不提供 program-level
class ordering、寄存器依赖或 group ownership 判定。

`vsp_cluster_memory_shell` 当前以一个 MEMORY client 实例化该 service，把 span
engine 的 LOAD state-write 和 STORE state-read 接到 `simd_cluster_exec_shell`。
service 的多 client 接口为以后并接 EXCHANGE 留出边界，但当前 shell 没有连接
EXCHANGE，也没有在 EXEC 与 MEMORY 两个独立 command 入口之间建立统一顺序。

## 5. 首个集成闭环与延期项 `[已实现参考 + 延期项]`

首个闭环可以保持 blocking：

```text
dmem LOAD response
  -> 若干 VRF state-write child beat
  -> decoded GROUP_EXEC
  -> 若干 VRF state-read child beat
  -> dmem STORE request/ack
```

`vsp_cluster_memory_shell` 已完成上述 decoded reference wiring；自检 testbench 用
边界外 local-memory model 顺序驱动 LOAD、ADD-immediate GROUP_EXEC 和 STORE，
117 项检查覆盖四组数据变换、请求背压、完成状态与 protocol-error 清洁。这里的
“顺序”来自 test driver 等待前一 parent completion 后再提交下一 action，并非 shell
已实现 common class router 或 program-order enforcement。

独立 exchange engine 已有内部 row capture 和路由/写回状态机，但尚未接到
EXCHANGE class、shared VRF service 或 cluster completion。物理 local SRAM、DMA、
cache/MMU adapter、packetizer/gearbox 和系统级 ingress/capture FIFO 也未集成；
`dmem_*` 仍只是 effective-address 逻辑边界。ping-pong、计算/搬运重叠、
多 outstanding、二维地址和一致性在真实 trace 与 SoC 边界出现后再评估。

实施顺序与验收条件见[集群实验路线的 M4](development-roadmap.md)。
