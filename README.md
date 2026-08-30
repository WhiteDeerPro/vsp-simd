# VSP SIMD Core

这是一个通用的可编程向量/SIMD RTL 研究项目。图像、视频和信号处理是当前代表性
负载，但不进入硬件操作语义。统一用词见[术语表](docs/architecture/terminology.md)。

项目已经形成一个可运行的有序 action reference integration，但仍不是完整 VSP：

```text
VSP / SoC 子系统（未来）
└── 计算集群（开发中）
    ├── late-decode holding stage（参考 RTL 已实现，尚未接入 queue ownership）
    ├── EXEC uword profile-v0 expander（参考 RTL 已实现并接入控制 wrapper）
    ├── EXEC cluster integration（参考 RTL 已实现）
    │   ├── queue / RR live-head / atomic dispatch / per-group ingress
    │   ├── 4 × SIMD4 transaction wrapper
    │   └── completion tracker / result collector / reject sink
    ├── strict ordered action controller / class router（参考 RTL 已实现）
    │   ├── EXEC → profile-v0 expander → EXEC cluster
    │   ├── MEMORY → semantic decoder / address-state snapshot → vector memory engine
    │   ├── CONTROL state → sequencer address-state engine
    │   └── CONTROL.END → strong-quiescent completion
    ├── VRF vector memory engine（独立参考 RTL 已实现）
    ├── VRF arbiter（参考 RTL 已实现）
    ├── 4-word uword bundle framing / class predecode（独立参考 RTL 已实现）
    ├── byte-PC program source / control-store model / bundle assembler（独立参考 RTL 已实现）
    ├── multi-record framer / slot-0 action adapter / strict program wrapper（已接通）
    ├── ordered action window（含 predecessor-barrier 记账；尚未接入 strict program path）
    ├── route rendezvous table（DEP_IN/DEP_OUT 配对/退休门槛 leaf；尚未接入 program path）
    ├── sequencer address-state engine（已接入 strict slot-0 program path）
    ├── ordered I-side fetch 仿真模型（simulation only）
    ├── ordered dmem 仿真模型（可配置 FIFO outstanding；simulation only）
    ├── lane route（组内 crossbar；4-group/16-byte VRF-indexed VROUTE 已接入）
    └── admission metadata、动态 owner/resource、并发 action-window binding
        与 loop/redirect（待实现）
```

“搜索、凝视、分层、附着、抽象、联合、追踪”属于软件算法。硬件不预设这些语义，只提供能够忠实、高效编纂这些算法的通用原语。

## 当前内容

- 当前 controller profile 以 `4×8-bit` SIMD4 作为调度颗粒，叶模块保留参数用于
  健壮性验证；
- BYTE/HALF/WORD 动态边界的加减、移位、整体最值和有/无符号比较；
- 每 byte lane 的饱和、乘法与乘加等窄运算；
- 条件选择、移位 widening、公共移位对齐的三输入 `ARF+VRF-A±VRF-B`、宽值直接截位、舍入缩放和饱和 narrow；
- 由外部 sequencer 提供的广播立即数，可替代 VRF-B 驱动普通 ALU、MAC 和宽窄转换；
- 向量掩码执行；叶执行接口返回 merge 值，状态化 datapath 通过 masked RF write
  保留未激活 lane；
- 窄结果与宽结果分离，使累加精度独立于 8-bit 窄结果；
- 参数化组合 Bênes 网络，作为置换网络研究模块保留，不接入当前数据通路；
- `vsp_lane_gather`：默认 16 lane 的固定全 crossbar 临时基线，纯 gather，
  动态索引之外提供 identity/broadcast/rotate/reverse/transpose/deinterleave/
  interleave 静态图样与 rotate wrap 报告；已独立验证，不接入数据通路；
- `vsp_word_first_gather_phase` 与 `vsp_four_pass_gather_engine`：在对齐的
  4-group route domain 中快照 16-byte source、16-byte index 和 16-bit mask，以
  4×4 32-bit multicast word crossbar 和目的侧 byte selector 固定四次完成动态
  register gather；支持重复 index、OOB no-write/reporting、结果背压与 identity 保持，
  作为未接入的多 pass 比较实现保留；
- SIMD group 内的一份直接 crossbar，支持重复索引的 gather、lane broadcast 与 permutation；
- 单字 `EXEC_ROUTE vs/vi/vd/io` 编制与 `fmt=0xd` canonical expansion：数据和逐 byte
  索引均来自 VRF，旧的 index/broadcast/slide immediate control 已取消；当前 cluster
  以 blocking engine 经共享 VRF arbiter 串行捕获 source/index、完成 16-byte gather，再
  逐组 masked commit；OOB 或 invalid source 关闭对应 byte write 并保留 `vd`，invalid
  mask 只诊断、不使 action 异常；
  `io[1:0]` 已贯穿编码和 canonical payload：`00=LOCAL`、`01=DEP_IN`、
  `10=DEP_OUT`、`11=DEP_INOUT`，其中 `dependency=|io`；当前 engine 可执行 `LOCAL`
  以及 role-complete 的 `DEP_INOUT`。后者仍要求上游满足 dependency barrier，但当前
  single-active 路径尚无双槽证明；结构预解码已直接产生 route mode、
  `barrier-before` 与 `pair-required` 元数据，独立 ordered action window 会令
  barrier entry 等到退休队头再发射。独立 rendezvous leaf 可按
  `{context,epoch,route_id}` 收集 `DEP_IN/DEP_OUT`，并在两个 participant frontier
  达到 fence token 后交付 wave；这些部件尚未接成 concurrent program path。
  `DEP_IN/DEP_OUT` 当前有序拒绝且不访问 VRF；
- 可接相邻 SIMD group 边界的双向 slide，用于组成更宽的逻辑执行组；
- mask-aware 的组合 reduction tree，可求和、最小值、最大值和获胜 lane；
- 由 `ABSDIFF_U + REDUCE_SUM_U` 组合出的 SAD 验证内核；
- 由外部微操作驱动的单通道 3×3 Gaussian，覆盖 slide、连续 ARF MAC、tail mask 与最终舍入窄化；
- 由外部微操作驱动的单通道 3×3 Sobel，覆盖 `WSUB_U` 的负 ACC 累加链、共享 align
  表达 1/2 系数、source-A route 参与宽三输入操作、`NCLIP_S` 有符号窄化与
  `ABS_SAT_S`/`ADD_SAT_U` 幅值合成；
- 两 pass 8-bit 可分离 `[1,2,1]` Gaussian 比较负载：测量两次舍入相对精确九 tap 的
  偏差（本输入域内最大 1 LSB，仅出现在中间调内容）与微操作计量，并可选读入 PGM
  手动查看；
- 3×3 Median 比较负载：经全部 `9!` rank permutation 验证的 19-comparator
  selection network，当前单写口映射为每 SIMD4 block 57 条 EXEC；
- 外部 sequencer 发射的 VRF/ARF/MRF 状态化数据通路；
- operation/mode/writeback/route/reduction 的共享合法性检查；
- 默认 `4 group / 2 queue / 2 slot` 的 EXEC reference frontend：单 admission、
  有序 FIFO、round-robin live-head、opaque locked shadow、显式 reject credit
  和 terminal pop；
- 多 context、多 issue slot 的 owner 检查、原子 group-mask 分发和错误 reject；
- 单 group 的 decoded EXEC、RF state-write 与 VRF state-read ready/valid，
  tagged subrequest completion/data response、可背压 result capture 和状态传输仲裁；
- 默认 `4 group / 2 alloc slot / 2 context / 4 entry` 的 EXEC command
  completion tracker：按 `context+tag` 聚合可乱序/同拍 group completion，
  独立跟踪 expected result mask，并以可背压 RR 输出唯一 command completion；
- 默认 `4 group / 2 context / 2 slot` 的 `simd_cluster_exec`：完整 decoded
  EXEC admission、slot-specific resource grant、原子 tracker commit、每 group
  单项 ingress、四个 transaction wrapper、state-read/write subrequest lane、reject completion
  与 RR result collector；
- `simd_issue_decode_stage`：每 issue slot 一项的 late-decode holding 边界，保存
  raw/resolved/cached provenance 与 class/response/resource/canonical 输出；当前使用
  可替换 hook，不定义最终 32-bit/16-bit 编码；
- `vsp_decoded_action_controller`：统一接收 `EXEC/MEMORY/CONTROL` action，执行
  owner/context/类别检查、严格跨 class 顺序和统一 completion；首个 profile
  全局只保留一个 active action，`CONTROL.END` 等待内部执行队列、tracker、
  memory engine 和 VRF arbiter 全部静止；`program_done` 只表示 END completion
  退休，不汇总此前 action 是否成功；
- `vsp_cluster_controller_wrapper`：把 profile-v0 encoded EXEC、decoded MEMORY、
  EXEC cluster 与 vector memory engine 接成一条有序 action 链；EXEC data result
  仍与 command completion 独立返回；
- 内部 uword 工具与 program frontend reference：把 profile-v0 EXEC、
  `SMOVI/SADD/SADDI` CONTROL state、`VLOAD/VSTORE` MEMORY、opaque record 或 raw word
  编制成 hex/listing/symbol，写入可替换的 control-store
  行为模型，从参数化 byte PC 顺序读取，并跨 bundle 组装为单 record ready/valid；
  工具提供 VRF-indexed `EXEC_ROUTE` 与 `EXEC_REDUCE` pseudo-op；
- 独立 `vsp_vector_memory_engine`：VRF-only，一个 active command、一个
  outstanding memory beat，按 group 升序在连续 4-byte beat 上执行
  LOAD/STORE，并报告 stop-on-first 的 partial masks/bytes；
- `vsp_ordered_dmem_model`：byte-addressed 仿真 endpoint，覆盖 write strobe、
  range/address-space fault、response backpressure 和严格有序的可配置 outstanding
  queue；它不是物理 SRAM/cache/MMU；
- `vsp_ordered_ifetch_model`：read-only I-side 仿真 endpoint，覆盖 byte-PC、1–4 word
  bundle、address-space/fault、response backpressure 和严格有序的可配置 outstanding
  queue；它尚未接 program source，也不是 I-cache；
- `vsp_sequencer_state_engine`：per-context 32-bit address state、恒零 register 0、
  `SMOVI/SADD/SADDI`、可背压 completion 和 base query；它不持有 PC 或 memory port，
  当前已由 strict program wrapper 的 CONTROL decoder 驱动，并在 MEMORY action admission
  时提供 base 快照；
- `vsp_cluster_vrf_arbiter`：在多个 VRF-only client 与 cluster 的单组 group VRF
  state-read/write 端点之间做 RR 仲裁，一次保留一个 subrequest owner；
- Verilator lint 与自检仿真。

当前 `simd_cluster_exec` 采用 full-decoded reference profile：入口直接提供
canonical EXEC 控制，内部 queue、dispatcher、per-group ingress、wrapper、
tracker、reject buffer 和 result collector 已组成可背压事务闭环。可信
state-read/write subrequest lane 使外部 engine 能传输 VRF row；它们不是算术指令。
`simd_issue_decode_stage` 已给出晚译码后的稳定 holding 边界，profile-v0 EXEC
parser/expander 也已在 controller wrapper 的 action 入口接入。当前 class router
验证的是一个保守的、全局单 active action 路径。`vsp_uword_predecoder` 已能在
一个 4-word bundle 内划分 mixed uword record 并预判 dispatch class；
`vsp_uword_cluster_program_wrapper` 已把线性 byte PC、control-store、multi-record
framer、launch envelope、slot-0 action adapter、state/MEMORY semantic decoder 和 strict
controller 接通。当前定向闭环能够从 encoded stream 顺序执行
`SMOVI/SADD/SADDI → VLOAD → EXEC → VSTORE → END`，并在 MEMORY admission 时快照
state base。它仍只消费 slot 0；三 record admission metadata、ordered window 与多
engine 并发 binding、queue-head late-decode 重排尚未接通。因此该 reference
integration 可以验证程序顺序、地址状态、数据搬运和完成合同，但还不是并发
sequencer，也不代表最终吞吐组织。
跨组 lane 路由不再候选为与 MEMORY 并列的独立 command class。`fmt=0xd` 现为寄存器
形式的 gather：`DR[lane] = SR[IR[lane]]`，其中 SR/IR/DR 都是 VRF row，允许一对一
置换与广播，不支持 scatter（同一操作内不会出现多通道写同一通道）。它属于 Vector
ALU/cluster 的 EXEC routing path；`vsp_cluster_register_route_engine` 已经通过共享 VRF
arbiter 串行捕获选中 group 的 source/index row，使用 `vsp_vrf_gather` 形成 16-byte
结果，逐组 masked commit 后进入 cluster completion。memory wrapper 会先排空既有
ordinary EXEC/MEMORY/VRF transaction；pending route 阻止新 MEMORY，route busy 阻止
新 ordinary EXEC/MEMORY，因而安全性不只依赖外层 strict controller。当前仍是
single-active blocking 实现；并行 capture/commit、独立 source/destination mask、
细粒度 predicate、双槽 dependency rendezvous 和并发 resource-aware scheduling 尚未完善。
非零 dependency route 后续只能在两槽旧操作真实退休、ingress/tracker/reject/completion、
MEMORY 与 VRF arbiter 都排空后接受；slot/queue 暂时为空本身不足以构成这个条件。
`vsp_lane_gather` 与
word-first four-pass engine 只保留为未接入的物理实现比较。

`vsp_vector_memory_engine` 已接入 reference class router，但尚未接入 local SRAM 或
DMA，不表示整个存储路径已闭合。
它区分 execution context 与 address context，并携带
`LOCAL/PHYSICAL/TRANSLATED` address-space 类别；这只定义可插入未来
翻译/路由 adapter 的有序 data-memory 逻辑口，当前没有 MMU、TLB、
PTW 或 cache；只有独立的 I-side protocol model，不是 architectural IFetch。
当前 control-store source 也不是 I-cache；program path 没有 loop/branch/redirect。

术语上，当前内部信号名为 `op_i`/`exec_op_i`；6-bit `simd_op_e`
只是 canonical `EXEC` 的 function，不是完整 opcode。项目尚未定义
32/16-bit instruction；queue 的 32/16/16 默认宽度只是 opaque
elaboration profile，不是编码格式。
program-level RF_FILL 的 bulk data 不进入指令字或指令队列，候选边界归入
[数据准备与 DMA](docs/design/data-movement.md)。独立处理器所需的取指、分支和异常
不在当前路线内，物理 RF、流水线和访存组织仍待选择。

## 目录结构

```text
rtl/
├── pkg/            # 公共类型、操作码与参数
├── units/          # lane 内算术、移位、mask 与 reduction 单元
├── permute/        # group 内 crossbar、route 与 compact
├── group/          # 寄存器文件、执行级与 group 数据通路
├── interconnect/   # group 之上的交换网络实验
├── cluster/        # 多 group 所有权、发射与后续集群控制
├── control/        # 内部 uword control store、byte-PC source 与 record assembler
├── memory/         # 独立 VSP MEMORY/vector memory engine 参考 RTL
└── files.mk        # 各验证目标唯一、有序的 RTL 文件清单
sim/                # Verilator 自检 testbench 与行为参考模型
tools/              # 内部 uword 编制等开发辅助工具
examples/uword/     # 工具和 program frontend 使用的短程序
docs/               # 架构现状、候选设计、Q&A、负载和验证方法
```

这里采用浅层分类：模块边界不因整理目录而改变，后续加入乘法卷积/部分积单元时先归入 `units/`，达到需要独立演进的规模后再细分。

## 构建与验证

需要 Verilator、GNU Make 和支持 C++17 的编译器；仅重新生成架构图时需要 Graphviz。

```bash
make lint
make test
```

只运行本次新增路径，或查看工具生成的 byte-PC listing：

```bash
make test-vsp-sequencer-state-engine test-vsp-ordered-ifetch-model
make test-vsp-uword-asm test-vsp-uword-program-frontend \
  test-vsp-uword-cluster-program
python3 tools/vsp_uword_asm.py examples/uword/pc_smoke.uasm \
  -o /tmp/vsp-pc-smoke.hex --base-pc 0x20 \
  --listing /tmp/vsp-pc-smoke.lst --symbols /tmp/vsp-pc-smoke.json
```

默认的可再生 Verilator 产物集中在 `build/`，`make clean` 可将其全部清除。若工作区上传器不读取 `.gitignore`，建议直接在工作区外构建，并用 quiet 模式避免回传冗长的编译命令：

```bash
make -s BUILD_DIR=/tmp/vsp-build lint
make -s BUILD_DIR=/tmp/vsp-build test
make BUILD_DIR=/tmp/vsp-build clean
```

`BUILD_DIR` 可换成任意专用构建目录；`clean` 带有保护，不会删除 `/`、当前工作区或其父目录。

文档从[文档导航](docs/README.md)开始。当前控制主线：

- [架构范围工作稿](docs/architecture/overview.md)
- [I-side / D-side 内存模型边界](docs/architecture/memory-hierarchy.md)
- [SIMD4 集群控制工作稿](docs/design/cluster-control.md)
- [队列、微指令与译码候选](docs/design/instruction-delivery.md)
- [Internal EXEC uword profile v0](docs/design/exec-uword-profile-v0.md)
- [数据准备与 DMA 边界](docs/design/data-movement.md)
- [架构问题集](docs/explorations/architecture-qa.md)
- [VSP/SIMD 集群实验路线](docs/design/development-roadmap.md)
