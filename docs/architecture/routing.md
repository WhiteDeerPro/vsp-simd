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

## 候选：4-group 固定四次迭代 gather `[研究结论，RTL 未实现]`

这里的目标仍是 byte-lane register gather，不是 indexed memory load：四个相邻
SIMD4 group 各提供一个 32-bit VRF row，共同形成 16-byte source、16-byte index 和
16-byte destination view。这个“4-group route domain”只是候选物理共享范围，不增加
新的编程模型术语。语义先写成：

```text
for i in 0..15:
    if destination_active[i]:
        destination[i] = index[i] < 16 ? source[index[i]] : 0
```

重复 index 合法并形成 multicast/broadcast；每个 destination byte 只有一个 producer，
因此不是 scatter。index 可由 VRF 的第二读操作数提供。为了让超范围值不会被低四位
截断后回绕，首版即使只访问 16 个 byte，也应保存并检查完整的 8-bit index。

### 源侧 local route 后接 word multicast：原算法成立

令 `source[c][d]` 表示源 group `c` 的 byte `d`，目标
`destination[j][t]` 的 index 可拆成 `(c[j][t], d[j][t])`。四次迭代的 phase `p`
选择：

```text
t[j] = (j + p) mod 4
local_select[c[j]][t[j]] = d[j]
word_select[j] = c[j]
byte_write_enable[j] = 1 << t[j]
```

`j -> t[j]` 在每个 phase 是双射。因此，同一个源侧 local crossbar 的同一个输出
byte 位置不会同时被要求选择两个不同的 `d`；local crossbar 可以把该 phase 所需的
不同 byte 放到 packet 的不同位置。后级 4×4、32-bit word crossbar 的每个输出独立
选择输入，允许多个输出重复选择同一个输入 packet。目的 group 只写自己的 one-hot
byte。四个 phase 又使每个 `(j,t)` 恰好出现一次，所以任意
`index in [0,16)^16`，包括全广播，都能完成。

这里“不同 `t`”解决的是**同一个源 packet 位置的控制冲突**，不是不同 group 之间的
VRF 写冲突。证明还依赖两个明确条件：

- 源侧 4×4 byte network 是 output-selects-input 的 gather crossbar，允许重复选择；
- 4×4 word network 同样是 multicast crossbar。当前 `simd_crossbar` 满足这两个
  条件；只含 straight/cross 2×2 switch 的 `benes_network` 不提供复制，不能替代它。

在“每个目的 group 每次只写一个 byte”的题设下，每个目的有四个 byte，四次迭代既是
上界也是下界。它应称为 **fixed-four-pass iterative gather**，不是天然的四级流水线：
只实例化一套网络时，route core 的 latency 和 initiation interval 都至少为四个
route cycle；operand capture、最终 commit 和 completion backpressure 还在这四次之外。

这个反对角线证明适合恰好 `M=L=4`。推广到 `M` 个 group、每组 `L` 个 byte 时，原
`t=(j+p) mod L` 构造只有在 `M<=L` 时无条件保证同 phase 的 `t` 不重复；`M>L`
不能直接声称仍为 `L` 次。可以把目的分成至多 `L` 个 group 的 batch，安全代价为
`ceil(M/L)*L` 次，但上级 word crossbar 仍会随 `M^2` 增长。

### 更适合 VSP 的次序：word multicast 后接目的侧 local route

原方案正确，但不是唯一的两级次序。对当前 VSP 更自然的优先候选是：

```text
four source-row snapshots
          |
          v
4x4 32-bit word multicast crossbar
          |
          v
four destination-local byte selectors / 4x4 routes
          |
          v
128-bit result staging -> parallel masked VRF commit
```

phase `p=0..3` 直接让所有目的 group 处理本地 offset `t=p`：

```text
idx = index_snapshot[j][p]
word_select[j] = idx[3:2]
destination_local_select[j][p] = idx[1:0]
result[j][p] = selected_source_word[j][idx[1:0]]
```

每个目的 group 的 local selector 独立，因此多个目的即使选择同一个 source word、同一个
byte 位置，也不会产生源侧 local-control 冲突。对一般 `M x L` 结构，只要上级是
`M x M` multicast word crossbar，这个次序可固定用 `L` 次完成；但 `M x M` 的布线
成本仍使它更适合小型物理 domain，而不是全 cluster 任意 byte gather。

这个次序还有两项实现优势：

- 它与现有“外来 source-A word 进入 group-local route”的方向一致，控制由每个目的
  index row 就地派生，不需要把四个目的的需求转置成源侧 local controls；
- 若以后允许一个目的 group 在同一 phase 写入所有来自同一 source group 的 byte，
  常见 mapping 可按目的中的 distinct source-group 数在 1–4 次完成；首版仍可保留
  固定四次以换取简单 completion 和调度。

是否物理复用当前 `simd_route` 仍需综合判断。直接复用要求增加 external source-A
mux、per-group 独立 route control 和 cluster writeback owner，可能把长组合路径耦合
到普通 ALU。首个 standalone reference 更适合在共享 engine 内使用 captured rows 和
小型 byte selector，行为闭合后再比较共享 local crossbar 是否真的省面积。

### 不能只比较“768 对 1920”

按 1-bit 2:1 mux 等价数粗估，且忽略寄存器、选择译码、长线、RF 端口和时钟功耗：

| datapath 候选 | 粗略 mux 数 | route passes | 说明 |
|---|---:|---:|---|
| flat 16×16 byte crossbar | `16*8*15 = 1920` | 1 | 当前独立 reference |
| 源侧 4×4 byte + 4×4 word | `4*4*8*3 + 4*32*3 = 768` | 4 | 用户给出的两级结构 |
| word-first + 每目的一个 4:1 byte selector | `4*32*3 + 4*8*3 = 480` | 4 | 等价于四个 time-muxed 16:1 byte mux |

因此，两级结构的主要吸引力是**复用已经需要的 local route 与 group-word exchange**，
以及以后允许 multi-byte write 的扩展空间；若专门为 gather 新造全部网络，它并非门数
最小。另一方面，mux 数也不是物理结论：flat reference 没有 source/index/result
holding，四次迭代方案需要约 128-bit source、128-bit full-byte index、128-bit result
及 mask staging，并会让 word network 每次搬运 128 bit 而只提交 32 bit。这些实现必须
用同一工艺目标比较 post-route Fmax、面积、每 action 能量、VRF 占用周期和 initiation
interval，当前不删除 `vsp_lane_gather`。

### Transaction 与资源合同

要把“四次 route”变成可调用 engine，至少需要以下合同：

1. admission 原子预留完整、对齐的四个 source/destination group，以及一个
   route-domain shared resource；该 action 仍属于 `EXEC`，不新增 dispatch class；
2. 同拍读取 source row 与 index row，完整快照后才开始迭代。这样既不持续占用 VRF
   read port，也避免 `vd==vs` 或 `vd==vi` 时早期写破坏后续读取；第一版 profile 仍可
   暂时禁止 overlap，直到 hazard metadata 覆盖完成；
3. destination-inactive byte 保持旧值；active 且 index 越界的 byte 写零，二者不能
   共用“禁止写”处理；
4. 优先在 engine 内收齐 128-bit result，再通过四个 group 的并行 masked write path
   commit。当前 `vsp_cluster_vrf_arbiter` 是单 group、single-outstanding client，若逐组
   走该口，四次 route 会膨胀为串行 child transactions，不能继续称固定四次服务；
5. action completion 只在所有目标 group 的最终 commit 都被接收后产生。任何阶段的
   downstream backpressure 必须保持 phase、snapshot、result 和 tag 稳定。

当前 2R1W、per-lane write-mask 的 group VRF 具备所需叶端能力；缺的是 cluster 级
并行 capture/commit、multi-cycle engine、资源预留和动态 index action 字段。编码不应
先挤进现有 `fmt=0xd`：它只包含一组对所有 group 相同的四个 immediate local index。

### Register route、memory fallback 与 indexed memory gather

“memory route”至少包含两件不同的事，不能与 register gather 混成一种操作：

1. **scratchpad/SRAM staging**：数据已经在 VRF，但借共享存储的写地址与读地址完成
   跨 domain 搬运或重排；
2. **indexed memory gather**：数据还在 D-side address space，逐元素计算
   `base + byte_offset[i]` 后取入 VRF。

加上直接 register route 后，三类机制解决不同范围的问题：

| 路径 | 数据起点 | 延迟/故障 | 适合情况 |
|---|---|---|---|
| SIMD4 local route | 本组 VRF | 单拍组合，无 memory fault | 静态小重排、broadcast、slide |
| 4-group iterative register gather | 四组 VRF snapshot | 固定 route passes，无 TLB/cache fault | FFT/小波/transpose/邻域数据已驻留且会复用 |
| SRAM staging 或 packet exchange | 其他 route domain | 多 action，可预测但消耗端口/带宽 | 低频跨 domain 重排、编译器布局兜底 |
| indexed memory gather | D-side memory | 可变；需 AGU/TLB/cache/outstanding/reorder | 数据未入 VRF、索引跨大范围稀疏工作集 |

把已经在 VRF 的值先 STORE、改地址、再 LOAD 会增加 memory traffic、端口占用和可变
等待。对一个已经驻留的 16-byte tile，至少会额外穿过存储边界 16-byte 写和 16-byte
读；若希望在写入时完成任意 byte scatter，还会把问题转成 SRAM bank conflict、逐 byte
write-enable 或多拍仲裁。因此它不应替代 domain 内的 register gather，只应作为跨
domain、跨容量层级或低频路径。它的优势是复用现有共享 SRAM 和地址通路，网络规模不随
cluster 全局互连平方增长，并能自然形成较长数据生命周期的 rendezvous point。

反之，若 16 个 index 只命中大地址空间中的少数元素，先连续加载整个覆盖范围也可能更
浪费；这时需要未来独立的 indexed-memory engine。它的语义是
`address[i] = base + byte_offset[i]`，不是 register gather；它节省无用数据传输，但必须
接受 TLB/cache miss、bank conflict、返回乱序和 fault completion 带来的可变服务时间。

一个有价值的混合优化是由 memory side 先按 SRAM/cache line 合并请求：若 index 都在
同一个小 block，连续取 block 到 staging，再用 register gather 排列进 VRF；跨多个
block 时仍由 memory engine 保存 element tag、fault 和 response merge 状态。两类 engine
可以共享 VRF writeback arbiter 或小型 byte selector，但不应共享同一个架构操作语义。

### 当前层级建议

```text
SIMD4 group
  -> 现有 4x4 local route，1 cycle，immediate/static pattern

aligned 4-group route domain
  -> 候选 iterative register gather，dynamic VRF index，4 route passes

execution cluster with several route domains
  -> point-to-point word/packet exchange + staging；不承诺全局任意 byte gather

D-side memory hierarchy
  -> 未来独立 indexed gather/scatter AGU/coalescer/reorder path
```

先保留 flat `vsp_lane_gather`，再实现纯组合 phase reference，对
`source-local anti-diagonal`、`word-first destination-local` 和直接 time-muxed byte mux
做等价验证与综合 A/B。只有真实 trace 显示跨 route-domain gather 频繁，才扩大 network；
否则让编译器用 packet exchange、scratch row 或 SRAM layout 组合，避免全 cluster
`O(group_count^2)` word crossbar。

资料对照：RVV 也把
[register gather 与 indexed memory load/store](https://docs.riscv.org/reference/isa/extensions/vector/_attachments/riscv-v-spec.pdf)
分成不同操作族；Ara 把
[VLSU、全连接 permutation unit 与 lane execution](https://github.com/pulp-platform/ara/blob/main/docs/source/modules/ara.md)
分开；Saturn 的
[VLSU 手册](https://saturn-vectors.org/)展示了 DSP 型 conventional memory 对 indexed
address generation 的吞吐限制；AraXL 的
[层级互连研究](https://arxiv.org/abs/2501.10301)说明 lane 数扩大后物理布线会主导；近期
[短向量 permutation unit 实现](https://arxiv.org/abs/2505.07112)也表明 flat crossbar
在具体工艺下未必不可接受，所以最终选择仍应来自综合，而不是只看渐近式。

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
是 `0..min(255,N-1)`；当前 16-lane 候选只能访问 0..15。上面的 four-pass reference
选择 RVV-like 的 out-of-range 写零，便于与 flat reference 做行为等价；真正接入 profile
时仍需把这一规则写进 canonical action。当前 local `simd_crossbar` 的非法索引路径报告
`illegal_o`，两者不能静默等同。

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
