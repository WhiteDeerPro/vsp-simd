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

## 跨组 lane gather `[语义已收束，RTL 待实现]`

跨组路由不再是与 MEMORY 并列的独立 command class，也不再以 SIMD4 row 为端口
颗粒。它收束为一条寄存器形式的 gather 指令，属于 Vector ALU 内的一个 routing
级：

```text
ROUTE SR, IR, DR
DR[lane] = SR[IR[lane]]
```

`SR` 是源向量寄存器，`IR` 是索引向量寄存器，`DR` 是目的。索引由 VRF 提供，
不是指令立即数，因此索引可以是运行时计算结果。一个 lane 是 8-bit，索引本身占
一个 lane，所以单条 gather 的寻址范围上界是 256 lane。

### 语义边界：只做 gather

每个目的 lane 自带索引，因此目的端天然唯一：

- 索引互不相同：置换；
- 索引重复：广播/多播（多个目的读同一个源）；
- **不支持 scatter**：同一条操作内不会出现多个源竞争写同一个目的。

many-to-one 的写冲突只可能跨操作发生（后一条 gather 覆盖前一条的目的），硬件
不需要在单次操作内做冲突消解。因此不需要 conflict-detection CAM、写归约网络或
串行化重排缓冲。scatter 若确有需要，走标量串行 STORE 或 MEMORY 的 indexed
访问，不进入本网络。

### 为什么不用 Bênes

Bênes 网络面积随 `N log N` 增长，且是 rearrangeable non-blocking，看似合适，但
与上面的语义有两处硬冲突：

1. **Bênes 是双射**，不支持广播。要得到 `W1 W1 X X`，必须先置换出
   `X W1 X X` 再合并回源寄存器，一次广播被拆成多步；
2. **控制位无法从索引向量直接求解**。Bênes 的路由需要一个 O(N log N) 的串行
   求解算法，把运行时 `IR` 实时拆解成各级 switch 控制在硬件上不可行。静态
   pattern（编译期已知）可以预先算好，但动态索引会卡住。

这两点使 Bênes 只适合编译期固定的置换，无法承载上面定义的动态 gather。

### 候选实现：gather-only Omega 网络

计划用 multicast Omega 网络替代跨组 Bênes，并统一组内/组间路由：

- `N` 端口需 `log2(N)` 级，每级 `N/2` 个 2×2 switch；16 lane 为 4 级 32 个
  switch，每 switch 8-bit 数据；
- switch 支持四种模式：straight、cross、broadcast-in0、broadcast-in1，故
  广播一步完成；
- **控制位可由索引向量直接派生**：在第 `i` 级，switch 方向取决于目的地址的
  第 `i` 位，是简单的位模式映射而非求解，可用组合逻辑实现；
- Omega 是 blocking 网络，但在"仅 gather、允许广播、无 many-to-one"的约束下，
  传统 blocking 的主要来源（多输入争同一输出）恰好落入 broadcast 模式，冲突
  概率大幅降低。残余冲突由硬件给出 conflict flag，交由软件多 pass。

面积介于 Bênes 与全 crossbar 之间，级数少于同规模 Bênes，且不再需要区分组内
crossbar 与组间网络两套控制路径。

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
不经过全局 N×N data crossbar。跨组的置换与广播由候选 Omega 网络在一次 gather
中完成，组内复制由目的 SIMD4 的 local broadcast 完成。
