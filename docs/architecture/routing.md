# SIMD 局部数据路由

## 作用域 `[当前 profile]`

当前路由网络属于一个 SIMD 执行单元，不是覆盖整个 VSP 的全局互连。架构调度
实验目前使用四个 8-bit physical lane 的 SIMD4。叶模块仍对 8、16 lane 参数
做健壮性 lint，但扩大总并行度的当前工作模型是增加 SIMD4 group 数，而不是扩大
一个 group。

```text
VSP / cluster
├── SIMD group 0: local route + lanes + local VRF slice
├── SIMD group 1: local route + lanes + local VRF slice
└── shared sequencer / SRAM / reduction and boundary links
```

多个 SIMD group 可以接收同一微操作，分别处理连续的元素区间。逐元素运算因此可以把 `2 × SIMD4` 当作逻辑上的 8-lane 工作。任意跨组 permutation 并不由此自动获得；它需要额外网络或经过局部存储分拍执行。

## Crossbar 语义 `[接口语义]`

`simd_crossbar` 为每个输出提供一个独立的源 lane 索引：

```text
out[lane] = in[index[lane]]
```

- 所有索引唯一：permutation；
- 索引可以重复：gather/multicast；
- 所有索引相同：broadcast。

多个输出读取同一输入不存在目的冲突。多个输入试图写同一个目的则属于 reduction、scatter 或仲裁问题，不由该网络定义。

当前 SIMD4 RTL 采用直接 4×4 crossbar。接口保留任意重复索引，而普通 Bênes
网络只保证一一置换。扩大并行度时，“每组 local crossbar + 上层 row exchange”
是候选拓扑，不是由当前 crossbar 自动推出的唯一方案。

## `simd_route` 操作

| 操作 | 含义 |
|---|---|
| `ROUTE_OP_GATHER` | 每个输出使用自己的 `index_i`，覆盖 permutation/gather/multicast |
| `ROUTE_OP_BROADCAST` | 所有输出读取 `broadcast_index_i` 指定的输入 lane |
| `ROUTE_OP_SLIDE_UP` | 数据向高编号 lane 移动，低端缺口从 `lower_i` 获取 |
| `ROUTE_OP_SLIDE_DOWN` | 数据向低编号 lane 移动，高端缺口从 `upper_i` 获取 |

`slide_amount_i=0` 是恒等映射；`slide_amount_i=LANES` 完整传入相邻 SIMD group。更大的数超出这个局部网络覆盖范围并报告 `illegal_o`。

将 `lower_i/upper_i` 绑为零即可得到局部零填充 slide；它们本质上是抽象 boundary
ports。正确性只要求 boundary data 在事务期间稳定并经过资源仲裁；M2 参考实现
先把数据捕获到 boundary staging/ingress，避免直接组合读取另一个正在执行的
group RF。`boundary_mask_o` 只标记哪些结果来自 boundary
输入，不是执行 mask。

## 数据通路位置

当前只实例化一份路由网络，放在 VRF source A 与 lane execution 之间：

```text
VRF source A ── local route ──┐
                              ├── lane execute ── writeback/reduction
VRF source B ─────────────────┘
```

- `route_enable_i=0`：source A 直接进入执行单元；
- `route_enable_i=1`：source A 先经过路由；
- `PASS_A + write_vrf_i`：形成单独的 route 写回；
- 其他 ALU 操作：可以直接消费路由后的 A，避免临时寄存器。

这避免为两个源操作数复制两套 crossbar，也没有把网络串到 B 操作数路径。当前仍是无内部流水的组合实现；可否满足目标频率必须在选定工艺和 lane/位宽后通过综合判断。

## Mask 驱动的稳定重排

普通 `GATHER` 要求 sequencer 已经给出每个输出的 lane index。组内
`COMPRESS/EXPAND` 则由 MRF 自动生成稳定映射和有效数，不要求 sequencer 扫描
mask：

- `COMPRESS` 依次收集 lane 0 到 lane `LANES-1` 的活动元素，放入连续低 lane；
- `EXPAND` 依次消耗连续低 lane，在 mask 指定的位置恢复元素；
- 未承载元素的输出 lane 置零；
- `count` 返回活动元素数，结果 mask 可写回 MRF。

当前 RTL 用独立的参数化组合重排单元表达行为。物理实现可以让它与 source-A
crossbar 共享选择网络，也可以根据时序结果分拍执行；这一选择仍然开放。
跨 group 的 packet 拼接、余数保留和网络流控仍属于上级 VSP 互连问题。

## 跨组 row-level Bênes `[独立 engine RTL + 集成候选]`

跨组网络以 SIMD4 row 为端口颗粒，不把四个 physical byte lane 各自展开为全局
端口。若网络有 `P` 个物理端口，一次通过时每个端口携带：

```text
row_packet = {byte_we[3:0], data[31:0]}
port p < GROUP_COUNT  <-> SIMD4 group p
```

当前 `vsp_benes_exchange_engine` 令 `P = GROUP_COUNT`，并要求 `P>=2` 且为
二次幂；非二次幂 group 补 dummy endpoint 是后续适配候选，不是当前 engine
能力。`byte_we` 与数据经过完全相同的 switch
选择；输出 `byte_we` 是目的 VRF row 的逐 byte 写使能，零 mask packet 不产生
写回。网络自身始终是一一置换：一个输入 packet 在一个 pass 中至多到达一个输出，
一个输出也至多接收一个输入。重复读取、复制和 broadcast 不进入 Bênes switch
语义。

一次 `EXCHANGE` action 只表示一个物理 pass。现有 engine 接受由外部 route
register/controller 解析好的 `route_entry_valid + raw switch control`，并在 command
握手时连同 row、byte mask、context/tag 和预期 mask 一起快照。engine 内没有 route
table；route register 的装载方法、表项数量、class router、cluster 接线和最终指令
位域都尚未实现或定义。

三个 mask 具有不同含义：

```text
src_group_mask       本 pass 实际读取的源 group
dst_group_mask       src mask 经同一 route 后落到的目的 group
resource_group_mask  src_group_mask | dst_group_mask
```

独立 engine 已用一份同 control 的 mask-shadow Bênes，从输入 byte mask 推导实际
source/destination mask，并与命令携带的两个 mask 比较；不一致或 route entry
无效时返回 `BAD_ROUTE`，不发起 VRF child。cluster 调度器仍需在 action 接受前得到
三者，原子占有全部 source/destination endpoint 和写口。部分参与的 pass 令未参与
物理端口携带零 byte mask；网络仍执行一个完整 permutation，不把 inactive endpoint
解释为广播或丢弃活动 packet。

首版 engine 串行读取各 active source，等待所有 row 完整 capture 后才令
`GROUP_COUNT × 36-bit` 数据网络产生并锁存结果；随后按 group 编号串行提交 masked
VRF write，并等待每条 child completion。读写错误均 stop-on-first，parent completion
报告 requested/completed/failed mask 和 partial。它仍是独立模块，尚未接入
EXCHANGE class、group wrapper 或 cluster completion 汇总。

逻辑向量通常包含多于一个 network pass 的 row。sequencer 将它 strip-mine 成多条
`EXCHANGE`，每一条选择一个无源端口冲突、无目的端口冲突的 matching；本地
`simd_route` 负责 group 内 byte 重排和 broadcast。程序可以在不同 pass 重新读取
同一个 row 来做时分复制，但单 pass 的 token 数仍守恒。多 pass 不是对整个逻辑
向量的一次原子快照：若源和目的存储重叠，必须使用 scratch/ping-pong，或者由
编译器做 cycle decomposition，避免较早写回覆盖后续尚未捕获的源。

对一个完整的 `G groups × 4 byte` tile，任意纯 byte permutation 都可以构造成
source-group 到 destination-group 的二分多重图：每个 byte 是一条边，每个 source
和 destination 顶点的度都为 4。二分图的边可以按最大度分解，因此至多四种颜色，
也就是至多四个无端口冲突的 Bênes matching/pass；每 pass 的 local route 负责选择
该 source group 的一个 byte 并放到目标 byte 位置。较短 matching 用零 byte-mask
packet 补足未参与端口。broadcast/复制会增加 source 顶点的边度数，所需 pass 数
随最大 fanout 增加，仍不要求 Bênes switch 自身复制。这个分解是编译器/sequencer
的候选映射依据，当前项目尚未实现相应 route compiler。

## Broadcast 边界

当前 `ROUTE_OP_BROADCAST` 是 lane-to-lanes broadcast。展开后的 scalar immediate
已经能送到单个 SIMD4；cluster 中相同 uop/常数的物理交付应使用分层控制扇出，
不经过全局 N×N data crossbar。跨组 row 置换由 Bênes 完成；跨组复制由
sequencer 多 pass，组内复制由目的 SIMD4 的 local broadcast 完成。
