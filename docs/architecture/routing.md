# SIMD register route 与交换网络

## 作用域 `[当前 profile]`

当前有两个不同层次的 register-route path：每个 SIMD4 group 内的 4×4 local route，
以及 execution cluster 内已经接入的 VRF-indexed VROUTE。当前参考 profile 用四个
SIMD4 group 组成一个 16-byte route domain；扩大总并行度的工作模型仍是增加 SIMD4
group，而不是扩大一个 group。这里的 cluster route 不是覆盖整个 VSP 或 memory
address space 的全局互连。

```text
VSP / cluster
├── SIMD group 0: local route + lanes + local VRF slice
├── ...
├── SIMD group 3: local route + lanes + local VRF slice
└── shared VROUTE engine
    ├── selected-group VRF source/index snapshots
    ├── 16-byte output-driven gather
    └── selected-group serial masked commit
```

多个 SIMD group 可以接收同一微操作，分别处理连续的元素区间。普通逐元素运算仍在
各 group 内执行；VROUTE 则把同一个 VRF row number 在四组中的 4-byte fragment 拼成
16-byte 逻辑 source/index/destination view。跨出当前 route domain 的 permutation 仍需
额外交换网络或经过局部存储分拍执行。

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
广播；普通 Bênes 网络只保证一一置换，无法直接表达这一点。跨组 VRF-indexed
`fmt=0xd` 已经由 controller 展开，并在 cluster wrapper 中交给
`vsp_cluster_register_route_engine`。该 engine 捕获 VRF operands 后使用
`vsp_vrf_gather` 形成 16-byte 结果。`vsp_lane_gather`、fixed-four-pass、Omega 与
Bênes 内容保留为实现比较和扩展研究，不是当前 VROUTE 的连接路径。

## `simd_route` 内部操作

| 操作 | 含义 |
|---|---|
| `ROUTE_OP_GATHER` | 每个输出使用自己的 `index_i`，覆盖 permutation/gather/multicast |
| `ROUTE_OP_BROADCAST` | 所有输出读取 `broadcast_index_i` 指定的输入 lane |
| `ROUTE_OP_SLIDE_UP` | 数据向高编号 lane 移动，低端缺口从 `lower_i` 获取 |
| `ROUTE_OP_SLIDE_DOWN` | 数据向低编号 lane 移动，高端缺口从 `upper_i` 获取 |

这些是 `simd_route` 叶端 RTL 的控制接口，不再是一组可以直接编码的指令操作。
profile v0 的单字 `fmt=0xd` 已重定义为纯向量 gather：

```text
EXEC_ROUTE vs=1 vi=3 vd=2 io=3
```

`vs` 是数据 VRF row，`vi` 是保存逐 byte 8-bit index 的 VRF row，`vd` 是目的
VRF row。展开结果固定为 `PASS_A/BYTE/GATHER`，`write_vrf=IN`；除新的 OUT/IN role
immediate 外，旧的 index/broadcast/slide control 均为零。重复索引自然表达广播；
偏移索引表达 domain 内 slide mapping。越界或
inactive source 会关闭对应目的 byte 的写使能并保留旧 `vd`；需要 zero-fill slide 时，
程序必须先清零目的值或显式选择一个有效零源。现有
4×4 `simd_route` 可以继续作为 cluster route 的叶端物理资源，但没有独立的
immediate router 编码。

## 当前 cluster VROUTE 数据通路 `[已接入]`

默认 `GROUP_COUNT=4`、每组四个 byte。`vsp_cluster_memory_wrapper` 在普通 group EXEC
入口之前识别合法 VROUTE，并将它交给 blocking、single-active 的
`vsp_cluster_register_route_engine`。当前实现顺序执行：

1. 通过共享 VRF arbiter，逐个捕获选中 group 的 `vs` row；
2. 再逐个捕获这些 group 的 `vi` row；
3. 对完整 snapshot 组合执行 `vsp_vrf_gather`；
4. 逐个向选中 group 的 `vd` row 发 masked write；
5. 所有目标 write 完成后才产生 action completion。

所有 source/index snapshot 都先于第一次 destination write，因此当前实现允许
`vd==vs`、`vd==vi` 以及三者相等，不会被早期写回破坏。route 与 vector memory engine
共享 VRF transaction arbiter，故 action latency 包含 arbitration、endpoint ready 和
completion backpressure；它不是固定四拍，也还不是每拍可接受一条的新流水线。

一个 route-domain-relative byte index 的映射为：

```text
domain_byte = 4 * group_local_slot + lane_offset
```

在默认四组 domain 中，`vi` 的 8-bit index 0..15 合法；16..255 保留完整值参与范围
检查，不截断到低四位，也不回绕。group-local slot 只是本 wrapper 内的 group endpoint
序号。每个 group 另有 `SIMD4_BASE_ID + slot` 形成的不可变 8-bit SIMD4 static ID；该
身份没有编码进 `vi`，也不参与上述 byte index 计算。

VROUTE v0 的 `group_mask` 来自 canonical action envelope，不来自 `fmt=0xd` 或 MRF。
`fmt=0xd` 的 `[27:26]` 是 `OUT/IN` role immediate；当前可执行的 blocking action 必须
为 `INOUT`，因此仍由同一 mask 同时选择 source 与 destination。其他三种 mode 已编码并
贯穿 canonical payload，但当前 engine 会在任何 VRF 访问前有序拒绝。
一个选中 bit 把该 group 的四个 destination byte 全部置为 active，并令 engine 捕获
该 group 的 source/index row。route engine 的通用边界会遵守 VRF read response mask，
但当前 group endpoint 只回显 engine 发出的全一 request mask，VRF 也没有持久 validity；
因此已接入路径目前没有选中 group 内的独立 tail/predicate。行为为：

- inactive destination：不产生 byte write，原 `vd` 保持；
- active destination 且 index 合法、source byte 有效：写所选 source byte；
- active destination 但 index 越界，或指向未选中/无效 source byte：不产生该 byte
  write，原 `vd` 保持，同时在 engine 内置 invalid-element bit；
- 重复 index 合法，直接表达 multicast/broadcast；空 `group_mask` 拒绝且不写回。

逐 byte invalid-element mask 当前保存在 route completion 内部，但统一 EXEC completion
envelope 尚未将它暴露给上级。invalid-element 只是诊断，不把 action 标成 illegal、
rejected 或 protocol error。read-side error 在首次 destination write 前终止，因而完整
保留旧目的值；write 逐组提交，若后续 write 失败，较早已经接受的 group write 可能已经
生效，并通过 illegal-group status 报告。

默认 16-byte domain 可让程序把 16..255 的索引用作 per-byte no-write sentinel，从而
得到 tail-undisturbed 行为；它不提供确定性零填充。独立 lane-active mask（例如 action
metadata/MRF 路径）仍有价值，尤其当 route domain 扩到 256 byte、全部 8-bit index 都
成为合法源地址时。

### 叶端 `simd_route` 的 slide boundary

`slide_amount_i=0` 是恒等映射；`slide_amount_i=LANES` 完整传入相邻 SIMD group。更大的数超出这个局部网络覆盖范围并报告 `illegal_o`。

将 `lower_i/upper_i` 绑为零即可得到局部零填充 slide；它们本质上是抽象 boundary
ports。正确性只要求 boundary data 在事务期间稳定并经过资源仲裁；M2 参考实现
先把数据捕获到 boundary staging/ingress，避免直接组合读取另一个正在执行的
group RF。`boundary_mask_o` 只标记哪些结果来自 boundary
输入，不是执行 mask。

## Group-local 数据通路位置

普通 SIMD group execution 只实例化一份 local route，放在 VRF source A 与 lane
execution 之间：

```text
VRF source A ── local route ──┐
                              ├── lane execute ── writeback/reduction
VRF source B ─────────────────┘
```

- `route_enable_i=0`：source A 直接进入执行单元；
- `route_enable_i=1`：source A 先经过路由；
- `PASS_A + write_vrf_i`：形成单独的 route 写回；
- 其他 ALU 操作：可以直接消费路由后的 A，避免临时寄存器。

这避免为两个源操作数复制两套 crossbar，也没有把网络串到 B 操作数路径。当前仍是
无内部流水的组合实现；可否满足目标频率必须在选定工艺和 lane/位宽后通过综合判断。
编码后的 cluster VROUTE 不沿这条普通 group EXEC 路径逐组发射；wrapper 会截获它，
改由上一节的共享 register-route engine 读写 VRF。两条路径具有相同的 output-selects-input
语义，但当前没有物理复用同一份 crossbar。

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

## 未接入的比较基线：`vsp_lane_gather` `[研究参考]`

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
lane 置零。该 standalone mode 接口的 `illegal_o` 与当前 VROUTE 的逐 byte invalid
diagnostic 不同，不能把它们静默等同；已接入 VROUTE 的 out-of-range 行为以上一节为准。

该 standalone 模块自身仍不定义 VRF stripe、资源预留、group ownership 或写回事务。
这些合同已经由 `vsp_cluster_register_route_engine` 在另一条路径闭合；不能据此声称
`vsp_lane_gather` 本身已接入或是已选拓扑。

## 研究参考：4-group 固定四次迭代 gather `[standalone RTL，未接入]`

这里记录的是被比较过但未被当前 cluster wrapper 选择的多 pass 实现。目标仍是
byte-lane register gather，不是 indexed memory load：四个相邻
SIMD4 group 各提供一个 32-bit VRF row，共同形成 16-byte source、16-byte index 和
16-byte destination view。它与已接入 VROUTE 共用有效 index 的 4-group
route-domain mapping 和 invalid/no-write 合同，因而未来可替换当前 datapath 而不改变
语义：

```text
for i in 0..15:
    if destination_active[i]:
        source_ok = index[i] < 16 && source_active[index[i]]
        if source_ok:
            destination[i] = source[index[i]]
        else:
            write_enable[i] = 0
            invalid[i] = 1
```

重复 index 合法并形成 multicast/broadcast；每个 destination byte 只有一个 producer，
因此不是 scatter。index 可由 VRF 的第二读操作数提供。为了让超范围值不会被低四位
截断后回绕，首版即使只访问 16 个 byte，也应保存并检查完整的 8-bit index。
`source_active/destination_active` 由 action 的 group mask 按每组四个 byte 展开；
inactive destination 不写回；active destination 的越界索引或 inactive source 同样
关闭写使能、保留目的值，但额外产生 invalid 诊断。four-pass reference 的 result
write-mask 同样只标记 valid hit，OOB mask 独立保留诊断信息。

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

当前 reference 已按这个边界落地：

- `vsp_word_first_gather_phase`：组合实现一次 word-first pass，输入完整 128-bit source、
  128-bit full-byte index、16-bit active mask 和 2-bit phase，每次返回四个目的 group
  各自选中的一个 byte、write-enable 与 OOB；
- `vsp_four_pass_gather_engine`：在 command handshake 时快照 source/index/mask/identity，
  连续执行 phase 0–3，在内部形成 128-bit result，并通过 decoupled response 返回
  write-mask 与 OOB-mask；response 背压期间全部状态保持稳定。

它们没有接入 VRF、canonical action 或现有 cluster completion；因此验证的是 route core
与事务边界，不把“capture + four passes + commit”缩写成一条已经可发射的四周期指令。
当前 engine 是 single-outstanding：command capture 后四个 RUN edge 产生 response；在
result 永远 ready 时，下一 command 在随后一个 edge 接受，所以 reference 的 command
initiation interval 是 5，而组合网络被占用的 route passes 仍是 4。后续若需要 II=4，
可在不改 phase 语义的前提下增加 response queue 或 phase3/new-command overlap。

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

### 与 Omega/Bênes 的区别：network stage 不是 route pass

Omega、Bênes 和这个 four-pass hierarchy 都能画成多级 mux，但不能据此统称为相同的
`N log N` 网络。以 `N=16` 个 8-bit endpoint 为例，下表按每个 2×2 switch 含两个
8-bit 2:1 mux 估算：

| 结构 | 空间级/时间次数 | bit-level 2:1 mux | 单次支持的 mapping |
|---|---:|---:|---|
| 标准 Omega | 4 个 network stages | `32*2*8 = 512` | unique-path、blocking permutation 子集 |
| 标准 Bênes | 7 个 network stages | `56*2*8 = 896` | 求得 switch setting 后的任意 permutation |
| flat byte gather crossbar | 1 traversal | `16*15*8 = 1920` | 任意 gather/multicast |
| word-first reference | 同一网络复用 4 passes | `480` | 任意 4-group×4-byte gather |

Omega 的 destination bit 可以逐级 self-route，但只消除了全局 route-setting，不会消除
内部 link contention；不兼容的同时请求仍需拆分、仲裁或返回 accepted mask。Bênes 对
一一 permutation 是 rearrangeably non-blocking，但需要先计算整网 switch setting；标准
straight/cross 2×2 switch 不复制输入，重复 index 或全广播不能单遍完成。若增加 copy、
buffer 或 arbitration，已不再是上述简单 `N log N` 成本模型。

word-first reference 则用 output-driven multicast word mux，index 高两位直接选 word、
低两位直接选 byte，没有 path search。这里的“四”是同一硬件被时间复用四次；Omega
的“四级”和 Bênes 的“七级”是空间组合级，可以整拍穿越，也可以插寄存器形成 pipeline，
但流水不会改变某个 mapping 是否会阻塞或是否允许复制。

在本项目真正关心的四个 32-bit group port 上，差异更直接：4×4 full word crossbar 是
12 个 32-bit 2:1 mux；4-port Bênes 也是 `3 stages * 2 switches * 2 outputs = 12` 个
32-bit mux。后者组合更深、需要 setting 且不支持 multicast，所以这个小 domain 没有
采用 Bênes/Omega 的面积理由。一般 `M group × L lane` 的 word/local full-crossbar
hierarchy 也仍含 `M²` word connectivity；它不是全局扩展到任意规模时的 `N log N`
答案，而是用固定小 domain 和多次 pass 换掉动态 conflict handling。

### 当前 Transaction 与资源合同

已接入实现采用比上述 four-pass reference 更窄的共享 VRF 边界：

1. VROUTE 仍属于 `EXEC`，wrapper 将合法 route action 从普通 per-group EXEC 路径分流
   到一个 blocking、single-active register-route engine，不新增 dispatch class；
2. engine 只访问 `group_mask` 选中的 group，经 single-group VRF arbiter port 逐组读取
   `vs`，再逐组读取 `vi`，完整 snapshot 后才计算和写回；
3. `group_mask` 按每组选中四个 byte；engine 能遵守 RF response mask，但当前 endpoint
   回显全一 request mask，因此部署路径仍是 whole-group active。inactive destination
   与 active invalid destination 都保持旧值；后者额外设置逐 byte invalid 诊断，但不使
   action 异常；
4. `vsp_vrf_gather` 一次组合形成整个 route-domain result，随后经同一 arbiter 逐组选中
   destination row masked write。这里没有 four-pass route latency，也没有并行四组 commit；
5. completion 只在最后一个被选 group 的 write response 完成后产生。下游背压期间
   command identity、snapshot、result 和 completion 保持稳定；
6. 任意 read error 在 commit 前中止；write error 发生时，前面已经完成的串行 write
   可能已经可见。因此现有实现提供 read-side all-or-nothing，但不承诺 write-side rollback。

这条实现复用了现有 VRF arbiter，先闭合了可调用性、alias 安全和 completion。并行
capture/commit、route pipeline 与不同 crossbar hierarchy 仍可作为吞吐/面积优化，而非
当前语义缺口。

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
| 当前 4-group register gather | 选中组的 VRF snapshot | 无 TLB/cache fault；延迟随串行 VRF 事务与背压变化 | FFT/小波/transpose/邻域数据已驻留且会复用 |
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

### 当前层级与扩展边界

```text
SIMD4 group
  -> 现有 4x4 local route 作为内部叶端选择器

4-group / 16-byte route domain
  -> 已接入 blocking snapshot + vsp_vrf_gather + serial masked commit

execution cluster with several route domains
  -> point-to-point word/packet exchange + staging；不承诺全局任意 byte gather

D-side memory hierarchy
  -> 未来独立 indexed gather/scatter AGU/coalescer/reorder path
```

已保留 flat `vsp_lane_gather` 与 word-first phase/engine 作为 A/B research RTL。若后续
目标是提高 VROUTE 吞吐，可以在不改 `vs/vi/vd` 和逐 byte invalid 语义的前提下，比较
并行 VRF capture/commit、four-pass hierarchy 或 pipelined flat gather。只有真实 trace
显示跨 route-domain gather 频繁，才扩大 network；否则让编译器用 packet exchange、
scratch row 或 SRAM layout 组合，避免全 cluster `O(group_count^2)` word crossbar。

资料对照：RVV 也把
[register gather 与 indexed memory load/store](https://docs.riscv.org/reference/isa/extensions/vector/_attachments/riscv-v-spec.pdf)
分成不同操作族；Ara 把
[VLSU、全连接 permutation unit 与 lane execution](https://github.com/pulp-platform/ara/blob/main/docs/source/modules/ara.md)
分开；Saturn 的
[VLSU 手册](https://saturn-vectors.org/)展示了 DSP 型 conventional memory 对 indexed
address generation 的吞吐限制；AraXL 的
[层级互连研究](https://arxiv.org/abs/2501.10301)说明 lane 数扩大后物理布线会主导；近期
[短向量 permutation unit 实现](https://arxiv.org/abs/2505.07112)也表明 flat crossbar
在具体工艺下未必不可接受，所以最终选择仍应来自综合，而不是只看渐近式。Omega 的
stage/unique-path 定义可追溯到
[Lawrie 1975](https://doi.org/10.1109/T-C.1975.224157)，Bênes 的 rearrangeable network
性质见[原始工作](https://doi.org/10.1002/j.1538-7305.1964.tb04103.x)。

## 跨组 lane gather 语义 `[编码与执行已接入]`

profile v0 的 `fmt=0xd` 已编码下面的 VRF-indexed register gather，并保持为 EXEC
class；controller 展开、cluster 分流、VRF operand capture、route engine 仲裁、commit
和 completion 已经接通。当前采用共享 arbiter 上的串行 capture/commit，不表示并行
四组端口或最终物理拓扑已经决定。以下 Omega/Bênes 比较保留用于追溯问题。

跨组路由不是与 MEMORY 并列的独立 command class。当前用一个 register-gather action
描述目标语义；wrapper 在 EXEC integration boundary 把它交给共享 route engine：

```text
ROUTE SR, IR, DR
DR[lane] = SR[IR[lane]]
```

`SR`、`IR` 和 `DR` 分别由 `vs`、`vi`、`vd` 指定。一个逻辑 row view 按
`domain_byte = 4 * group-local slot + lane offset`，把同一 row number 在四个 group
中的 fragment 依 slot 顺序连接；它不按 8-bit SIMD4 static ID 排列。索引由 VRF 提供，
因此可以是运行时计算结果。8-bit index 保持 0..255 的完整值；当前 16-byte domain 仅
0..15 合法。active destination 的 out-of-range index 或 inactive source 会关闭对应
byte write、保留原 `vd` 并设置 invalid 诊断；inactive destination 同样禁止 byte write，
但不设置这项诊断。两种情况都不会使 action illegal。该逐 byte 语义由
`vsp_vrf_gather` 实现，不沿用 local `simd_crossbar` 的整操作 `illegal_o` 行为。

首版可执行的 `INOUT group_mask` 按 group-local slot 编号，并对选中 group 的四个 byte
整组启用；它同时限定 source/index capture 与 destination commit。因而 index 指向未选中 group 的
byte 时，等同于指向 inactive source 并禁止该目的 byte 写回。engine 接口保留
response-mask 合并逻辑，
但当前 endpoint 不提供独立 byte validity；`fmt=0xd` 也不携带 MRF selector 或 per-byte
predicate，所以选中组内的 tail 可用 OOB index 得到 undisturbed 行为；zero-fill 仍需
预清 `vd` 或显式有效零源。

### 语义边界：只做 gather

每个目的 lane 自带索引，因此目的端天然唯一：

- 索引互不相同：置换；
- 索引重复：广播/多播（多个目的读同一个源）；
- **不支持 scatter**：同一条操作内不会出现多个源竞争写同一个目的。

many-to-one 的写冲突只可能跨操作发生（后一条 gather 覆盖前一条的目的），硬件
不需要在单次操作内做冲突消解。因此不需要 conflict-detection CAM、写归约网络或
串行化重排缓冲。当前不支持 scatter；以后可以比较 sequencer 分解的顺序 STORE，
或独立 indexed-memory unit，但这两条 fallback 目前都没有 RTL。

### 两个 mask 协作与 outstanding 边界

OUT/IN 两位只声明一个 mask 在 route wave 中的角色，不负责把两个独立 action 配成一
对。首个 cooperative profile 应只允许同一 execution context 内的 streams 协作，并以
显式的 `{context, epoch, route_id}`（或同一条已定义的 bundle 身份）匹配；participant
tag 可以不同。OUT/IN 本身不授权跨 context 读取 VRF；若以后需要跨 context 交换，必须
另行定义 sharing/permission 和双边 retirement 语义。匹配后形成一个内部 parent：

```text
src_group_mask       OUT fragments 的并集
dst_group_mask       IN fragments 的并集
resource_group_mask  src_group_mask | dst_group_mask
```

这里区分两个 handshake：

- `fragment_capture`：可选的有限 rendezvous table 从 action queue 收走一半 descriptor；
  它不分配 execution tracker、不锁 group/route engine，也不算已接受的 route
  outstanding。table 满时只产生普通入口 backpressure；
- `wave_accept`：所有 participant 已配齐，且 union groups、route engine、VRF hazard 和
  每个 participant 的 completion credit 能同拍原子取得，内部 parent 才进入执行。

不设置 rendezvous table 也可要求所有 fragment 同时在多个 queue head 可见，并直接做
原子 `wave_accept`；代价是更强的 head-of-line/program scheduling 约束。一个 execution
parent 不等于一个 architectural completion：接受时为每个 participant 预留 completion，
共同执行结束后按原 context/tag fan-out；共同 transport fault 广播给各 participant，
逐 byte invalid 只归属有 IN role 的 participant。当前单条 `INOUT` 是一 parent/一
completion 的特例。

parent 一旦接受，只能等待已经发出的有限 VRF response、固定 route/commit 阶段及已
预留 completion buffer 的背压；不能再等待另一个 slot、未来指令或运行中扩大的 mask。
索引落在 `src_group_mask` 外仍沿用 no-write、保留 `vd` 的 invalid 行为。

按 slot 号、mask 相似性或“恰好同拍到达”隐式配对会让结果依赖调度时序，不作为程序
语义。若 peer 永远不出现，仍会形成程序级 rendezvous deadlock。使用 table 时，只有
out-of-band flush/epoch teardown 或 table 可直接观察到的 stream-end 才能可靠取消并报告
孤立 fragment；位于同一阻塞队头之后的普通 END/barrier 不能反过来解锁它。无 table
方案则由编译器/程序保证各 fragment 同时可见，系统级 abort/watchdog 负责错误恢复。
当前 RTL 没有 rendezvous table，因此只执行单 action 的 `INOUT`。

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
`fmt=0xd` 已产生 `vs/vi/vd` 和 OUT/IN canonical operands；当前 engine 在任何 VRF
事务前有序拒绝非 `INOUT` mode。`vsp_cluster_register_route_engine`
经 cluster VRF arbiter 捕获 operands，调用 `vsp_vrf_gather` 并写回，已接入 controller/
cluster completion 路径。`vsp_lane_gather`、`vsp_four_pass_gather_engine`、参数化
`benes_network` 与 Omega 方案只作为实现研究材料保留，不接入正式 VROUTE 路径。

## Broadcast 边界

`ROUTE_OP_BROADCAST` 仍是叶端 RTL 的 lane-to-lanes 控制，但没有独立编码。正式
VROUTE 用索引 VRF row 中的重复值表达广播。展开后的 scalar immediate 已经能送到
单个 SIMD4；cluster 中相同 uop/常数的控制扇出不经过全局 N×N data crossbar。
