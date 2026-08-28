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

多个输出读取同一输入不存在 architectural write conflict。多个输入试图写同一个
目的属于 reduction、scatter 或仲裁语义，不由这个 output-selects-input 接口定义；
这与多级网络内部两条合法路径争用同一 link 的 internal path conflict 是两回事。

当前 SIMD4 RTL 采用直接 4×4 crossbar。接口保留任意重复索引，因此组内已经支持
广播；普通 Bênes 网络只保证一一置换，无法直接表达这一点。扩大并行度时的候选
拓扑是用统一的 multicast Omega 网络覆盖组内与跨组 gather，详见下文；这不是由
当前 crossbar 自动推出的唯一方案。

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

## 跨组 lane gather `[候选语义，RTL 待实现]`

跨组路由不再候选为与 MEMORY 并列的独立 command class，也不再预设以 SIMD4 row
为端口颗粒。当前用一个 register-gather action 描述目标语义；它不是已经编码的
指令，候选位置是 Vector ALU 内的一个 routing 级：

```text
ROUTE SR, IR, DR
DR[lane] = SR[IR[lane]]
```

`SR`、`IR` 和 `DR` 是逻辑源、索引和目的视图；它们如何 stripe 到各 SIMD group 的
group-local VRF row 尚未定义。索引候选由 VRF 提供，因此可以是运行时计算结果。
8-bit index 能编码 0..255，但一个具体网络只有 `N` 个 source lane，实际合法范围至多
是 `0..min(255,N-1)`；当前 16-lane 候选只能访问 0..15。跨组 out-of-range 是返回零
还是形成错误仍是开放项：RVV `vrgather` 返回零，而当前 local `simd_crossbar` 的
非法索引路径报告 `illegal_o`，两者不能静默等同。

### 语义边界：只做 gather

每个目的 lane 自带索引，因此目的端天然唯一：

- 索引互不相同：置换；
- 索引重复：广播/多播（多个目的读同一个源）；
- **不支持 scatter**：同一条操作内不会出现多个源竞争写同一个目的。

many-to-one 的写冲突只可能跨操作发生（后一条 gather 覆盖前一条的目的），硬件
不需要在单次操作内做冲突消解。因此不需要 conflict-detection CAM、写归约网络或
串行化重排缓冲。当前不支持 scatter；以后可以比较 sequencer 分解的顺序 STORE，
或独立 indexed-memory unit，但这两条 fallback 目前都没有 RTL。

### 当前为什么不选择 Bênes

Bênes 是 rearrangeable non-blocking permutation network，动态 route-setting 在硬件
上可以实现；当前不选择它是成本与目标语义的权衡，而不是拓扑上“不可实现”：

1. 基础 2×2 Bênes 表达一一置换，不原生复制输入。广播需要额外复制路径、多个 pass
   或外围合并；
2. 动态 permutation 需要 route-setting logic。其工作量和控制状态随 `N log N`
   增长，在本项目的运行时 byte-lane gather 目标下尚无证据值得支付这部分面积和延迟。

静态 pattern 可以预先求控制，动态实现也并非被排除；当前只是不把已验证的裸 Bênes
研究模块接入执行数据通路。

### 候选实现：gather-only Omega 网络

计划用 multicast Omega 网络替代跨组 Bênes，并统一组内/组间路由：

- `N` 端口需 `log2(N)` 级，每级 `N/2` 个 2×2 switch；16 lane 为 4 级 32 个
  switch，每 switch 8-bit 数据；
- 候选 switch 支持 straight、cross 和从一个输入向两个输出复制；N-way broadcast
  需要在多个 stage 继续展开，但在路径兼容时可于一次 network traversal 完成；
- destination/index bit 可以参与逐级方向选择，但完整控制方案尚未确定。需要比较
  反向 request network、从完整 IR 组合生成 multicast tree 等实现，不能仅凭索引位
  宣称 routing logic 已闭合；
- Omega 是 blocking 网络，即使 external source/destination 合法，仍可能发生 internal
  path conflict。失败/提交协议尚未选择：可以 all-or-nothing，并返回足以让 sequencer
  预拆无冲突子集的 conflict witness；也可以 partial accept，但必须返回 per-destination
  accepted/completed mask，并保证未接受 lane 不写回。单一 conflict flag 不足以让原
  request 重试后取得进展；实际冲突率也必须由 routing trace 测量。

纯 2×2 拓扑的 Omega 级数少于同规模 Bênes；加入 multicast、冲突判断、staging 和
流水后的面积/时序排序尚未综合，不能据 switch count 直接断言。统一组内与组间控制
仍是候选收益，不是当前 RTL 事实。

FFT/小波是这里的主要负载依据：它们的 butterfly 在 stride 跨过 group 边界时
（如 16 lane 下 stride=4）需要跨组交换，若只有组内 crossbar，每个这样的 stage
都要退化成 STORE→重排寻址→LOAD 的内存往返。跨组 gather 的价值正在于用寄存器
路由替换这些往返，降低内存压力。

当前 RTL 状态：组内 4×4 crossbar（`simd_crossbar`/`simd_route`）已实现并验证；
跨组 Omega 网络、索引到控制位的 routing logic、以及它在 Vector ALU 内的接线
均尚未实现。参数化 Bênes 网络（`benes_network`）作为置换网络研究模块保留，
不接入数据通路。

## Broadcast 边界

当前 `ROUTE_OP_BROADCAST` 是 lane-to-lanes broadcast。展开后的 scalar immediate
已经能送到单个 SIMD4；cluster 中相同 uop/常数的物理交付应使用分层控制扇出，
不经过全局 N×N data crossbar。某个索引模式能被候选 Omega 网络路由时，跨组置换
或广播可由一次 gather 完成；发生 blocking 时，只有在上述 all-or-nothing 拆分或
partial-accept 协议之一确定后才能安全多 pass。组内复制仍可由目的 SIMD4 的 local
broadcast 完成。
