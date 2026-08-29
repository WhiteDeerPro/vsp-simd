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
广播；普通 Bênes 网络只保证一一置换，无法直接表达这一点。跨组 route 的**编码与
数据通路接入**仍然延期；作为临时基线，固定 16×16 byte crossbar 已有独立参考
RTL（`vsp_lane_gather`），供需要跨组置换的负载映射先行取证。下文的 Omega 内容
只保留为早期探索记录。

## `simd_route` 操作

| 操作 | 含义 |
|---|---|
| `ROUTE_OP_GATHER` | 每个输出使用自己的 `index_i`，覆盖 permutation/gather/multicast |
| `ROUTE_OP_BROADCAST` | 所有输出读取 `broadcast_index_i` 指定的输入 lane |
| `ROUTE_OP_SLIDE_UP` | 数据向高编号 lane 移动，低端缺口从 `lower_i` 获取 |
| `ROUTE_OP_SLIDE_DOWN` | 数据向低编号 lane 移动，高端缺口从 `upper_i` 获取 |

内部 EXEC profile v0 已给这条本地路径分配单字 `fmt=0xd`。它固定执行
`PASS_A/BYTE`，可写回 VRF、导出窄结果或在 route 后做 SIMD4 reduction；GATHER 的
四个 2-bit source index 全部放在同一 32-bit word。SLIDE 在该编码中把相邻组
boundary 固定为零，所以只有 zero-fill 语义。assembler 示例：

```text
EXEC_ROUTE op=gather va=1 vd=2 i0=3 i1=2 i2=1 i3=0
```

这条编码已经沿 uword predecode、canonical expander、controller 和 group writeback
跑通；它不控制下文独立的 16×16 跨组模块。

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

## 临时基线：`vsp_lane_gather` `[里程碑基线]`

固定全 crossbar 已实现为独立参考 RTL，默认 `LANES=16 / DATA_W=8`，位于
`rtl/interconnect/`，**不接入数据通路**。选它而不是先做 Bênes/Omega 的理由就是
动态路由的成本位置：全 crossbar 没有 route-setting，索引位直接驱动 mux，运行时
索引不产生任何额外控制状态或冲突协议；代价是 `O(LANES²)` 的 mux 面积（16 lane
下为 16 个 16:1 byte mux）。因此“动态难做”在这个拓扑上不成立，难做的是分级网络。

它是纯 gather：`out[lane] = in[index[lane]]`，重复索引合法，任何输出都不会被写
两次。除动态索引外提供一组静态图样，用 4-bit `mode_i` 编码，避免为常见固定置换
交付 `LANES × INDEX_W` 位索引：

| mode | 含义 | 图像用途 |
|---:|---|---|
| 0 `IDENTITY` | 恒等 | 旁路 |
| 1 `GATHER` | 使用 `index_i` 的动态映射 | LUT/gamma、双线性取样、任意重排 |
| 2 `BROADCAST` | 全部输出读 `amount_i` 指定 lane | 系数/像素广播 |
| 3 `ROTATE_UP` | 循环右移 `amount_i` | stencil 邻域 |
| 4 `ROTATE_DOWN` | 循环左移 `amount_i` | stencil 邻域 |
| 5 `REVERSE` | 整向量镜像 | 水平翻转 |
| 6 `TRANSPOSE` | 方形 tile 转置（仅 `LANES` 为完全平方数） | 列访问、可分离滤波第二 pass |
| 7 `DEINTERLEAVE` | 偶 lane 入低半、奇 lane 入高半 | 2 通道拆分、水平 2× 降采样 |
| 8 `INTERLEAVE` | `DEINTERLEAVE` 的逆 | 通道合并、上采样 |
| 9–15 | 保留 | 后续路由方案 |

`wrap_mask_o` 标记 rotate 中源已绕过向量末端的输出 lane。消费端把这些 lane 屏蔽
掉即得到零填充 shift，因此 16-lane 逻辑向量内的 stencil 不再需要相邻组 boundary
端口。它不是执行 mask。保留 mode 与越界 `amount_i` 报告 `illegal_o` 且不交付数据；
动态索引越界（仅在 `LANES` 非二次幂时可能）沿用 `simd_crossbar` 语义，只把该输出
lane 置零。RVV `vrgather` 的越界返零与这里的 `illegal_o` 不能静默等同，跨组
out-of-range 的最终选择仍是开放项。

明确未定义、因此该模块目前不能声称的部分：宽逻辑向量如何 stripe 到各 group 的
VRF row、索引来自 VRF 还是立即数、资源预留与 group ownership、写回事务，以及
分级/流水与面积。它是可替换的临时基线，不是已选拓扑。

## 跨组 lane gather 语义 `[延期议题；以下含历史探索]`

跨组 route 的 **encoding 与 controller 接入**仍不在当前路线内；profile v0 的
`fmt=0xd` 只编码组内 4×4 route。以下 register-gather 语义与 Omega 比较保留用于
追溯问题，不代表已选拓扑。

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

### 历史候选：gather-only Omega 网络

曾讨论用 multicast Omega 网络替代跨组 Bênes，并统一组内/组间路由：

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
16×16 固定 crossbar（`vsp_lane_gather`）已作为独立临时基线实现并验证，但未接入
数据通路，也没有相关编码。参数化 Bênes 网络（`benes_network`）与上述 Omega 方案
只作为网络研究材料保留，不接入数据通路。

## Broadcast 边界

当前 `ROUTE_OP_BROADCAST` 是 lane-to-lanes broadcast。展开后的 scalar immediate
已经能送到单个 SIMD4；cluster 中相同 uop/常数的物理交付应使用分层控制扇出，
不经过全局 N×N data crossbar。跨组广播/置换在延期期间不具有可调用硬件语义；
组内复制仍可由目的 SIMD4 的 local broadcast 完成。
